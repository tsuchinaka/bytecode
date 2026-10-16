/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Prompt composer: agent question dock, permission banner,
 * attachment chips, multiline entry, context meter, model and
 * agent pickers, stop and send buttons.
 *
 * Attachments arrive via clipboard paste (Ctrl+V with an image) or
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
    private Gtk.MenuButton diff_button;
    private Gtk.Box? diff_row = null;
    private Gtk.Label? diff_editing_label = null;
    private Gtk.Box diff_list_box;
    private Gtk.Label diff_chip_add;
    private Gtk.Label diff_chip_del;
    private Gtk.Label diff_chip_count;
    private Gtk.Spinner diff_chip_spinner;
    private Gtk.Button permission_mode_button;
    private string permission_mode = "ask";
    private BrailleSpinner busy_spinner;
    private Gtk.Revealer command_revealer;
    private Gtk.ListBox command_list;
    /** True while the inline command list is showing. */
    private bool commands_shown = false;
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
    /** Last query the command list was built for, so typing that does
     *  not change it does not rebuild the rows. Null means "never
     *  built": the old sentinel started with NUL and was therefore the
     *  empty string, which made the first "/" (an empty query) look
     *  already built and show no list. */
    private string? last_command_query = null;
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

        /* Changed files, right above the input it belongs to: the chip
         *  summarises the session and names the file being written. */
        diff_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
            margin_start = 12,
            margin_end = 12,
            margin_top = 8,
            visible = false
        };
        diff_editing_label = new Gtk.Label ("") {
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.MIDDLE,
            visible = false,
            hexpand = true
        };
        diff_editing_label.add_css_class (Granite.CssClass.DIM);
        diff_editing_label.add_css_class ("caption");
        diff_row.append (diff_editing_label);
        frame.append (diff_row);

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
            min_content_height = 48,
            max_content_height = 150,
            child = text_view
        };

        placeholder_label = new Gtk.Label ("Send a message") {
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

        var drop_target = new Gtk.DropTarget (typeof (Gdk.FileList), Gdk.DragAction.COPY);
        drop_target.drop.connect ((value, x, y) => on_files_dropped (value));
        text_view.add_controller (drop_target);

        /* Context meter: a slim line under the input, with its reading
         *  as a quiet caption rather than a heavy bar across the card. */
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
            margin_top = 4,
            margin_bottom = 2,
            visible = false
        };
        context_row.add_css_class ("composer-context");
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
            max_width_chars = 42,
            hexpand = true
        };
        status_label.add_css_class (Granite.CssClass.DIM);
        status_label.add_css_class ("caption");
        status_label.add_css_class ("composer-status");

        /* Changed-files chip: sits directly above the input and opens
         *  the list of files the agent has touched (one row per path),
         *  with a spinner on anything being written right now. */
        diff_button = new Gtk.MenuButton () {
            valign = Gtk.Align.CENTER,
            tooltip_text = "Files changed in this session"
        };
        diff_button.add_css_class (Granite.STYLE_CLASS_FLAT);

        var diff_chip_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            valign = Gtk.Align.CENTER
        };
        diff_chip_box.add_css_class ("diff-chip");
        diff_chip_spinner = new Gtk.Spinner () {
            visible = false,
            tooltip_text = "Editing a file"
        };
        /* Same colouring as every other diff readout in the app, and a
         *  count of zero stays out of the way instead of reading
         *  "+5 −0". */
        diff_chip_add = chip_count ("diff-add");
        diff_chip_del = chip_count ("diff-del");
        diff_chip_count = new Gtk.Label ("") {
            valign = Gtk.Align.CENTER,
            margin_start = 2
        };
        diff_chip_count.add_css_class (Granite.CssClass.DIM);
        diff_chip_count.add_css_class ("caption");
        diff_chip_box.append (diff_chip_spinner);
        diff_chip_box.append (diff_chip_add);
        diff_chip_box.append (diff_chip_del);
        diff_chip_box.append (diff_chip_count);
        diff_button.child = diff_chip_box;

        diff_list_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        var diff_scrolled = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            propagate_natural_width = true,
            /* Without this the scroller asks for the child's minimum
             *  height, which for a stack of rows is a sliver: the
             *  popover came out ~50px tall and the rows spilled out of
             *  it. Natural height takes the rows up to the cap. */
            propagate_natural_height = true,
            child = diff_list_box
        };
        var diff_popover = new Gtk.Popover () {
            child = diff_scrolled
        };
        OpenClient.set_menu_popover (diff_button, diff_popover);

        /* The row is built before this button exists (it has to sit
         *  above the input), so the button joins it here. Appending it
         *  while it was still null silently dropped the chip: the row
         *  showed the edited file's name with nothing to open. */
        if (diff_row != null) {
            diff_row.prepend (diff_button);
        }

        attach_button = new Gtk.Button.from_icon_name ("mail-attachment-symbolic") {
            tooltip_text = "Attach files (or paste and drop them here)",
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
        permission_mode_button.add_css_class ("composer-chip");
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
        buttons.append (attach_button);
        buttons.append (stop_button);
        buttons.append (send_button);

        /* Inline slash-command list: it lives in the card, right above
         *  the input being typed into, instead of floating over the
         *  conversation as a popup. */
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

        frame.append (command_revealer);
        frame.append (overlay);
        frame.append (context_row);
        frame.append (buttons);
        append (frame);
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
         *  show even if the query did not change. */
        last_command_query = null;
    }

    /** Shows the inline list while the input starts with a slash and
     *  something matches what has been typed so far. */
    private void update_command_popup () {
        var text = text_view.buffer.text;
        if (!text.has_prefix ("/") || text.contains ("\n")) {
            hide_commands ();
            return;
        }
        var typed = text.substring (1);
        /* The query is everything up to the first space. Splitting an
         *  empty string (just "/" typed) yields no element at all, which
         *  used to hand a null to the filter. */
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
        hide_commands ();
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

    /** Rebuilds the changed-files chip and its popover: one row per
     *  path, plus a spinner on files being written right now (including
     *  ones the diff has not caught up with yet). */
    public void set_diff_files (Gee.ArrayList<FileDiff> files, Gee.ArrayList<string> editing) {
        if (diff_row == null || diff_editing_label == null) {
            return;
        }
        if (files.size == 0 && editing.size == 0) {
            diff_row.visible = false;
            diff_editing_label.visible = false;
            clear_box (diff_list_box);
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
        /* Zero counts say nothing worth the pixels: a file with only
         *  additions reads "+5 · 1", not "+5 −0 · 1". */
        diff_chip_add.visible = additions > 0;
        diff_chip_del.visible = deletions > 0;
        diff_chip_count.label = @"· $(files.size)";
        diff_button.tooltip_text = files.size == 1
            ? "1 file changed in this session"
            : @"$(files.size) files changed in this session";
        var busy = editing.size > 0;
        diff_chip_spinner.visible = busy;
        diff_chip_spinner.spinning = busy;
        /* Name the file being written, so the input shows what is
         *  changing without opening anything. */
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

        clear_box (diff_list_box);
        var listed = new Gee.HashSet<string> ();
        foreach (var diff in files) {
            listed.add (diff.path);
            diff_list_box.append (new ChangeRow (diff.path, diff.additions,
                diff.deletions, diff.status, editing.contains (diff.path)));
        }
        /* Files being written that the diff does not know about yet
         *  (a brand-new file, or a fetch still in flight). */
        foreach (var path in editing) {
            if (listed.contains (path)) {
                continue;
            }
            diff_list_box.append (new ChangeRow (path, -1, -1, "", true));
        }
    }

    /** One +/− number on the chip, hidden until it has something to
     *  say. */
    private static Gtk.Label chip_count (string css_class) {
        var label = new Gtk.Label ("") {
            valign = Gtk.Align.CENTER,
            visible = false
        };
        label.add_css_class (css_class);
        return label;
    }

    private static void clear_box (Gtk.Box box) {
        Gtk.Widget? child = box.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            box.remove (child);
            child = next;
        }
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
        /* Files copied from the file manager. */
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

        /* Anything but a directory: an image gets a preview, every
         *  other file a named chip in the bubble. Refusing non-images
         *  meant the paperclip did nothing at all for them, with no
         *  way to tell why. */
        if (mime == null || mime == "inode/directory") {
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
