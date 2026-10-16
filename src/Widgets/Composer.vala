/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Prompt composer: agent question dock, permission banner,
 * attachment chips, multiline entry, context meter, model and
 * agent pickers, stop and send buttons.
 *
 * Images arrive via clipboard paste (Ctrl+V with an image) or
 * file drag-and-drop. They are staged as files and sent as
 * `file://` prompt attachments.
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
            uri = uri,
            name = name,
            mime = mime
        };
    }
}

public class Composer : Gtk.Box {
    public signal void send_requested (string text, Gee.ArrayList<FileAttachment> files);
    public signal void stop_requested ();
    public signal void permission_decision (string request_id, string decision);
    public signal void form_answered (string form_id, Json.Node answer);
    public signal void form_cancelled (string form_id);
    public signal void diff_requested ();
    public signal void command_requested (string name, string text);
    public signal void permission_mode_changed (string mode);

    public ModelChooser model_chooser { get; private set; }
    public AgentChooser agent_chooser { get; private set; }
    public VariantChooser variant_chooser { get; private set; }
    /** When true, Enter makes a new line and Ctrl+Enter sends. */
    public bool ctrl_enter_to_send { get; set; default = false; }

    private Gtk.TextView text_view;
    private Gtk.Label placeholder_label;
    private Gtk.Button send_button;
    private Gtk.Button stop_button;
    private Gtk.Button attach_button;
    private Gtk.Label status_label;
    private Gtk.Button diff_button;
    private Gtk.Button permission_mode_button;
    private string permission_mode = "ask";
    private BrailleSpinner busy_spinner;
    private Gtk.Popover command_popover;
    private Gtk.ListBox command_list;
    private Gee.ArrayList<CommandInfo> commands;
    private Gtk.LevelBar context_bar;
    private Gtk.Label context_label;
    private Gtk.Box context_row;

    private Gtk.Revealer permission_revealer;
    private Gtk.Label permission_label;
    private string permission_request_id = "";

    private Gtk.Revealer form_revealer;
    private FormCard form_card;

    private Gtk.Revealer attachments_revealer;
    private Gtk.FlowBox attachments_box;
    private Gee.ArrayList<Attachment> attachments;
    /** Decoded 64px attachment thumbnails, keyed by file path, so
     *  re-listing the chips doesn't re-decode every image. */
    private Gee.HashMap<string, Gdk.Pixbuf?> thumbnail_cache;
    /** Last query the slash-command popup was built for, so typing
     *  that doesn't change it doesn't rebuild the rows. */
    private string last_command_query = "\x00sentinel";
    /** Last meter value/band/label written, so repeated usage events
     *  with the same numbers don't invalidate layout. */
    private double last_context_value = -1.0;
    private string last_context_band = "";
    private string last_context_label = "\x00sentinel";

    public Composer () {
        Object (
            orientation: Gtk.Orientation.VERTICAL,
            spacing: 6
        );
        margin_top = 10;
        margin_bottom = 12;
        margin_start = 12;
        margin_end = 12;

        attachments = new Gee.ArrayList<Attachment> ();
        thumbnail_cache = new Gee.HashMap<string, Gdk.Pixbuf?> ();

        commands = new Gee.ArrayList<CommandInfo> ();
        commands.add (new CommandInfo () { name = "compact", description = "Compact the session context", builtin = true });
        commands.add (new CommandInfo () { name = "new", description = "Create a new session", builtin = true });
        commands.add (new CommandInfo () { name = "diff", description = "View the session changes", builtin = true });

        /* Agent question dock */
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
        append (form_revealer);

        /* Permission request banner */
        var permission_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
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
        append (permission_revealer);

        /* Input card: same elementary "card" look as the new-session
         * prompt (see NewSessionView): background + shadow from the
         * card class, small corner radius, inner padding. */
        var frame = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        frame.add_css_class (Granite.CssClass.CARD);
        frame.add_css_class ("rounded");
        frame.add_css_class ("composer-card");

        attachments_box = new Gtk.FlowBox () {
            column_spacing = 8,
            row_spacing = 8,
            homogeneous = false,
            selection_mode = Gtk.SelectionMode.NONE,
            margin_top = 8,
            margin_start = 12,
            margin_end = 12
        };
        attachments_revealer = new Gtk.Revealer () {
            child = attachments_box,
            transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN,
            reveal_child = false
        };
        frame.append (attachments_revealer);

        text_view = new Gtk.TextView () {
            wrap_mode = Gtk.WrapMode.WORD_CHAR,
            top_margin = 10,
            bottom_margin = 10,
            left_margin = 14,
            right_margin = 14,
            accepts_tab = false
        };
        text_view.add_css_class ("composer-entry");

        /* Content-aware height: one line by default, growing with the
         * text up to a few lines, then scrolling instead of eating the
         * whole chat. */
        var input_scrolled = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            vscrollbar_policy = Gtk.PolicyType.AUTOMATIC,
            propagate_natural_height = true,
            min_content_height = 44,
            max_content_height = 150,
            child = text_view
        };

        placeholder_label = new Gtk.Label ("Send a message (paste or drop images to attach)") {
            xalign = 0,
            yalign = 0,
            halign = Gtk.Align.START,
            valign = Gtk.Align.START,
            margin_top = 10,
            margin_start = 14,
            can_target = false
        };
        placeholder_label.add_css_class (Granite.CssClass.DIM);

        text_view.buffer.changed.connect (() => {
            placeholder_label.visible = text_view.buffer.get_char_count () == 0;
            update_command_popup ();
        });

        var overlay = new Gtk.Overlay () {
            child = input_scrolled,
            hexpand = true
        };
        overlay.add_overlay (placeholder_label);

        /* Capture phase so our Ctrl+V image handling runs before the
         * TextView's built-in paste, which would otherwise insert the
         * file URI as plain text. */
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

            /* Slash-command popup keyboard handling. */
            if (command_popover.visible) {
                if (keyval == Gdk.Key.Escape) {
                    command_popover.popdown ();
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

        var drop_target = new Gtk.DropTarget (typeof (Gdk.FileList), Gdk.DragAction.COPY);
        drop_target.drop.connect ((value, x, y) => on_files_dropped (value));
        text_view.add_controller (drop_target);

        /* Context meter row */
        context_bar = new Gtk.LevelBar.for_interval (0.0, 1.0) {
            hexpand = true,
            valign = Gtk.Align.CENTER
        };
        context_label = new Gtk.Label ("") {
            xalign = 1,
            valign = Gtk.Align.CENTER
        };
        context_label.add_css_class (Granite.CssClass.DIM);
        context_label.add_css_class ("caption");
        context_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
            margin_start = 12,
            margin_end = 12,
            visible = false
        };
        context_row.append (context_bar);
        context_row.append (context_label);

        /* Bottom row: choosers, status, actions */
        agent_chooser = new AgentChooser ();
        model_chooser = new ModelChooser ();
        variant_chooser = new VariantChooser ();

        busy_spinner = new BrailleSpinner ();

        status_label = new Gtk.Label ("") {
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.END,
            hexpand = true
        };
        status_label.add_css_class ("message-meta");

        diff_button = new Gtk.Button () {
            valign = Gtk.Align.CENTER,
            visible = false,
            tooltip_text = "View changes"
        };
        diff_button.add_css_class (Granite.STYLE_CLASS_FLAT);
        diff_button.add_css_class ("diff-chip");
        diff_button.clicked.connect (() => diff_requested ());

        attach_button = new Gtk.Button.from_icon_name ("mail-attachment-symbolic") {
            tooltip_text = "Attach images",
            valign = Gtk.Align.CENTER
        };
        attach_button.add_css_class (Granite.STYLE_CLASS_FLAT);
        attach_button.clicked.connect (() => pick_images ());

        stop_button = new Gtk.Button.from_icon_name ("media-playback-stop") {
            tooltip_text = "Stop",
            visible = false,
            valign = Gtk.Align.CENTER
        };
        stop_button.add_css_class (Granite.STYLE_CLASS_FLAT);
        stop_button.clicked.connect (() => stop_requested ());

        send_button = new Gtk.Button.from_icon_name ("mail-send") {
            tooltip_text = "Send (Enter)",
            valign = Gtk.Align.CENTER
        };
        send_button.add_css_class ("suggested-action");
        send_button.clicked.connect (() => request_send ());

        permission_mode_button = new Gtk.Button () {
            tooltip_text = "Permission mode (click to cycle)",
            valign = Gtk.Align.CENTER
        };
        permission_mode_button.add_css_class (Granite.STYLE_CLASS_FLAT);
        permission_mode_button.clicked.connect (() => cycle_permission_mode ());
        update_permission_mode_button ();

        var buttons = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            margin_start = 8,
            margin_end = 8,
            margin_bottom = 8
        };
        buttons.append (permission_mode_button);
        buttons.append (agent_chooser);
        buttons.append (model_chooser);
        buttons.append (variant_chooser);
        buttons.append (busy_spinner);
        buttons.append (status_label);
        buttons.append (diff_button);
        buttons.append (attach_button);
        buttons.append (stop_button);
        buttons.append (send_button);

        frame.append (overlay);
        frame.append (context_row);
        frame.append (buttons);
        append (frame);

        /* Slash-command popup, anchored above the input card. */
        command_popover = new Gtk.Popover () {
            position = Gtk.PositionType.TOP
        };
        command_list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.SINGLE
        };
        command_list.add_css_class ("picker-list");
        command_list.row_activated.connect ((row) => {
            var command_row = (CommandRow) row;
            execute_command_row (command_row.command);
        });
        var command_scrolled = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            propagate_natural_width = true,
            propagate_natural_height = true,
            max_content_height = 220,
            child = command_list
        };
        command_popover.child = command_scrolled;
        command_popover.set_parent (frame);
    }

    public void set_server_commands (Gee.ArrayList<CommandInfo> server_commands) {
        /* Keep builtins, replace the server-provided tail. */
        var builtins = new Gee.ArrayList<CommandInfo> ();
        foreach (var command in commands) {
            if (command.builtin) {
                builtins.add (command);
            }
        }
        commands = builtins;
        foreach (var command in server_commands) {
            commands.add (command);
        }
        /* The row list is now stale: force a rebuild on the next
         *  popup even if the query didn't change. */
        last_command_query = "\x00sentinel";
    }

    private void update_command_popup () {
        var text = text_view.buffer.text;
        if (!text.has_prefix ("/") || text.contains ("\n")) {
            command_popover.popdown ();
            return;
        }
        var query = text.substring (1).split (" ")[0].down ();
        rebuild_command_list (query);
        if (command_list.get_row_at_index (0) != null) {
            command_popover.popup ();
        } else {
            command_popover.popdown ();
        }
    }

    private void rebuild_command_list (string query) {
        if (query == last_command_query) {
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
        var selected = command_list.get_selected_row ();
        if (selected == null) {
            return;
        }
        var next = down ? selected.get_next_sibling () : selected.get_prev_sibling ();
        while (next != null && !(next is CommandRow)) {
            next = down ? next.get_next_sibling () : next.get_prev_sibling ();
        }
        if (next != null) {
            command_list.select_row ((Gtk.ListBoxRow) next);
        }
    }

    private void run_selected_command () {
        var row = command_list.get_selected_row ();
        if (row == null) {
            return;
        }
        execute_command_row (((CommandRow) row).command);
    }

    private void execute_command_row (CommandInfo command) {
        command_popover.popdown ();
        text_view.buffer.text = "";
        command_requested (command.name, "");
    }

    public void grab_focus_entry () {
        text_view.grab_focus ();
    }

    public void clear () {
        text_view.buffer.text = "";
        clear_attachments ();
    }

    public void set_running (bool running, string? detail = null) {
        stop_button.visible = running;
        if (running) {
            busy_spinner.start ();
            status_label.label = detail ?? "Generating…";
        } else {
            busy_spinner.stop ();
        }
    }

    public void set_status_text (string text) {
        if (!stop_button.visible) {
            status_label.label = text;
        }
    }

    public void set_diff_stat (int files, int additions, int deletions) {
        if (files <= 0) {
            diff_button.visible = false;
            return;
        }
        diff_button.visible = true;
        diff_button.label = @"+$additions −$deletions · $files";
    }

    public void set_context (double fraction, string label) {
        if (fraction < 0.0) {
            context_row.visible = false;
            return;
        }
        context_row.visible = true;
        var clamped = double.min (1.0, double.max (0.0, fraction));
        /* Guarded: usage events arrive several times per second, and
         *  writing an identical value (re)invalidates layout/style. */
        if (clamped != last_context_value) {
            context_bar.value = clamped;
            last_context_value = clamped;
        }
        /* Color ramp lives here, not in offset selectors (see style.css). */
        string band = clamped >= 0.92 ? "context-full"
            : (clamped >= 0.75 ? "context-high" : "");
        if (band != last_context_band) {
            context_bar.remove_css_class ("context-high");
            context_bar.remove_css_class ("context-full");
            if (band != "") {
                context_bar.add_css_class (band);
            }
            last_context_band = band;
        }
        if (label != last_context_label) {
            context_label.label = label;
            context_label.tooltip_text = @"Context used: $(label)";
            last_context_label = label;
        }
    }

    /* -- permissions -------------------------------------------------- */

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

    /* -- permissions --------------------------------------------------- */
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

    /* -- forms -------------------------------------------------------- */

    public void show_form (FormInfo form) {
        form_card.set_form (form);
        form_revealer.reveal_child = true;
    }

    public void hide_form () {
        form_revealer.reveal_child = false;
        form_card.set_form (null);
    }

    /* -- attachments -------------------------------------------------- */

    private bool try_paste_image () {
        var clipboard = text_view.get_clipboard ();
        var formats = clipboard.get_formats ();
        if (formats == null) {
            return false;
        }
        /* Raw pixels (screenshots, copied images) first. */
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
        /* Files copied from the file manager: attach the images,
         * ignore the rest (the composer is images-only). */
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
        /* Some file managers only advertise text/uri-list. */
        if (formats.contain_mime_type ("text/uri-list")) {
            read_clipboard_uri_list.begin (clipboard);
            return true;
        }
        return false;
    }

    /** Reads a uri-list from the clipboard and ingests it. */
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
        var data = new GLib.DataInputStream (stream);
        try {
            string? line;
            size_t length;
            while ((line = data.read_line (out length)) != null) {
                var uri = line.strip ();
                if (uri == "" || uri.has_prefix ("#")) {
                    continue;
                }
                attach_file (GLib.File.new_for_uri (uri));
            }
        } catch (Error e) {
            warning ("Read URI list failed: %s", e.message);
        }
    }

    private bool on_files_dropped (GLib.Value value) {
        var list = value as Gdk.FileList;
        if (list == null) {
            return false;
        }
        var accepted = false;
        foreach (var file in list.get_files ()) {
            attach_file (file);
            accepted = true;
        }
        return accepted;
    }

    private void pick_images () {
        pick_images_async.begin ();
    }

    private async void pick_images_async () {
        var files = yield Portals.pick_images ();
        if (files == null) {
            return;
        }
        foreach (var file in files) {
            attach_file (file);
        }
    }

    private void attach_file (GLib.File file) {
        attach_file_async.begin (file);
    }

    private async void attach_file_async (GLib.File file) {
        var path = file.get_path ();
        if (path == null) {
            return;
        }

        string? mime = null;

        /* MIME sniffing hits the disk; keep it off the main thread. */
        Work.submit_with_resume (() => {
            try {
                var info = file.query_info ("standard::content-type", GLib.FileQueryInfoFlags.NONE);
                mime = info.get_content_type ();
            } catch (Error e) {
                warning ("Could not read %s: %s", path, e.message);
            }
        }, attach_file_async.callback);

        yield;

        if (mime == null || !mime.has_prefix ("image/")) {
            return;
        }
        var attachment = new Attachment () {
            path = path,
            name = GLib.Path.get_basename (path),
            mime = mime
        };
        attachments.add (attachment);
        rebuild_attachment_chips ();
    }

    private void attach_texture (Gdk.Texture texture, string name) {
        var dir = GLib.Path.build_filename (GLib.Environment.get_user_cache_dir (), "opencode-client", "paste");
        var stamp = GLib.get_real_time ().to_string ();
        var path = GLib.Path.build_filename (dir, @"image-$stamp.png");

        /* Encode on the main thread (GdkTexture is not thread-safe),
         * then write the file on a worker. */
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

    /** Shows a decoded pixbuf in an image widget. Gtk.Image's pixbuf
     *  setter was deprecated in GTK 4.12 in favour of taking a
     *  Gdk.Paintable, so the pixbuf is wrapped once. */
    private static void set_picture (Gtk.Image image, Gdk.Pixbuf pixbuf) {
        image.set_from_paintable (pixbuf_texture (pixbuf));
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

            var thumbnail = new Gtk.Image.from_icon_name ("image-x-generic");
            chip.append (thumbnail);

            var label = new Gtk.Label (attachment.name) {
                xalign = 0,
                ellipsize = Pango.EllipsizeMode.MIDDLE,
                max_width_chars = 20
            };
            chip.append (label);

            var captured = attachment;
            var remove_button = new Gtk.Button.from_icon_name ("window-close") {
                tooltip_text = "Remove",
                valign = Gtk.Align.CENTER
            };
            remove_button.add_css_class (Granite.STYLE_CLASS_FLAT);
            remove_button.clicked.connect (() => {
                attachments.remove (captured);
                rebuild_attachment_chips ();
            });
            chip.append (remove_button);

            attachments_box.append (chip);

            /* Decode the thumbnail off the main thread, then swap it in.
             *  Result is cached per path: re-listing the chips (adding
             *  or removing one attachment) used to re-submit a decode
             *  for every attachment every time. */
            var path = attachment.path;
            if (thumbnail_cache.has_key (path)) {
                var cached = thumbnail_cache[path];
                if (cached != null) {
                    set_picture (thumbnail, cached);
                }
            } else {
                Work.submit (() => {
                    Gdk.Pixbuf? pixbuf = null;
                    try {
                        pixbuf = new Gdk.Pixbuf.from_file_at_scale (path, 64, 64, true);
                    } catch (Error e) {
                    }
                    thumbnail_cache[path] = pixbuf;
                    Idle.add (() => {
                        if (pixbuf != null) {
                            set_picture (thumbnail, pixbuf);
                        }
                        return false;
                    });
                });
            }
        }

        attachments_revealer.reveal_child = attachments.size > 0;
    }

    private void clear_attachments () {
        attachments.clear ();
        rebuild_attachment_chips ();
    }

    /* -- sending ------------------------------------------------------ */

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
}


public class CommandRow : Gtk.ListBoxRow {
    public CommandInfo command;

    public CommandRow (CommandInfo command) {
        this.command = command;

        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10) {
            margin_top = 6,
            margin_bottom = 6,
            margin_start = 6,
            margin_end = 6
        };

        var name_label = new Gtk.Label (@"/$(command.name)") {
            xalign = 0
        };
        name_label.add_css_class (Granite.CssClass.MONOSPACE);
        box.append (name_label);

        var description_label = new Gtk.Label (command.description) {
            xalign = 0,
            hexpand = true,
            ellipsize = Pango.EllipsizeMode.END
        };
        description_label.add_css_class (Granite.CssClass.DIM);
        description_label.add_css_class ("caption");
        box.append (description_label);

        child = box;
    }
}

}
