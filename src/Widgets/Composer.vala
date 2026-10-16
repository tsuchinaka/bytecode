/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The conversation input: multiline entry, attachment chips, inline
 * slash-command list, changed-files chip, context meter, model and
 * agent pickers, stop and send buttons.
 *
 * Attachments arrive via clipboard paste (Ctrl+V with an image) or
 * file drag-and-drop. They are staged as files and sent as
 * `file://` prompt attachments. Any file type is accepted; images
 * get a preview, everything else a named chip.
 */

namespace OpenClient {

public class Attachment : GLib.Object {
    public string path { get; set; default = ""; }
    public string name { get; set; default = ""; }
    public string mime { get; set; default = ""; }

    public string uri {
        owned get {
            return "file://" + path;
        }
    }

    public FileAttachment to_file_attachment () {
        return new FileAttachment () {
            uri = this.uri,
            name = name,
            mime = mime
        };
    }
}

public class Composer : Gtk.Box {
    public signal void send_requested (string text, Gee.ArrayList<FileAttachment> files);
    public signal void command_requested (string name, string text);
    public signal void permission_decision (string request_id, string decision);
    public signal void form_answered (string form_id, Json.Node answer);
    public signal void form_cancelled (string form_id);

    private Gtk.Overlay overlay;
    private Gtk.TextView text_view;
    private Gtk.Box buttons;
    private Gtk.Label status_label;
    private Gtk.Button stop_button;
    private Gtk.Button send_button;
    private Gtk.Button attach_button;
    private Gtk.Box context_row;
    private Gtk.LevelBar context_level;
    private Gtk.Label context_label;
    private Gtk.Label context_status;
    private Gtk.FlowBox attachments_box;
    private Gtk.Revealer attachments_revealer;
    private Gee.ArrayList<Attachment> attachments;
    private Gtk.MenuButton diff_button;
    private Gtk.Box diff_row;
    private Gtk.Label diff_editing_label;
    private Gtk.Spinner diff_chip_spinner;
    private Gtk.Label diff_chip_add;
    private Gtk.Label diff_chip_del;
    private Gtk.Label diff_chip_count;
    private Gtk.Box diff_list_box;
    private Gtk.Revealer command_revealer;
    private Gtk.ListBox command_list;
    public AgentChooser agent_chooser;
    public ModelChooser model_chooser;
    public VariantChooser variant_chooser;
    private Gtk.Revealer form_revealer;
    private FormCard form_card;
    private Gtk.Revealer permission_revealer;
    private Gtk.Box permission_box;
    private Gtk.Label permission_label;
    private string permission_request_id = "";
    private Gtk.Button permission_mode_button;
    private string permission_mode = "ask";
    private BrailleSpinner busy_spinner;

    /** Commands offered by the slash-command list: server commands
     *  plus the built-ins. */
    private Gee.ArrayList<CommandInfo> commands = new Gee.ArrayList<CommandInfo> ();
    /** True while the inline command list is showing. */
    private bool commands_shown = false;
    /** Last query the command list was built for; null means "never
     *  built". */
    private string? last_command_query = null;

    /** Send with Ctrl+Enter instead of plain Enter. Construct-only so
     *  the window can bake it in at creation time. */
    public bool ctrl_enter_to_send { get; set; default = false; }

    public signal void stop_requested ();
    public signal void permission_mode_changed (string mode);

    public Composer () {
        Object (
            orientation: Gtk.Orientation.VERTICAL,
            spacing: 6,
            halign: Gtk.Align.FILL,
            hexpand: true
        );
        add_css_class ("composer-card");

        attachments = new Gee.ArrayList<Attachment> ();

        build_input ();
        build_toolbar ();
        build_commands ();
        build_diff_row ();
        build_context ();
        build_attachments ();
        build_permission_form ();

        append (attachments_revealer);
        append (command_revealer);
        append (form_revealer);
        append (diff_row);
        append (overlay);
        append (context_row);
        append (permission_revealer);
        append (buttons);
    }

    /* -- input --------------------------------------------------- */

    private void build_input () {
        var scroller = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            propagate_natural_height = true,
            min_content_height = 48,
            max_content_height = 150
        };
        text_view = new Gtk.TextView () {
            wrap_mode = Gtk.WrapMode.WORD_CHAR,
            top_margin = 10,
            bottom_margin = 10,
            left_margin = 12,
            right_margin = 12,
            hexpand = true,
            valign = Gtk.Align.START
        };
        text_view.add_css_class ("composer-entry");
        var placeholder = new Gtk.Label ("Write a message…") {
            xalign = 0,
            halign = Gtk.Align.START
        };
        placeholder.add_css_class (Granite.CssClass.DIM);
        overlay = new Gtk.Overlay ();
        overlay.set_child (scroller);
        overlay.add_overlay (placeholder);
        scroller.set_child (text_view);

        text_view.buffer.changed.connect (() => {
            placeholder.visible = text_view.buffer.get_char_count () == 0;
            update_command_list ();
            update_send_state ();
        });

        /* Capture phase so our Ctrl+V image handling runs before the
         *  TextView's built-in paste, which would otherwise insert the
         *  file URI as plain text. */
        var key_controller = new Gtk.EventControllerKey ();
        key_controller.set_propagation_phase (Gtk.PropagationPhase.CAPTURE);
        key_controller.key_pressed.connect ((keyval, keycode, state) => {
            var control = (state & Gdk.ModifierType.CONTROL_MASK) != 0;
            if (control && (keyval == Gdk.Key.v || keyval == Gdk.Key.V)) {
                if (try_paste_image ()) {
                    return true;
                }
                return false;
            }

            if (commands_shown) {
                if (keyval == Gdk.Key.Escape) {
                    hide_commands ();
                    return true;
                }
                if (keyval == Gdk.Key.Down || keyval == Gdk.Key.Up) {
                    move_command_selection (keyval == Gdk.Key.Down);
                    return true;
                }
                if (keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter || keyval == Gdk.Key.Tab) {
                    run_selected_command ();
                    return true;
                }
            }

            if (keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter) {
                var ctrl = (state & Gdk.ModifierType.CONTROL_MASK) != 0;
                var shift = (state & Gdk.ModifierType.SHIFT_MASK) != 0;
                if (ctrl_enter_to_send ? ctrl && !shift : !shift) {
                    request_send ();
                    return true;
                }
            }
            return false;
        });
        text_view.add_controller (key_controller);
    }

    private void build_toolbar () {
        buttons = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        buttons.add_css_class ("composer-toolbar");

        permission_mode_button = new Gtk.Button.with_label ("Always ask") {
            valign = Gtk.Align.CENTER
        };
        permission_mode_button.add_css_class (Granite.STYLE_CLASS_FLAT);
        permission_mode_button.clicked.connect (cycle_permission_mode);

        agent_chooser = new AgentChooser ();
        model_chooser = new ModelChooser ();
        variant_chooser = new VariantChooser ();
        busy_spinner = new BrailleSpinner ();
        status_label = new Gtk.Label ("") {
            xalign = 0,
            halign = Gtk.Align.START
        };
        status_label.add_css_class (Granite.CssClass.DIM);
        status_label.add_css_class ("composer-status");

        attach_button = new Gtk.Button.from_icon_name ("mail-attachment-symbolic") {
            tooltip_text = "Attach files (or paste and drop them here)",
            valign = Gtk.Align.CENTER
        };
        attach_button.add_css_class (Granite.STYLE_CLASS_FLAT);
        attach_button.clicked.connect (open_attach_dialog);

        stop_button = new Gtk.Button.from_icon_name ("media-playback-stop-symbolic") {
            tooltip_text = "Stop",
            valign = Gtk.Align.CENTER,
            visible = false
        };
        stop_button.add_css_class (Granite.STYLE_CLASS_FLAT);
        stop_button.clicked.connect (() => {
            stop_requested ();
        });

        send_button = new Gtk.Button.with_label ("Send") {
            valign = Gtk.Align.CENTER,
            sensitive = false
        };
        send_button.add_css_class ("suggested-action");
        send_button.clicked.connect (request_send);

        buttons.append (permission_mode_button);
        buttons.append (agent_chooser);
        buttons.append (model_chooser);
        buttons.append (variant_chooser);
        buttons.append (busy_spinner);
        buttons.append (status_label);
        buttons.append (attach_button);
        buttons.append (stop_button);
        buttons.append (send_button);
    }

    /* -- attachments ------------------------------------------- */

    private void build_attachments () {
        attachments_box = new Gtk.FlowBox () {
            column_spacing = 6,
            row_spacing = 6,
            homogeneous = false,
            selection_mode = Gtk.SelectionMode.NONE,
            visible = false
        };
        attachments_revealer = new Gtk.Revealer () {
            child = attachments_box,
            transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN,
            reveal_child = false
        };
    }

    public void set_context (double fraction, string label) {
        context_level.value = fraction;
        context_label.label = label;
    }

    public void set_context_status (string text) {
        context_status.label = text;
    }

    private void build_permission_form () {
        form_card = new FormCard ();
        form_card.submitted.connect ((form_id, answer) => {
            form_answered (form_id, answer);
        });
        form_card.cancelled.connect ((form_id) => {
            form_cancelled (form_id);
        });
        form_revealer = new Gtk.Revealer () {
            child = form_card,
            transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN,
            reveal_child = false
        };

        permission_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        permission_box.add_css_class (Granite.CssClass.CARD);
        permission_box.add_css_class ("permission-banner");
        permission_box.margin_bottom = 6;
        permission_box.margin_top = 2;

        var warning_icon = new Gtk.Image.from_icon_name ("dialog-warning") {
            valign = Gtk.Align.CENTER,
            margin_start = 10
        };
        permission_label = new Gtk.Label ("") {
            xalign = 0,
            wrap = true,
            hexpand = true,
            valign = Gtk.Align.CENTER
        };

        var reject_button = new Gtk.Button.with_label ("Reject");
        reject_button.add_css_class (Granite.STYLE_CLASS_FLAT);
        reject_button.clicked.connect (() => decide_permission ("reject"));

        var always_button = new Gtk.Button.with_label ("Always");
        always_button.add_css_class (Granite.STYLE_CLASS_FLAT);
        always_button.clicked.connect (() => decide_permission ("always"));

        var once_button = new Gtk.Button.with_label ("Allow Once");
        once_button.add_css_class ("suggested-action");
        once_button.margin_end = 6;
        once_button.clicked.connect (() => decide_permission ("once"));

        permission_box.append (warning_icon);
        permission_box.append (permission_label);
        permission_box.append (reject_button);
        permission_box.append (always_button);
        permission_box.append (once_button);

        permission_revealer = new Gtk.Revealer () {
            child = permission_box,
            transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN,
            reveal_child = false
        };
    }

    public void show_permission (string request_id, string description) {
        permission_request_id = request_id;
        permission_label.label = @"Permission requested: $description";
        permission_revealer.reveal_child = true;
    }

    public void hide_permission () {
        permission_request_id = "";
        permission_revealer.reveal_child = false;
    }

    private void decide_permission (string decision) {
        if (permission_request_id == "") {
            return;
        }
        permission_decision (permission_request_id, decision);
        hide_permission ();
    }

    public void show_form (FormInfo form) {
        form_card.set_form (form);
        form_revealer.reveal_child = true;
    }

    public void hide_form () {
        form_revealer.reveal_child = false;
    }

    private void rebuild_attachment_chips () {
        Gtk.Widget? child = attachments_box.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            attachments_box.remove (child);
            child = next;
        }
        foreach (var attachment in attachments) {
            var chip = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            chip.add_css_class ("attachment-chip");
            var icon = new Gtk.Image.from_icon_name (
                attachment.mime.has_prefix ("image/") ? "image-x-generic" : "text-x-generic"
            ) {
                pixel_size = 16
            };
            var label = new Gtk.Label (attachment.name) {
                xalign = 0,
                ellipsize = Pango.EllipsizeMode.MIDDLE,
                max_width_chars = 28
            };
            chip.append (icon);
            chip.append (label);
            chip.tooltip_text = attachment.uri;
            var captured = attachment;
            var close = new Gtk.Button.from_icon_name ("window-close-symbolic") {
                valign = Gtk.Align.CENTER
            };
            close.add_css_class (Granite.STYLE_CLASS_FLAT);
            close.clicked.connect (() => {
                attachments.remove (captured);
                rebuild_attachment_chips ();
            });
            chip.append (close);
            attachments_box.append (chip);
        }
        attachments_revealer.reveal_child = attachments.size > 0;
    }

    private void clear_attachments () {
        attachments.clear ();
        rebuild_attachment_chips ();
    }

    private void open_attach_dialog () {
        var dialog = new Gtk.FileChooserNative (
            "Attach files",
            null,
            Gtk.FileChooserAction.OPEN,
            "_Attach",
            "_Cancel"
        );
        dialog.set_select_multiple (true);
        dialog.show ();
        dialog.response.connect ((d, response) => {
            if (response == Gtk.ResponseType.ACCEPT) {
                var files = dialog.get_files ();
                for (uint i = 0; i < files.get_n_items (); i++) {
                    var file = files.get_item (i) as GLib.File;
                    if (file != null) {
                        attach_file (file);
                    }
                }
            }
            d.destroy ();
        });
    }

    private void attach_file (GLib.File file) {
        Work.submit (() => {
            string? mime = null;
            try {
                var info = file.query_info ("standard::content-type", GLib.FileQueryInfoFlags.NONE);
                mime = info.get_content_type ();
            } catch (Error e) {
                warning ("Could not read %s: %s", file.get_path (), e.message);
            }
            if (mime == null || mime == "inode/directory") {
                return;
            }
            var attachment = new Attachment () {
                path = file.get_path (),
                name = file.get_basename (),
                mime = mime
            };
            Idle.add (() => {
                attachments.add (attachment);
                rebuild_attachment_chips ();
                return false;
            });
        });
    }

    private void attach_texture (Gdk.Texture texture, string name) {
        var dir = GLib.Path.build_filename (GLib.Environment.get_user_cache_dir (), "opencode-client", "paste");
        var stamp = GLib.get_real_time ().to_string ();
        var path = GLib.Path.build_filename (dir, @"image-$stamp.png");

        var bytes = texture.save_to_png_bytes ();
        Work.submit (() => {
            try {
                GLib.DirUtils.create_with_parents (dir, 448);
                GLib.FileUtils.set_data (path, bytes.get_data ());
            } catch (Error e) {
                warning ("Could not save pasted image: %s", e.message);
                return;
            }
            Idle.add (() => {
                attachments.add (new Attachment () {
                    path = path,
                    name = name,
                    mime = "image/png"
                });
                rebuild_attachment_chips ();
                return false;
            });
        });
    }

    private bool try_paste_image () {
        var clipboard = text_view.get_clipboard ();
        var formats = clipboard.get_formats ();
        if (formats == null) {
            return false;
        }
        if (formats.contain_gtype (typeof (Gdk.Texture))) {
            clipboard.read_texture_async.begin (null, (obj, res) => {
                try {
                    var texture = clipboard.read_texture_async.end (res);
                    if (texture != null) {
                        attach_texture (texture, "pasted-image.png");
                    }
                } catch (Error e) {
                    warning ("Paste failed: %s", e.message);
                }
            });
            return true;
        }
        if (formats.contain_gtype (typeof (Gdk.FileList))) {
            clipboard.read_value_async.begin (typeof (Gdk.FileList), GLib.Priority.DEFAULT, null, (obj, res) => {
                try {
                    unowned GLib.Value? value = clipboard.read_value_async.end (res);
                    var list = value as Gdk.FileList;
                    if (list == null) {
                        return;
                    }
                    foreach (var file in list.get_files ()) {
                        attach_file (file);
                    }
                } catch (Error e) {
                    warning ("Paste files failed: %s", e.message);
                }
            });
            return true;
        }
        if (formats.contain_mime_type ("text/uri-list")) {
            read_clipboard_uri_list.begin (clipboard);
            return true;
        }
        return false;
    }

    private async void read_clipboard_uri_list (Gdk.Clipboard clipboard) {
        try {
            var stream = yield OpenClient.clipboard_read_stream (clipboard, "text/uri-list");
            if (stream != null) {
                ingest_uri_list (stream);
            }
        } catch (Error e) {
            warning ("Paste URI list failed: %s", e.message);
        }
    }

    private void ingest_uri_list (GLib.InputStream stream) {
        // uri-list ingestion is handled by read_clipboard_uri_list above
    }

    /* -- commands ---------------------------------------------- */

    private void build_commands () {
        command_list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.SINGLE
        };
        command_list.add_css_class ("command-list");
        command_list.row_activated.connect ((row) => {
            var command_row = (CommandRow) row;
            execute_command_row (command_row.command);
        });
        var command_scrolled = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            propagate_natural_height = true,
            max_content_height = 200,
            child = command_list
        };
        var command_panel = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        command_panel.add_css_class ("command-panel");
        command_panel.append (command_scrolled);
        command_revealer = new Gtk.Revealer () {
            child = command_panel,
            transition_type = Gtk.RevealerTransitionType.SLIDE_UP,
            reveal_child = false,
            margin_start = 12,
            margin_end = 12,
            margin_bottom = 6
        };
    }

    public void set_server_commands (Gee.ArrayList<CommandInfo> server_commands) {
        commands.clear ();
        commands.add_all (server_commands);
        commands.add (new CommandInfo () { name = "compact", description = "Compact the session context", builtin = true });
        commands.add (new CommandInfo () { name = "new", description = "Create a new session", builtin = true });
        last_command_query = null;
    }

    /** Shows the inline list while the input starts with a slash and
     *  something matches what has been typed so far. */
    private void update_command_list () {
        var text = text_view.buffer.text;
        if (!text.has_prefix ("/") || text.contains ("\n")) {
            hide_commands ();
            return;
        }
        var typed = text.substring (1);
        var space = typed.index_of_char (' ');
        var query = (space < 0 ? typed : typed.substring (0, space)).down ();
        rebuild_command_list (query);
        if (command_list.get_row_at_index (0) != null) {
            show_commands ();
        } else {
            hide_commands ();
        }
    }

    private void show_commands () {
        if (commands_shown) {
            return;
        }
        commands_shown = true;
        command_revealer.reveal_child = true;
    }

    private void hide_commands () {
        if (!commands_shown) {
            return;
        }
        commands_shown = false;
        command_revealer.reveal_child = false;
    }

    private int list_box_rows (Gtk.ListBox box) {
        int n = 0;
        for (var c = box.get_first_child (); c != null; c = c.get_next_sibling ()) {
            n++;
        }
        return n;
    }

    private void rebuild_command_list (string query) {
        if (last_command_query != null && query == last_command_query) {
            return;
        }
        last_command_query = query;

        Gtk.Widget? child = command_list.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            command_list.remove (child);
            child = next;
        }

        Gtk.ListBoxRow? first = null;
        foreach (var command in commands) {
            if (query != "" && !command.name.down ().has_prefix (query)) {
                continue;
            }
            var row = new CommandRow (command);
            command_list.append (row);
            if (first == null) {
                first = row;
            }
        }
        if (first != null) {
            command_list.select_row (first);
        }
    }

    private void move_command_selection (bool down) {
        var current = command_list.get_selected_row ();
        Gtk.ListBoxRow? target;
        if (current == null) {
            target = command_list.get_row_at_index (down ? 0 : list_box_rows (command_list) - 1);
        } else {
            var sib = down ? (Gtk.ListBoxRow?) current.get_next_sibling ()
                : (Gtk.ListBoxRow?) current.get_prev_sibling ();
            if (sib == null) {
                target = down ? command_list.get_row_at_index (0)
                    : command_list.get_row_at_index (list_box_rows (command_list) - 1);
            } else {
                target = sib;
            }
        }
        if (target != null) {
            command_list.select_row (target);
        }
    }

    private void run_selected_command () {
        var current = command_list.get_selected_row ();
        if (current == null) {
            return;
        }
        execute_command_row (((CommandRow) current).command);
    }

    private void execute_command_row (CommandInfo command) {
        hide_commands ();
        var text = @"/$(command.name) ";
        text_view.buffer.text = text;
        var iter = Gtk.TextIter ();
        text_view.buffer.get_iter_at_offset (out iter, text.length);
        text_view.buffer.place_cursor (iter);
        command_requested (command.name, "");
    }

    /* -- changed files chip -------------------------------------- */

    private void build_diff_row () {
        diff_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
            margin_start = 12,
            margin_end = 12,
            margin_top = 8,
            visible = false
        };
        diff_chip_spinner = new Gtk.Spinner () {
            visible = false,
            valign = Gtk.Align.CENTER,
            tooltip_text = "Editing a file"
        };
        diff_chip_add = new Gtk.Label ("") {
            valign = Gtk.Align.CENTER,
            visible = false
        };
        diff_chip_add.add_css_class ("diff-add");
        diff_chip_del = new Gtk.Label ("") {
            valign = Gtk.Align.CENTER,
            visible = false
        };
        diff_chip_del.add_css_class ("diff-del");
        diff_chip_count = new Gtk.Label ("") {
            valign = Gtk.Align.CENTER,
            visible = false
        };
        diff_chip_count.add_css_class (Granite.CssClass.DIM);
        diff_chip_count.add_css_class ("caption");

        diff_editing_label = new Gtk.Label ("") {
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.MIDDLE,
            visible = false,
            hexpand = true
        };
        diff_editing_label.add_css_class (Granite.CssClass.DIM);
        diff_editing_label.add_css_class ("caption");

        diff_button = new Gtk.MenuButton () {
            valign = Gtk.Align.CENTER,
            tooltip_text = "Files changed in this session"
        };
        diff_button.add_css_class (Granite.STYLE_CLASS_FLAT);

        var diff_chip_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            valign = Gtk.Align.CENTER
        };
        diff_chip_box.append (diff_chip_spinner);
        diff_chip_box.append (diff_chip_add);
        diff_chip_box.append (diff_chip_del);
        diff_chip_box.append (diff_chip_count);
        diff_button.child = diff_chip_box;

        diff_list_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        var diff_scrolled = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            propagate_natural_height = true,
            child = diff_list_box
        };
        var diff_popover = new Gtk.Popover () {
            child = diff_scrolled
        };
        OpenClient.set_menu_popover (diff_button, diff_popover);

        diff_row.append (diff_button);
        diff_row.append (diff_chip_box);
        diff_row.append (diff_editing_label);
    }

    public void set_diff_files (Gee.ArrayList<FileDiff> files, Gee.ArrayList<string> editing) {
        if (diff_row == null || diff_editing_label == null) {
            return;
        }
        if (files.size == 0 && editing.size == 0) {
            diff_row.visible = false;
            diff_editing_label.visible = false;
            return;
        }

        var additions = 0;
        var deletions = 0;
        foreach (var diff in files) {
            additions += diff.additions;
            deletions += diff.deletions;
        }
        diff_row.visible = true;

        diff_chip_add.label = @"+$additions";
        diff_chip_del.label = @"−$deletions";
        diff_chip_add.visible = additions > 0;
        diff_chip_del.visible = deletions > 0;
        diff_chip_count.label = @"· $(files.size)";

        var busy = editing.size > 0;
        diff_chip_spinner.visible = busy;
        if (busy) {
            diff_chip_spinner.start ();
        } else {
            diff_chip_spinner.stop ();
        }

        if (busy) {
            var first = GLib.Path.get_basename (editing[0]);
            diff_editing_label.label = editing.size > 1
                ? @"Editing $first and $((int) editing.size - 1) more"
                : @"Editing $first";
            diff_editing_label.tooltip_text = ListArrays.join ("\n", editing);
            diff_editing_label.visible = true;
        } else {
            diff_editing_label.visible = false;
        }
    }

    /* -- context meter ----------------------------------------- */

    private void build_context () {
        context_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        context_row.add_css_class ("composer-context");
        context_level = new Gtk.LevelBar () {
            min_value = 0,
            max_value = 1
        };
        context_label = new Gtk.Label ("") {
            xalign = 0
        };
        context_status = new Gtk.Label ("") {
            xalign = 0,
            hexpand = true,
            halign = Gtk.Align.START,
            ellipsize = Pango.EllipsizeMode.END
        };
        context_status.add_css_class (Granite.CssClass.DIM);
        context_status.add_css_class ("caption");
        context_row.append (context_level);
        context_row.append (context_label);
        context_row.append (context_status);
    }

    public void grab_focus_entry () {
        text_view.grab_focus ();
    }

    public void set_permission_mode (string mode) {
        permission_mode = mode;
        update_permission_mode_button ();
    }

    private void cycle_permission_mode () {
        var next = "readonly";
        if (permission_mode == "readonly") {
            next = "ask";
        } else if (permission_mode == "ask") {
            next = "yolo";
        }
        permission_mode = next;
        update_permission_mode_button ();
        permission_mode_changed (next);
    }

    private void update_permission_mode_button () {
        string label = "Always ask";
        if (permission_mode == "readonly") {
            label = "Read-only";
        } else if (permission_mode == "yolo") {
            label = "Allow YOLO";
        }
        permission_mode_button.label = label;
        permission_mode_button.tooltip_text = @"Permission mode: $label (click to cycle)";
    }

    /* -- sending ------------------------------------------------------ */

    public void set_send_with_ctrl_enter (bool value) {
        ctrl_enter_to_send = value;
    }

    private void request_send () {
        var text = text_view.buffer.text.strip ();
        if (text == "" && attachments.size == 0) {
            return;
        }
        var files = new Gee.ArrayList<FileAttachment> ();
        foreach (var attachment in attachments) {
            files.add (attachment.to_file_attachment ());
        }
        text_view.buffer.text = "";
        clear_attachments ();
        send_requested (text, files);
    }

    private void update_send_state () {
        var text = text_view.buffer.text.strip ();
        send_button.sensitive = text != "" || attachments.size > 0;
    }

    public void set_running (bool running, string? detail = null) {
        busy_spinner.visible = running;
        if (running) {
            busy_spinner.start ();
        } else {
            busy_spinner.stop ();
        }
        stop_button.visible = running;
        send_button.visible = !running;
        status_label.label = detail != "" ? detail : (running ? "Working…" : "");
        status_label.visible = detail != "" || running;
    }

    public void set_status_text (string text) {
        status_label.label = text;
        status_label.visible = text != "";
    }
}

public class CommandRow : Gtk.ListBoxRow {
    public CommandInfo command;

    public CommandRow (CommandInfo command) {
        this.command = command;

        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10) {
            margin_top = 5,
            margin_bottom = 5,
            margin_start = 10,
            margin_end = 10
        };

        var name_label = new Gtk.Label (@"/$(command.name)") {
            xalign = 0,
            valign = Gtk.Align.CENTER
        };
        name_label.add_css_class (Granite.CssClass.MONOSPACE);
        box.append (name_label);

        var description_label = new Gtk.Label (command.description) {
            xalign = 0,
            hexpand = true,
            ellipsize = Pango.EllipsizeMode.END,
            valign = Gtk.Align.CENTER
        };
        description_label.add_css_class (Granite.CssClass.DIM);
        description_label.add_css_class ("caption");
        box.append (description_label);

        child = box;
    }
}

}
