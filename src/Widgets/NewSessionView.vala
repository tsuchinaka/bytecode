/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * New-session page, built with elementary's own idioms: a welcome-style
 * hero (large app icon, title-1 heading, dim subtitle), a Workspace
 * section that must be set before sending, the prompt card (Granite's
 * "card" style class), and a Suggestions section of icon buttons. The
 * server fixes a session's directory at creation time, so the folder
 * is required up front, so Send stays insensitive until one is set.
 */

namespace OpenClient {

public class NewSessionView : Gtk.Box {
    public signal void create_requested (string directory, string text, Gee.ArrayList<FileAttachment> files);
    public signal void cancelled ();
    /** Emitted whenever a workspace folder is picked (recent or fresh)
     *  so the app can remember it for the recents list. */
    public signal void folder_selected (string directory);

    public ModelChooser model_chooser { get; private set; }
    public AgentChooser agent_chooser { get; private set; }
    public VariantChooser variant_chooser { get; private set; }
    /** When true, Enter makes a new line and Ctrl+Enter sends. */
    public bool ctrl_enter_to_send { get; set; default = false; }

    /** Pending model/agent choice. Empty ids mean "server default". */
    public string pending_provider_id { get; private set; default = ""; }
    public string pending_model_id { get; private set; default = ""; }
    public string pending_variant { get; private set; default = ""; }
    public string pending_agent_id { get; private set; default = ""; }

    private string folder = "";
    private Gtk.MenuButton folder_button;
    private Gtk.Popover folder_popover;
    private Gtk.ListBox recent_list;
    private Gee.ArrayList<string> recent_folders;
    private Gtk.Label folder_label;
    private Gtk.TextView text_view;
    private Gtk.Label placeholder_label;
    private Gtk.Label hint_label;
    private Gtk.Button send_button;

    private Gtk.Revealer attachments_revealer;
    private Gtk.FlowBox attachments_box;
    private Gee.ArrayList<Attachment> attachments;
    /** Decoded 64px attachment thumbnails, keyed by file path, so
     *  re-listing the chips doesn't re-decode every image. */
    private Gee.HashMap<string, Gdk.Pixbuf?> thumbnail_cache;

    private const string[] SUGGESTIONS = {
        "Explore the Codebase",
        "Catch Me Up",
        "Weigh My Options",
        "Start Feature Planning",
        "Debug an Issue",
        "Review My Changes"
    };

    /* Full-color elementary action icons, one per suggestion. */
    private const string[] SUGGESTION_ICONS = {
        "edit-find",
        "view-refresh",
        "dialog-question",
        "document-new",
        "dialog-warning",
        "document-open-recent"
    };

    public NewSessionView () {
        Object (
            orientation: Gtk.Orientation.VERTICAL,
            spacing: 0,
            hexpand: true,
            vexpand: true
        );
        add_css_class (Granite.STYLE_CLASS_VIEW);

        attachments = new Gee.ArrayList<Attachment> ();
        thumbnail_cache = new Gee.HashMap<string, Gdk.Pixbuf?> ();

        var column = new Gtk.Box (Gtk.Orientation.VERTICAL, 14) {
            halign = Gtk.Align.CENTER,
            valign = Gtk.Align.CENTER,
            hexpand = true,
            vexpand = true,
            width_request = 640,
            margin_top = 20,
            margin_bottom = 20,
            margin_start = 24,
            margin_end = 24
        };

        /* -- Page title and a short explanation. Title case (AP style)
         *  for the H1 heading; the subtitle is descriptive text, so it
         *  stays sentence case (see hig/reference/text.md). -- */
        var title_label = new Gtk.Label ("What Are We Working On?") {
            xalign = 0.5f,
            wrap = true,
            justify = Gtk.Justification.CENTER
        };
        title_label.add_css_class (Granite.HeaderLabel.Size.H1.to_string ());

        var subtitle_label = new Gtk.Label (
            "Choose a workspace folder, then describe what you'd like to build.") {
            xalign = 0.5f,
            wrap = true,
            justify = Gtk.Justification.CENTER
        };
        subtitle_label.add_css_class (Granite.CssClass.DIM);

        var hero = new Gtk.Box (Gtk.Orientation.VERTICAL, 4) {
            halign = Gtk.Align.CENTER
        };
        hero.append (title_label);
        hero.append (subtitle_label);
        column.append (hero);

        /* -- Workspace: required before the session can start. -- */
        var workspace_header = new Granite.HeaderLabel ("Workspace") {
            halign = Gtk.Align.START
        };
        column.append (workspace_header);

        folder_label = new Gtk.Label ("Choose a workspace folder…") {
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.MIDDLE,
            hexpand = true
        };
        var folder_icon = new Gtk.Image.from_icon_name ("folder-open") {
            pixel_size = 16
        };
        var folder_chevron = new Gtk.Image.from_icon_name ("go-next-symbolic") {
            pixel_size = 12
        };
        folder_chevron.add_css_class (Granite.CssClass.DIM);
        var folder_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        folder_box.append (folder_icon);
        folder_box.append (folder_label);
        folder_box.append (folder_chevron);
        /* Recents popover (video's environment list): recent folders
         * as rows, plus a portal picker for anything else. */
        recent_list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.NONE
        };
        recent_list.row_activated.connect ((row) => {
            var path = ((RecentFolderRow) row).directory;
            if (path == "") {
                choose_folder ();
            } else {
                set_folder (path);
            }
            folder_popover.popdown ();
        });
        var recent_scrolled = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            propagate_natural_width = true,
            propagate_natural_height = true,
            max_content_height = 260,
            child = recent_list
        };
        folder_popover = new Gtk.Popover () {
            child = recent_scrolled
        };
        folder_button = new Gtk.MenuButton () {
            child = folder_box,
            halign = Gtk.Align.FILL,
            hexpand = true
        };
        OpenClient.set_menu_popover (folder_button, folder_popover);
        folder_button.tooltip_text = "Workspace folder for this session (required)";
        rebuild_recent_rows ();
        column.append (folder_button);

        /* -- Prompt card. -- */
        var card = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
        card.add_css_class (Granite.CssClass.CARD);
        /* "rounded" gives the card its subtle 4px corner radius; the
         * Granite constant for it is deprecated, so use the class
         * name the stylesheet actually ships. */
        card.add_css_class ("rounded");
        card.add_css_class ("new-session-card");

        /* Attachments area */
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
        card.append (attachments_revealer);

        text_view = new Gtk.TextView () {
            wrap_mode = Gtk.WrapMode.WORD_CHAR,
            top_margin = 10,
            bottom_margin = 10,
            left_margin = 14,
            right_margin = 14,
            accepts_tab = false
        };
        text_view.add_css_class ("composer-entry");
        text_view.add_css_class ("new-session-input");
        text_view.buffer.changed.connect (() => {
            placeholder_label.visible = text_view.buffer.get_char_count () == 0;
            update_send_state ();
        });

        /* Content-aware height, matching the session composer. */
        var input_scrolled = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            vscrollbar_policy = Gtk.PolicyType.AUTOMATIC,
            propagate_natural_height = true,
            min_content_height = 44,
            max_content_height = 150,
            child = text_view
        };

        /* No ellipsis in placeholder text per hig/reference/text.md:
         *  it adds no value there. */
        placeholder_label = new Gtk.Label ("Plan, build, or ask (paste or drop images to attach)") {
            xalign = 0,
            yalign = 0,
            halign = Gtk.Align.START,
            valign = Gtk.Align.START,
            margin_top = 10,
            margin_start = 14,
            can_target = false
        };
        placeholder_label.add_css_class (Granite.CssClass.DIM);

        var overlay = new Gtk.Overlay () {
            child = input_scrolled,
            hexpand = true
        };
        overlay.add_overlay (placeholder_label);
        card.append (overlay);

        /* Drop target for images */
        var drop_target = new Gtk.DropTarget (typeof (Gdk.FileList), Gdk.DragAction.COPY);
        drop_target.drop.connect ((value, x, y) => on_files_dropped (value));
        text_view.add_controller (drop_target);

        /* Paste target for images. Capture phase so this runs before
         * the TextView's built-in Ctrl+V, which would otherwise paste
         * the file URI as plain text. */
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

            if (keyval == Gdk.Key.Escape) {
                cancelled ();
                return true;
            }
            if (keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter) {
                var ctrl = (state & Gdk.ModifierType.CONTROL_MASK) != 0;
                var shift = (state & Gdk.ModifierType.SHIFT_MASK) != 0;
                if (ctrl_enter_to_send ? ctrl && !shift : !shift) {
                    request_create ();
                    return true;
                }
            }
            return false;
        });
        text_view.add_controller (key_controller);

        agent_chooser = new AgentChooser ();
        model_chooser = new ModelChooser ();
        variant_chooser = new VariantChooser ();
        var attach_button = new Gtk.Button.from_icon_name ("mail-attachment-symbolic") {
            tooltip_text = "Attach images",
            valign = Gtk.Align.CENTER
        };
        attach_button.add_css_class (Granite.STYLE_CLASS_FLAT);
        attach_button.clicked.connect (() => pick_images ());
        send_button = new Gtk.Button.from_icon_name ("mail-send") {
            tooltip_text = "Create session and send",
            valign = Gtk.Align.CENTER,
            sensitive = false
        };
        send_button.add_css_class (Granite.CssClass.SUGGESTED);
        send_button.clicked.connect (() => request_create ());

        var bottom = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
            margin_start = 8,
            margin_end = 8,
            margin_bottom = 8
        };
        bottom.append (agent_chooser);
        bottom.append (model_chooser);
        bottom.append (variant_chooser);
        var spacer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) { hexpand = true };
        bottom.append (spacer);
        bottom.append (attach_button);
        bottom.append (send_button);
        card.append (bottom);
        column.append (card);

        hint_label = new Gtk.Label ("Pick a workspace folder above to continue.") {
            xalign = 0.5f
        };
        hint_label.add_css_class (Granite.CssClass.DIM);
        hint_label.add_css_class (Granite.CssClass.SMALL);
        column.append (hint_label);

        /* -- Suggestions: icon buttons that fill the box. -- */
        var suggestions_header = new Granite.HeaderLabel ("Suggestions") {
            halign = Gtk.Align.START
        };
        column.append (suggestions_header);

        var chips = new Gtk.FlowBox () {
            hexpand = true,
            halign = Gtk.Align.FILL,
            column_spacing = 8,
            row_spacing = 8,
            selection_mode = Gtk.SelectionMode.NONE,
            min_children_per_line = 1,
            max_children_per_line = 3,
            homogeneous = false
        };
        for (int i = 0; i < SUGGESTIONS.length; i++) {
            var suggestion = SUGGESTIONS[i];
            var icon_name = i < SUGGESTION_ICONS.length ? SUGGESTION_ICONS[i] : "go-next";
            var chip_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            chip_box.append (new Gtk.Image.from_icon_name (icon_name) { pixel_size = 16 });
            chip_box.append (new Gtk.Label (suggestion));
            var chip = new Gtk.Button () { child = chip_box };
            chip.halign = Gtk.Align.CENTER;
            var captured = suggestion;
            chip.clicked.connect (() => {
                text_view.buffer.text = captured;
                text_view.grab_focus ();
            });
            chips.append (chip);
        }
        column.append (chips);

        append (column);
    }

    /** Catalogs in (same feed as the composer). */
    public void set_models (Gee.ArrayList<ModelInfo> models) {
        model_chooser.set_models (models);
    }

    public void set_agents (Gee.ArrayList<AgentInfo> agents) {
        agent_chooser.set_agents (agents);
    }

    /** What the pickers show. Empty model/agent ids fall back to the
     *  server default at creation time. */
    public void set_default_selection (string provider_id, string model_id,
        string variant, string agent_id) {
        pending_provider_id = provider_id;
        pending_model_id = model_id;
        pending_variant = variant;
        pending_agent_id = agent_id;
        if (provider_id != "" && model_id != "") {
            model_chooser.set_current (provider_id, model_id);
        }
        if (agent_id != "") {
            agent_chooser.set_current (agent_id);
        }
    }

    public void note_model_selected (string provider_id, string model_id, string variant) {
        pending_provider_id = provider_id;
        pending_model_id = model_id;
        pending_variant = variant;
    }

    public void note_variant_selected (string variant) {
        pending_variant = variant;
    }

    public void note_agent_selected (string agent_id) {
        pending_agent_id = agent_id;
    }

    /** Prefills the global default folder (if any) and focuses the
     *  box. Called every time the page opens. */
    public void reset (string default_folder) {
        if (folder == "") {
            set_folder (default_folder);
        }
        clear_attachments ();
        update_send_state ();
        text_view.grab_focus ();
    }

    public void set_folder (string directory) {
        folder = directory.strip ();
        if (folder == "") {
            folder_label.label = "Choose a workspace folder…";
            folder_button.tooltip_text = "Workspace folder for this session (required)";
        } else {
            folder_label.label = GLib.Path.get_basename (folder);
            folder_button.tooltip_text = folder;
            folder_selected (folder);
        }
        update_send_state ();
    }

    /** Recent folders for the picker popover (most recent first). */
    public void set_recent_folders (Gee.ArrayList<string> recents) {
        recent_folders = recents;
        rebuild_recent_rows ();
    }

    private void rebuild_recent_rows () {
        if (recent_list == null) {
            return;
        }
        Gtk.Widget? child = recent_list.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            recent_list.remove (child);
            child = next;
        }
        if (recent_folders != null) {
            foreach (var directory in recent_folders) {
                if (directory.strip () == "") {
                    continue;
                }
                recent_list.append (new RecentFolderRow (directory));
            }
        }
        recent_list.append (new RecentFolderRow (""));
    }

    public void clear_message () {
        text_view.buffer.text = "";
        clear_attachments ();
        update_send_state ();
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
         * ignore the rest (the box is images-only). */
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
        /* Some file managers only advertise text/uri-list. Read it and
         * attach the image files it points at. */
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
                update_send_state ();
            });
            chip.append (remove_button);

            attachments_box.append (chip);

            /* Decode the thumbnail off the main thread, then swap it in. */
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
        update_send_state ();
    }

    private void clear_attachments () {
        attachments.clear ();
        rebuild_attachment_chips ();
    }

    private void choose_folder () {
        choose_folder_async.begin ();
    }

    private async void choose_folder_async () {
        var directory = yield Portals.pick_folder ("Select workspace folder", folder);
        if (directory != null) {
            set_folder (directory);
        }
    }

    private void update_send_state () {
        var has_text = text_view.buffer.text.strip () != "";
        var has_files = attachments.size > 0;
        var ready = folder != "" && (has_text || has_files);
        send_button.sensitive = ready;
        hint_label.visible = folder == "";
        if (ready) {
            send_button.tooltip_text = "Create session and send";
        } else if (folder == "" && !has_text && !has_files) {
            send_button.tooltip_text = "Choose a workspace folder and type a message first";
        } else if (folder == "") {
            send_button.tooltip_text = "Choose a workspace folder first";
        } else {
            send_button.tooltip_text = "Type a message or attach an image first";
        }
    }

    private void request_create () {
        var text = text_view.buffer.text.strip ();
        if (folder == "" || (text == "" && attachments.size == 0)) {
            return;
        }
        var files = new Gee.ArrayList<FileAttachment> ();
        foreach (var attachment in attachments) {
            files.add (attachment.to_file_attachment ());
        }
        create_requested (folder, text, files);
    }
}

/** One row of the workspace recents popover: a recent folder, or the
 *  portal picker entry when directory is "". */
public class RecentFolderRow : Gtk.ListBoxRow {
    public string directory { get; construct; }

    public RecentFolderRow (string directory) {
        Object (directory: directory);
        if (directory == "") {
            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10) {
                margin_top = 8,
                margin_bottom = 8,
                margin_start = 10,
                margin_end = 10
            };
            box.append (new Gtk.Image.from_icon_name ("folder-open") {
                pixel_size = 16,
                valign = Gtk.Align.CENTER
            });
            var label = new Gtk.Label ("Choose another folder…") {
                xalign = 0,
                hexpand = true
            };
            box.append (label);
            child = box;
            return;
        }
        var row_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10) {
            margin_top = 8,
            margin_bottom = 8,
            margin_start = 10,
            margin_end = 10
        };
        row_box.append (new Gtk.Image.from_icon_name ("folder") {
            pixel_size = 16,
            valign = Gtk.Align.CENTER
        });
        var texts = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            hexpand = true
        };
        texts.append (new Gtk.Label (GLib.Path.get_basename (directory)) {
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.MIDDLE
        });
        var path_label = new Gtk.Label (directory) {
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.START,
            max_width_chars = 40
        };
        path_label.add_css_class (Granite.CssClass.DIM);
        path_label.add_css_class ("caption");
        texts.append (path_label);
        row_box.append (texts);
        child = row_box;
        tooltip_text = directory;
    }
}

}
