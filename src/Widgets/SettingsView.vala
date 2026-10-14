/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * In-window settings page, elementary style: a category sidebar on
 * the start side and one content stack on the end side — no separate
 * window, so context (chat, sidebar, toasts) stays put underneath.
 *
 * Covers local preferences (connection, appearance, behavior,
 * workspace) and the server-side configuration that used to live
 * only in the OpenCode CLI/config files (providers, credentials,
 * MCP servers, git worktrees).
 *
 * All server data is read through the generic `Client.request()` SDK
 * entry point, so new endpoints light up without new plumbing.
 */

namespace OpenClient {

public class SettingsView : Gtk.Box {
    private Config config;
    private Store store;
    private Client? client;

    private Granite.ValidatedEntry host_entry;
    private Granite.ValidatedEntry port_entry;
    private Gtk.Entry password_entry;
    private Gtk.Entry workspace_entry;

    private Gtk.Label connection_status_label;
    private Gtk.Image connection_status_icon;
    private Gtk.Label server_version_label;
    private Gtk.Button test_button;

    private Gtk.ToggleButton theme_system_button;
    private Gtk.ToggleButton theme_light_button;
    private Gtk.ToggleButton theme_dark_button;

    private Granite.SwitchModelButton notify_turns_switch;
    private Granite.SwitchModelButton notify_permissions_switch;
    private Granite.SwitchModelButton notify_questions_switch;

    private StatusList providers_page;
    private StatusList credentials_page;
    private StatusList mcp_page;
    private StatusList worktrees_page;

    private Gtk.ListBox category_list;
    private Gtk.Stack content_stack;
    private Gtk.Label providers_desc_label;

    /** Watches the server config file for outside edits. */
    private GLib.FileMonitor? config_monitor = null;
    private uint config_debounce = 0;

    private string project_id = "";

    public SettingsView (Config config, Store store) {
        Object (
            orientation: Gtk.Orientation.HORIZONTAL,
            spacing: 0,
            hexpand: true,
            vexpand: true
        );
        this.config = config;
        this.store = store;
        this.client = store.client;

        category_list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.SINGLE,
            activate_on_single_click = true
        };
        category_list.add_css_class ("navigation-sidebar");
        category_list.row_selected.connect ((row) => {
            if (row == null) {
                return;
            }
            var id = ((SettingsCategoryRow) row.get_child ()).category_id;
            content_stack.visible_child_name = id;
        });

        Gtk.ListBoxRow? first_row = null;
        first_row = add_category (first_row, "connection", "Connection", "network-server");
        add_category (first_row, "appearance", "Appearance", "preferences-color-symbolic");
        add_category (first_row, "behavior", "Behavior", "preferences-system");
        add_category (first_row, "workspace", "Workspace", "folder");
        add_category (first_row, "providers", "Providers", "applications-science");
        add_category (first_row, "credentials", "Credentials", "dialog-password");
        add_category (first_row, "mcp", "MCP servers", "application-x-addon");
        add_category (first_row, "worktrees", "Worktrees", "folder-open");

        var sidebar = new Gtk.ScrolledWindow () {
            width_request = 220,
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            child = category_list
        };

        content_stack = new Gtk.Stack () {
            transition_type = Gtk.StackTransitionType.SLIDE_UP_DOWN,
            hexpand = true,
            vexpand = true
        };
        content_stack.add_named (build_connection_page (), "connection");
        content_stack.add_named (build_appearance_page (), "appearance");
        content_stack.add_named (build_behavior_page (), "behavior");
        content_stack.add_named (build_workspace_page (), "workspace");
        content_stack.add_named (build_providers_page (), "providers");
        content_stack.add_named (build_credentials_page (), "credentials");
        content_stack.add_named (build_mcp_page (), "mcp");
        content_stack.add_named (build_worktree_page (), "worktrees");

        append (sidebar);
        append (new Gtk.Separator (Gtk.Orientation.VERTICAL));
        append (content_stack);

        content_stack.visible_child_name = "connection";
        if (first_row != null && first_row.get_parent () == category_list) {
            category_list.select_row (first_row);
        }

        store.catalog_changed.connect (() => {
            /* Model names backing the provider detail lines. */
            if (content_stack.visible_child_name == "providers") {
                load_providers.begin ();
            }
        });
        watch_server_config ();
        load_all.begin ();
    }

    protected override void dispose () {
        if (config_monitor != null) {
            config_monitor.cancel ();
            config_monitor = null;
        }
        if (config_debounce != 0) {
            GLib.Source.remove (config_debounce);
            config_debounce = 0;
        }
        base.dispose ();
    }

    /** Reloads server-side lists the moment the server config file
     *  changes on disk — edited here, in an editor, or via CLI, the
     *  page follows in real time with no polling. */
    private void watch_server_config () {
        var path = GLib.Path.build_filename (
            GLib.Environment.get_user_config_dir (), "opencode", "opencode.jsonc");
        var file = GLib.File.new_for_path (path);
        try {
            if (!file.query_exists ()) {
                return;
            }
            config_monitor = file.monitor_file (GLib.FileMonitorFlags.NONE);
            config_monitor.changed.connect (() => {
                if (config_debounce != 0) {
                    return;
                }
                config_debounce = GLib.Timeout.add (500, () => {
                    config_debounce = 0;
                    refresh_from_disk ();
                    return false;
                });
            });
        } catch (Error e) {
            warning ("Could not watch server config: %s", e.message);
        }
    }

    private void refresh_from_disk () {
        client = store.client;
        if (client == null) {
            return;
        }
        load_providers.begin ();
        load_credentials.begin ();
        store.load_models.begin ();
        store.notice ("Server configuration reloaded");
    }

    /** Reloads server-side lists; called every time the page opens. */
    public void refresh () {
        client = store.client;
        host_entry.text = config.host;
        port_entry.text = config.port.to_string ();
        password_entry.text = config.password;
        workspace_entry.text = config.workspace_directory;
        sync_theme_buttons ();
        update_connection_status ();
        load_all.begin ();
    }

    private Gtk.ListBoxRow add_category (Gtk.ListBoxRow? first, string id, string title, string icon_name) {
        var row = new SettingsCategoryRow (id, title, icon_name);
        category_list.append (row);
        /* ListBox wraps our widget; return the wrapper for selection. */
        var wrapper = (Gtk.ListBoxRow) row.get_parent ();
        return first ?? wrapper;
    }

    /* -- page scaffolding (elementary pattern: H2 title with dim
     *  subtitle, then card groups each led by an H4 section label) -- */

    private static Gtk.Widget page_header (string title, string description) {
        var header = new Granite.HeaderLabel (title) {
            size = Granite.HeaderLabel.Size.H2,
            secondary_text = description,
            margin_top = 24,
            margin_start = 24,
            margin_end = 24,
            margin_bottom = 12
        };
        return header;
    }

    private static Gtk.Widget section_label (string title) {
        var label = new Granite.HeaderLabel (title) {
            margin_top = 18,
            margin_start = 24,
            margin_end = 24,
            margin_bottom = 6
        };
        return label;
    }

    private static Gtk.Widget page_wrap (Gtk.Widget header, Gtk.Widget[] sections) {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            hexpand = true,
            vexpand = true
        };
        box.append (header);
        /* Tall pages (Behavior) must scroll instead of forcing the
         * window to grow beyond its default size. */
        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            hexpand = true,
            vexpand = true,
            margin_bottom = 18
        };
        foreach (var section in sections) {
            content.append (section);
        }
        var scroll = new Gtk.ScrolledWindow () {
            hexpand = true,
            vexpand = true,
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            child = content
        };
        box.append (scroll);
        return box;
    }

    private static Gtk.Box card () {
        var card = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            margin_start = 24,
            margin_end = 24,
            margin_bottom = 6
        };
        card.add_css_class ("card");
        return card;
    }

    private delegate void SwitchFlip (bool state);

    /** One Granite switch row: title + dim description with the
     *  switch at the end, the whole row clickable. */
    private Granite.SwitchModelButton switch_row (string title, string subtitle,
        bool initial, SwitchFlip on_flip) {
        var row = new Granite.SwitchModelButton (title) {
            description = subtitle,
            active = initial
        };
        row.toggled.connect (() => {
            on_flip (row.active);
        });
        return row;
    }

    private Gtk.ListBox card_list () {
        var list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.NONE,
            show_separators = true
        };
        list.add_css_class ("settings-list");
        return list;
    }

    /* -- Connection ---------------------------------------------------- */

    private Gtk.Widget build_connection_page () {
        /* Status card: live reachability, refreshed on open/test/save. */
        connection_status_icon = new Gtk.Image.from_icon_name ("network-server") {
            pixel_size = 32,
            valign = Gtk.Align.CENTER
        };
        connection_status_label = new Gtk.Label ("Checking…") {
            xalign = 0
        };
        connection_status_label.add_css_class (Granite.STYLE_CLASS_H4_LABEL);
        server_version_label = new Gtk.Label ("") {
            xalign = 0
        };
        server_version_label.add_css_class ("dim-label");
        server_version_label.add_css_class ("caption");
        var texts = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) {
            hexpand = true,
            valign = Gtk.Align.CENTER
        };
        texts.append (connection_status_label);
        texts.append (server_version_label);

        test_button = new Gtk.Button.with_label ("Test") {
            valign = Gtk.Align.CENTER,
            tooltip_text = "Check the entered host, port and password"
        };
        test_button.clicked.connect (() => test_connection.begin ());

        var status_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
            margin_top = 12,
            margin_bottom = 12,
            margin_start = 12,
            margin_end = 12
        };
        status_box.append (connection_status_icon);
        status_box.append (texts);
        status_box.append (test_button);
        var status_card = card ();
        status_card.append (status_box);

        /* Credentials card: entries validate inline (Granite marks
         *  bad input with an error icon + class as you type). */
        GLib.Regex? host_regex = null;
        GLib.Regex? port_regex = null;
        try {
            host_regex = new GLib.Regex ("^[A-Za-z0-9._-]+$");
            port_regex = new GLib.Regex ("^[0-9]{1,5}$");
        } catch (GLib.RegexError e) {
            warning ("Bad validation regex: %s", e.message);
        }
        host_entry = host_regex != null
            ? new Granite.ValidatedEntry.from_regex (host_regex) {
                text = config.host,
                hexpand = true,
                placeholder_text = "127.0.0.1"
            }
            : new Granite.ValidatedEntry () {
                text = config.host,
                hexpand = true,
                placeholder_text = "127.0.0.1"
            };
        port_entry = port_regex != null
            ? new Granite.ValidatedEntry.from_regex (port_regex) {
                text = config.port.to_string (),
                width_chars = 6,
                placeholder_text = "4096"
            }
            : new Granite.ValidatedEntry () {
                text = config.port.to_string (),
                width_chars = 6,
                placeholder_text = "4096"
            };
        password_entry = new Gtk.Entry () {
            text = config.password,
            visibility = false,
            hexpand = true,
            placeholder_text = "Server password"
        };

        var grid = new Gtk.Grid () {
            row_spacing = 12,
            column_spacing = 12,
            margin_top = 12,
            margin_bottom = 12,
            margin_start = 12,
            margin_end = 12
        };
        grid.attach (new Gtk.Label ("Host") { xalign = 0, valign = Gtk.Align.CENTER }, 0, 0, 1, 1);
        grid.attach (host_entry, 1, 0, 2, 1);
        grid.attach (new Gtk.Label ("Port") { xalign = 0, valign = Gtk.Align.CENTER }, 0, 1, 1, 1);
        grid.attach (port_entry, 1, 1, 1, 1);
        grid.attach (new Gtk.Label ("Password") { xalign = 0, valign = Gtk.Align.CENTER }, 0, 2, 1, 1);
        grid.attach (password_entry, 1, 2, 2, 1);
        var form_card = card ();
        form_card.append (grid);

        var save_button = new Gtk.Button.with_label ("Save & Reconnect") {
            halign = Gtk.Align.START,
            margin_start = 24,
            margin_top = 6,
            margin_bottom = 18
        };
        save_button.add_css_class ("suggested-action");
        save_button.clicked.connect (() => {
            config.host = host_entry.text.strip ();
            var parsed = int.parse (port_entry.text.strip ());
            if (parsed > 0 && parsed <= 65535) {
                config.port = (uint) parsed;
            }
            config.password = password_entry.text;
            config.save ();
            store.notice ("Settings saved");
            update_connection_status ();
            store.connect_and_load.begin ();
        });
        /* Save only makes sense with a valid host/port pair. */
        save_button.sensitive = can_save_connection ();
        host_entry.changed.connect (() => {
            save_button.sensitive = can_save_connection ();
        });
        port_entry.changed.connect (() => {
            save_button.sensitive = can_save_connection ();
        });

        return page_wrap (
            page_header ("Connection", "Host, port and password for your OpenCode server."),
            { status_card, section_label ("Server credentials"), form_card, save_button }
        );
    }

    /** Save needs a valid host plus a real port number. */
    private bool can_save_connection () {
        if (!host_entry.is_valid || !port_entry.is_valid) {
            return false;
        }
        var parsed = int.parse (port_entry.text.strip ());
        return parsed > 0 && parsed <= 65535;
    }

    private async void test_connection () {        test_button.sensitive = false;
        connection_status_label.label = "Checking…";
        server_version_label.label = "";
        var probe = new Client (
            host_entry.text.strip (),
            (uint) int.max (int.parse (port_entry.text.strip ()), 0),
            password_entry.text
        );
        var version = yield probe.version ();
        test_button.sensitive = true;
        if (version != null) {
            set_status (true, "Reachable", @"Server v$version · $(probe.base_url)");
        } else {
            set_status (false, "Unreachable", @"Could not reach $(probe.base_url)");
        }
        update_connection_status ();
    }

    private void set_status (bool ok, string title, string subtitle) {
        connection_status_label.label = title;
        connection_status_label.remove_css_class (Granite.CssClass.SUCCESS);
        connection_status_label.remove_css_class (Granite.CssClass.ERROR);
        connection_status_label.add_css_class (
            ok ? Granite.CssClass.SUCCESS : Granite.CssClass.ERROR);
        server_version_label.label = subtitle;
    }

    private void update_connection_status () {
        if (store.client == null) {
            set_status (false, "Not connected", "Save credentials to connect.");
            return;
        }
        set_status (true, "Connected", store.client.base_url);
        var client = store.client;
        client.version.begin ((obj, res) => {
            var version = client.version.end (res);
            if (version != null) {
                server_version_label.label = @"Server v$version · $(client.base_url)";
            }
        });
    }

    /* -- Appearance ---------------------------------------------------- */

    private Gtk.Widget build_appearance_page () {
        theme_system_button = new Gtk.ToggleButton.with_label ("System");
        theme_light_button = new Gtk.ToggleButton.with_label ("Light");
        theme_dark_button = new Gtk.ToggleButton.with_label ("Dark");
        theme_system_button.tooltip_text = "Follow the system color scheme";
        theme_light_button.tooltip_text = "Always use the light style";
        theme_dark_button.tooltip_text = "Always use the dark style";

        var segmented = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) {
            halign = Gtk.Align.START,
            margin_top = 12,
            margin_bottom = 12,
            margin_start = 12,
            margin_end = 12
        };
        segmented.add_css_class ("linked");
        segmented.append (theme_system_button);
        segmented.append (theme_light_button);
        segmented.append (theme_dark_button);
        sync_theme_buttons ();

        theme_system_button.toggled.connect (() => pick_theme ("system", theme_system_button));
        theme_light_button.toggled.connect (() => pick_theme ("light", theme_light_button));
        theme_dark_button.toggled.connect (() => pick_theme ("dark", theme_dark_button));

        var theme_card = card ();
        theme_card.append (segmented);

        return page_wrap (
            page_header ("Appearance", "How the app follows your desktop style."),
            { section_label ("Color scheme"), theme_card }
        );
    }

    /** Guards the segmented theme control: flipping one button
     *  programmatically fires the others' toggled handlers. */
    private bool picking_theme = false;

    private void sync_theme_buttons () {
        picking_theme = true;
        theme_system_button.active = config.theme_mode == "system";
        theme_light_button.active = config.theme_mode == "light";
        theme_dark_button.active = config.theme_mode == "dark";
        picking_theme = false;
    }

    private void pick_theme (string mode, Gtk.ToggleButton source) {
        if (picking_theme) {
            return;
        }
        picking_theme = true;
        if (!source.active) {
            /* Keep one option always selected. */
            source.active = true;
        }
        theme_system_button.active = mode == "system";
        theme_light_button.active = mode == "light";
        theme_dark_button.active = mode == "dark";
        picking_theme = false;
        if (config.theme_mode != mode) {
            config.theme_mode = mode;
            config.save ();
        }
    }

    /* -- Behavior ------------------------------------------------------ */

    private Gtk.Widget build_behavior_page () {
        /* Notifications card: master plus per-event toggles. */
        var notify_list = card_list ();
        notify_list.append (switch_row (
            "Desktop notifications",
            "Bubbles for finished turns, permission requests and questions.",
            config.notifications_enabled,
            (state) => {
                config.notifications_enabled = state;
                config.save ();
                sync_notify_subs ();
            }
        ));
        notify_turns_switch = notify_switch (notify_list,
            "Finished turns",
            "Notify when a background session finishes its turn.",
            config.notify_turns,
            (state) => { config.notify_turns = state; config.save (); });
        notify_permissions_switch = notify_switch (notify_list,
            "Permission requests",
            "Notify when the model asks to run something.",
            config.notify_permissions,
            (state) => { config.notify_permissions = state; config.save (); });
        notify_questions_switch = notify_switch (notify_list,
            "Question prompts",
            "Notify when the model waits for your answer.",
            config.notify_questions,
            (state) => { config.notify_questions = state; config.save (); });
        var notify_card = card ();
        notify_card.append (notify_list);

        var chat_list = card_list ();
        chat_list.append (switch_row (
            "Playful status lines",
            "\u201cDoing the cookies…\u201d while awaiting the first reply.",
            config.playful_status,
            (state) => {
                config.playful_status = state;
                config.save ();
            }
        ));
        var chat_card = card ();
        chat_card.append (chat_list);

        var composer_list = card_list ();
        composer_list.append (switch_row (
            "Send with Ctrl+Enter",
            "Enter makes a new line; Ctrl+Enter sends the message.",
            config.send_with_ctrl_enter,
            (state) => {
                config.send_with_ctrl_enter = state;
                config.save ();
            }
        ));
        var composer_card = card ();
        composer_card.append (composer_list);

        var sessions_list = card_list ();
        sessions_list.append (switch_row (
            "Confirm before deleting",
            "Ask before a session is permanently removed.",
            config.confirm_delete,
            (state) => {
                config.confirm_delete = state;
                config.save ();
            }
        ));
        var sessions_card = card ();
        sessions_card.append (sessions_list);

        sync_notify_subs ();

        return page_wrap (
            page_header ("Behavior", "Notifications and little delights."),
            {
                section_label ("Notifications"), notify_card,
                section_label ("Chat"), chat_card,
                section_label ("Composer"), composer_card,
                section_label ("Sessions"), sessions_card
            }
        );
    }

    private Granite.SwitchModelButton notify_switch (Gtk.ListBox list, string title, string subtitle,
        bool initial, SwitchFlip on_flip) {
        var row = switch_row (title, subtitle, initial, on_flip);
        list.append (row);
        return row;
    }

    private void sync_notify_subs () {
        var on = config.notifications_enabled;
        if (notify_turns_switch != null) {
            notify_turns_switch.sensitive = on;
        }
        if (notify_permissions_switch != null) {
            notify_permissions_switch.sensitive = on;
        }
        if (notify_questions_switch != null) {
            notify_questions_switch.sensitive = on;
        }
    }

    /* -- Workspace ----------------------------------------------------- */

    private Gtk.Widget build_workspace_page () {
        workspace_entry = new Gtk.Entry () {
            text = config.workspace_directory,
            placeholder_text = "/home/user/Projects",
            hexpand = true
        };

        var choose_button = new Gtk.Button.with_label ("Choose folder…");
        choose_button.clicked.connect (() => choose_workspace_folder.begin ());

        var reveal_button = new Gtk.Button.from_icon_name ("folder-open") {
            tooltip_text = "Show in Files",
            valign = Gtk.Align.CENTER
        };
        reveal_button.add_css_class ("flat");
        reveal_button.clicked.connect (() => reveal_workspace.begin ());

        var save_button = new Gtk.Button.with_label ("Save workspace");
        save_button.add_css_class ("suggested-action");
        save_button.clicked.connect (() => {
            config.workspace_directory = workspace_entry.text.strip ();
            config.save ();
            store.notice ("Workspace saved");
        });

        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
            margin_top = 12,
            margin_bottom = 12,
            margin_start = 12,
            margin_end = 12
        };
        row.append (workspace_entry);
        row.append (choose_button);
        row.append (reveal_button);
        row.append (save_button);
        var folder_card = card ();
        folder_card.append (row);

        return page_wrap (
            page_header ("Workspace", "Default folder suggested for new sessions and worktrees."),
            { section_label ("Default codebase folder"), folder_card }
        );
    }

    /* -- Server lists -------------------------------------------------- */

    private Gtk.Widget build_providers_page () {
        var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        var open_config = new Gtk.Button.with_label ("Config file");
        open_config.add_css_class ("flat");
        open_config.tooltip_text = "Open opencode.jsonc in your editor";
        open_config.clicked.connect (() => open_server_config ());
        var refresh = refresh_action ();
        refresh.clicked.connect (() => load_providers.begin ());
        actions.append (open_config);
        actions.append (refresh);

        providers_desc_label = new Gtk.Label ("") {
            xalign = 0,
            wrap = true
        };
        providers_desc_label.add_css_class ("dim-label");

        var header_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
            margin_top = 24,
            margin_start = 24,
            margin_end = 24,
            margin_bottom = 12
        };
        var header = new Granite.HeaderLabel ("Providers") {
            size = Granite.HeaderLabel.Size.H2,
            secondary_text = "Backends installed on this server.",
            hexpand = true
        };
        header_box.append (header);
        actions.valign = Gtk.Align.CENTER;
        header_box.append (actions);

        var desc_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) {
            margin_start = 24,
            margin_end = 24,
            margin_bottom = 6
        };
        desc_box.append (providers_desc_label);

        providers_page = new StatusList (
            "No providers",
            "The server reports no backends.",
            "applications-science"
        );
        var list_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            hexpand = true,
            vexpand = true,
            margin_start = 24,
            margin_end = 24,
            margin_bottom = 12
        };
        list_box.append (providers_page.stack);

        var page = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            hexpand = true,
            vexpand = true
        };
        page.append (header_box);
        page.append (desc_box);
        page.append (list_box);
        return page;
    }

    private Gtk.Widget build_credentials_page () {
        var refresh = refresh_action ();
        refresh.clicked.connect (() => load_credentials.begin ());
        credentials_page = new StatusList (
            "No credentials",
            "Accounts that let providers run models appear here.",
            "dialog-password"
        );
        return server_list_page (
            "Credentials",
            "Accounts that let providers run models.",
            refresh,
            credentials_page
        );
    }

    private Gtk.Widget build_mcp_page () {
        var refresh = refresh_action ();
        refresh.clicked.connect (() => load_mcp.begin ());
        mcp_page = new StatusList (
            "No MCP servers",
            "External tools connected through the Model Context Protocol.",
            "application-x-addon"
        );
        return server_list_page (
            "MCP servers",
            "External tools connected through the Model Context Protocol.",
            refresh,
            mcp_page
        );
    }

    private Gtk.Widget build_worktree_page () {
        var create = new Gtk.Button.with_label ("New worktree");
        create.add_css_class ("suggested-action");
        create.clicked.connect (() => create_worktree.begin ());
        worktrees_page = new StatusList (
            "No worktrees",
            "Git worktrees of the current project.",
            "folder-open"
        );
        return server_list_page (
            "Worktrees",
            "Git worktrees of the current project.",
            create,
            worktrees_page
        );
    }

    private Gtk.Widget server_list_page (string title, string description,
        Gtk.Widget action, StatusList status) {
        var header_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
            margin_top = 24,
            margin_start = 24,
            margin_end = 24,
            margin_bottom = 12
        };
        var header = new Granite.HeaderLabel (title) {
            size = Granite.HeaderLabel.Size.H2,
            secondary_text = description,
            hexpand = true
        };
        header_box.append (header);
        action.valign = Gtk.Align.CENTER;
        header_box.append (action);

        var list_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            hexpand = true,
            vexpand = true,
            margin_start = 24,
            margin_end = 24,
            margin_bottom = 12
        };
        list_box.append (status.stack);

        var page = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            hexpand = true,
            vexpand = true
        };
        page.append (header_box);
        page.append (list_box);
        return page;
    }

    /* -- helpers ------------------------------------------------------- */

    private static Gtk.Label row_title (string text) {
        var title = new Gtk.Label (text) { xalign = 0 };
        title.add_css_class (Granite.STYLE_CLASS_H4_LABEL);
        return title;
    }

    private static Gtk.Label row_subtitle (string text) {
        var subtitle = new Gtk.Label (text) {
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.END
        };
        subtitle.add_css_class ("dim-label");
        subtitle.add_css_class ("caption");
        return subtitle;
    }

    private static void clear_list (Gtk.ListBox list) {
        Gtk.Widget? child = list.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            list.remove (child);
            child = next;
        }
    }

    private static Gtk.Button refresh_action (string tooltip = "Refresh") {
        var refresh = new Gtk.Button.from_icon_name ("view-refresh") {
            tooltip_text = tooltip
        };
        refresh.add_css_class ("flat");
        return refresh;
    }

    /* -- loading ------------------------------------------------------- */

    private async void load_all () {
        client = store.client;
        if (client == null) {
            providers_page.show_error ("Not connected");
            credentials_page.show_error ("Not connected");
            mcp_page.show_error ("Not connected");
            worktrees_page.show_error ("Not connected");
            return;
        }
        load_providers.begin ();
        load_credentials.begin ();
        load_mcp.begin ();
        load_worktrees.begin ();
    }

    private async void choose_workspace_folder () {
        var directory = yield Portals.pick_folder (
            "Select workspace folder", workspace_entry.text.strip ());
        if (directory != null) {
            workspace_entry.text = directory;
        }
    }

    private async void reveal_workspace () {
        var directory = workspace_entry.text.strip ();
        if (directory == "") {
            store.notice ("No workspace folder set");
            return;
        }
        if (!yield Portals.reveal_in_files (directory)) {
            store.notice (@"Could not show $directory in Files");
        }
    }

    /** Opens the server config file in the default editor: providers
     *  live there (the API is read-only), and the file monitor below
     *  reloads this page the moment it is saved. */
    private void open_server_config () {
        open_server_config_async.begin ();
    }

    private async void open_server_config_async () {
        var path = GLib.Path.build_filename (
            GLib.Environment.get_user_config_dir (), "opencode", "opencode.jsonc");
        if (!GLib.FileUtils.test (path, GLib.FileTest.EXISTS)) {
            store.notice ("Server config file not found");
            return;
        }
        if (!yield Portals.open_file (path)) {
            store.notice ("Could not open config file");
        }
    }

    /** Directory the provider list is scoped to: the open session's
     *  folder, else the configured workspace, else server default. */
    private string providers_directory () {
        var session = store.active_session;
        if (session != null && session.directory.strip () != "") {
            return session.directory;
        }
        return config.workspace_directory.strip ();
    }

    private async void load_providers () {
        if (client == null) {
            return;
        }
        try {
            var dir = providers_directory ();
            var path = "/api/provider";
            if (dir != "") {
                path += "?directory=" + Uri.escape_string (dir);
            }
            /* The header subtitle already covers the unscoped case. */
            providers_desc_label.visible = dir != "";
            providers_desc_label.label = dir != ""
                ? @"Backends available in $dir."
                : "";
            var root = yield client.request ("GET", path);
            clear_list (providers_page.list);
            var count = 0;
            foreach (var obj in JsonUtil.root_objects (root)) {
                providers_page.list.append (provider_row (obj));
                count++;
            }
            providers_page.show_list (count > 0);
        } catch (Error e) {
            providers_page.show_error (@"Could not load providers: $(e.message)");
        }
    }

    /** Full provider detail: brand icon, name, endpoint and the
     *  models it serves (cross-referenced with the model catalog). */
    private Gtk.Widget provider_row (Json.Object obj) {
        var id = JsonUtil.string_member (obj, "id") ?? "";
        var name = JsonUtil.string_member (obj, "name") ?? id;
        var activation = JsonUtil.string_member (obj, "activation") ?? "";
        var settings = JsonUtil.object_member (obj, "settings");
        var endpoint = settings != null ? (JsonUtil.string_member (settings, "baseURL") ?? "") : "";

        var brand = new Gtk.Image.from_icon_name (ModelIcons.icon_for (id, "")) {
            pixel_size = 28,
            valign = Gtk.Align.CENTER
        };

        var texts = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) { hexpand = true };
        texts.append (row_title (name));
        if (endpoint != "") {
            var url = new Gtk.Label (endpoint) {
                xalign = 0,
                ellipsize = Pango.EllipsizeMode.MIDDLE
            };
            url.add_css_class ("dim-label");
            url.add_css_class ("caption");
            url.add_css_class ("monospace");
            texts.append (url);
        }
        var models_line = provider_models_line (id);
        if (models_line != "") {
            texts.append (row_subtitle (models_line));
        }

        var row_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
            margin_top = 8,
            margin_bottom = 8,
            margin_start = 12,
            margin_end = 12
        };
        row_box.append (brand);
        row_box.append (texts);
        if (activation != "") {
            var badge = new Gtk.Label (activation) {
                valign = Gtk.Align.CENTER
            };
            badge.add_css_class ("caption");
            if (activation == "active") {
                badge.add_css_class (Granite.CssClass.SUCCESS);
            } else {
                badge.add_css_class ("dim-label");
            }
            row_box.append (badge);
        }
        return new Granite.ListItem () { child = row_box };
    }

    private string provider_models_line (string provider_id) {
        var names = new Gee.ArrayList<string> ();
        int64 max_ctx = 0;
        foreach (var model in store.models) {
            if (model.provider_id != provider_id) {
                continue;
            }
            if (names.size < 3) {
                names.add (model.name);
            }
            if (model.context_limit > max_ctx) {
                max_ctx = model.context_limit;
            }
        }
        if (names.size == 0) {
            return "";
        }
        var line = string.joinv (", ", names.to_array ());
        if (max_ctx > 0) {
            line += @" · up to $(Store.format_tokens (max_ctx)) ctx";
        }
        return line;
    }

    private async void load_credentials () {
        if (client == null) {
            return;
        }
        try {
            var root = yield client.request ("GET", "/api/credential");
            clear_list (credentials_page.list);
            var count = 0;
            foreach (var obj in JsonUtil.root_objects (root)) {
                var id = JsonUtil.string_member (obj, "id") ?? "";
                var label = JsonUtil.string_member (obj, "label") ?? id;
                var integration = JsonUtil.string_member (obj, "integrationID") ?? "";
                var active = obj.get_boolean_member_with_default ("active", false);

                var row_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
                    margin_top = 8,
                    margin_bottom = 8,
                    margin_start = 12,
                    margin_end = 12
                };
                var texts = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) { hexpand = true };
                texts.append (row_title (label));
                texts.append (row_subtitle (@"$id · $integration"));

                if (active) {
                    var badge = new Gtk.Label ("Active") {
                        valign = Gtk.Align.CENTER
                    };
                    badge.add_css_class ("caption");
                    badge.add_css_class (Granite.CssClass.SUCCESS);
                    row_box.append (texts);
                    row_box.append (badge);
                } else {
                    var activate = new Gtk.Button.with_label ("Activate");
                    activate.add_css_class ("flat");
                    activate.valign = Gtk.Align.CENTER;
                    var captured_id = id;
                    activate.clicked.connect (() => activate_credential.begin (captured_id));
                    row_box.append (texts);
                    row_box.append (activate);
                }

                var remove = new Gtk.Button.from_icon_name ("user-trash") {
                    tooltip_text = "Delete credential",
                    valign = Gtk.Align.CENTER
                };
                remove.add_css_class ("destructive-action");
                var delete_id = id;
                remove.clicked.connect (() => delete_credential.begin (delete_id));
                row_box.append (remove);

                credentials_page.list.append (new Granite.ListItem () { child = row_box });
                count++;
            }
            credentials_page.show_list (count > 0);
        } catch (Error e) {
            credentials_page.show_error (@"Could not load credentials: $(e.message)");
        }
    }

    private async void activate_credential (string id) {
        if (client == null) {
            return;
        }
        try {
            yield client.request ("POST", "/api/credential/" + Uri.escape_string (id) + "/activate");
            store.notice ("Credential activated");
            load_credentials.begin ();
        } catch (Error e) {
            store.notice (@"Activate failed: $(e.message)");
        }
    }

    private async void delete_credential (string id) {
        if (client == null) {
            return;
        }
        try {
            yield client.request ("DELETE", "/api/credential/" + Uri.escape_string (id));
            store.notice ("Credential deleted");
            load_credentials.begin ();
        } catch (Error e) {
            store.notice (@"Delete failed: $(e.message)");
        }
    }

    private async void load_mcp () {
        if (client == null) {
            return;
        }
        try {
            var root = yield client.request ("GET", "/api/mcp");
            clear_list (mcp_page.list);
            var count = 0;
            foreach (var obj in JsonUtil.root_objects (root)) {
                var name = JsonUtil.string_member (obj, "name") ?? "server";
                var status_obj = JsonUtil.object_member (obj, "status");
                var status = status_obj != null
                    ? (JsonUtil.string_member (status_obj, "status") ?? "unknown") : "unknown";

                var dot = new Gtk.Image.from_icon_name (
                    status == "connected" ? "emblem-default-symbolic" : "window-close"
                ) {
                    pixel_size = 16,
                    valign = Gtk.Align.CENTER
                };
                if (status == "connected") {
                    dot.add_css_class (Granite.CssClass.SUCCESS);
                } else {
                    dot.add_css_class ("dim-label");
                }

                var row_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
                    margin_top = 8,
                    margin_bottom = 8,
                    margin_start = 12,
                    margin_end = 12
                };
                var texts = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) { hexpand = true };
                texts.append (row_title (name));
                var status_label = new Gtk.Label (status) {
                    xalign = 0
                };
                status_label.add_css_class ("caption");
                if (status == "connected") {
                    status_label.add_css_class (Granite.CssClass.SUCCESS);
                } else {
                    status_label.add_css_class ("dim-label");
                }
                texts.append (status_label);
                row_box.append (dot);
                row_box.append (texts);

                var toggle = new Gtk.Button.with_label (status == "connected" ? "Disconnect" : "Connect");
                toggle.add_css_class ("flat");
                toggle.valign = Gtk.Align.CENTER;
                var captured = name;
                var connected = status == "connected";
                toggle.clicked.connect (() => toggle_mcp.begin (captured, connected));
                row_box.append (toggle);

                mcp_page.list.append (new Granite.ListItem () { child = row_box });
                count++;
            }
            mcp_page.show_list (count > 0);
        } catch (Error e) {
            mcp_page.show_error (@"Could not load MCP servers: $(e.message)");
        }
    }

    private async void toggle_mcp (string name, bool connected) {
        if (client == null) {
            return;
        }
        var path = "/api/experimental/mcp/" + Uri.escape_string (name)
            + (connected ? "/disconnect" : "/connect");
        try {
            yield client.request ("POST", path);
            store.notice (connected ? "MCP disconnected" : "MCP connecting…");
            load_mcp.begin ();
        } catch (Error e) {
            store.notice (@"MCP action failed: $(e.message)");
        }
    }

    private async void load_worktrees () {
        if (client == null) {
            return;
        }
        try {
            if (project_id == "") {
                var projects = yield client.request ("GET", "/api/project");
                foreach (var obj in JsonUtil.root_objects (projects)) {
                    project_id = JsonUtil.string_member (obj, "id") ?? "";
                    if (project_id != "") {
                        break;
                    }
                }
            }
            clear_list (worktrees_page.list);
            if (project_id == "") {
                worktrees_page.show_error ("No project available");
                return;
            }
            var root = yield client.request ("GET", "/api/worktree?projectID=" + Uri.escape_string (project_id));
            var count = 0;
            foreach (var obj in JsonUtil.root_objects (root)) {
                var directory = JsonUtil.string_member (obj, "directory") ?? "";
                var strategy = JsonUtil.string_member (obj, "strategy") ?? "";
                var row_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
                    margin_top = 8,
                    margin_bottom = 8,
                    margin_start = 12,
                    margin_end = 12
                };
                var texts = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) { hexpand = true };
                texts.append (row_title (GLib.Path.get_basename (directory)));
                texts.append (row_subtitle (strategy != "" ? @"$directory · $strategy" : directory));
                row_box.append (texts);

                var remove = new Gtk.Button.from_icon_name ("user-trash") {
                    tooltip_text = "Remove worktree",
                    valign = Gtk.Align.CENTER
                };
                remove.add_css_class ("destructive-action");
                var captured = directory;
                remove.clicked.connect (() => remove_worktree.begin (captured));
                row_box.append (remove);

                worktrees_page.list.append (new Granite.ListItem () { child = row_box });
                count++;
            }
            worktrees_page.show_list (count > 0);
        } catch (Error e) {
            worktrees_page.show_error (@"Could not load worktrees: $(e.message)");
        }
    }

    private async void create_worktree () {
        if (client == null || project_id == "") {
            store.notice ("No project to create a worktree for");
            return;
        }
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("projectID");
        builder.add_string_value (project_id);
        builder.end_object ();
        try {
            yield client.request ("POST", "/api/worktree", builder.get_root ());
            store.notice ("Worktree created");
            load_worktrees.begin ();
        } catch (Error e) {
            store.notice (@"Create worktree failed: $(e.message)");
        }
    }

    private async void remove_worktree (string directory) {
        if (client == null || project_id == "") {
            return;
        }
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("projectID");
        builder.add_string_value (project_id);
        builder.set_member_name ("directory");
        builder.add_string_value (directory);
        builder.set_member_name ("force");
        builder.add_boolean_value (false);
        builder.end_object ();
        try {
            yield client.request ("DELETE", "/api/worktree", builder.get_root ());
            store.notice ("Worktree removed");
            load_worktrees.begin ();
        } catch (Error e) {
            store.notice (@"Remove worktree failed: $(e.message)");
        }
    }
}

/** A server-backed list with a proper elementary empty state: the
 *  list when it has rows, a Granite.Placeholder when it has none,
 *  and an inline dim error row when a load fails. */
private class StatusList : GLib.Object {
    public Gtk.Stack stack { get; private set; }
    public Gtk.ListBox list { get; private set; }
    private Granite.Placeholder empty;

    public StatusList (string title, string description, string icon_name) {
        list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.NONE,
            show_separators = true
        };
        list.add_css_class ("rich-list");
        list.add_css_class ("settings-list");

        var scroll = new Gtk.ScrolledWindow () {
            vexpand = true,
            hexpand = true,
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            child = list
        };
        scroll.add_css_class ("settings-scroll");

        empty = new Granite.Placeholder (title) {
            description = description
        };
        empty.icon = new ThemedIcon (icon_name);

        stack = new Gtk.Stack () {
            hexpand = true,
            vexpand = true
        };
        stack.add_named (scroll, "list");
        stack.add_named (empty, "empty");
        stack.visible_child_name = "empty";
    }

    public void show_list (bool has_items) {
        stack.visible_child_name = has_items ? "list" : "empty";
    }

    public void show_error (string text) {
        var label = new Gtk.Label (text) {
            xalign = 0.5f,
            margin_top = 24,
            margin_bottom = 24,
            wrap = true
        };
        label.add_css_class ("dim-label");
        var row = new Gtk.ListBoxRow () {
            child = label,
            selectable = false,
            activatable = false
        };
        Gtk.Widget? child = list.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            list.remove (child);
            child = next;
        }
        list.append (row);
        stack.visible_child_name = "list";
    }
}

public class SettingsCategoryRow : Gtk.Box {
    public string category_id { get; construct; }

    public SettingsCategoryRow (string category_id, string title, string icon_name) {
        Object (
            category_id: category_id,
            orientation: Gtk.Orientation.HORIZONTAL,
            spacing: 10
        );
        margin_start = 6;
        margin_end = 6;
        margin_top = 8;
        margin_bottom = 8;

        var icon = new Gtk.Image.from_icon_name (icon_name) {
            pixel_size = 18,
            valign = Gtk.Align.CENTER
        };

        var label = new Gtk.Label (title) {
            xalign = 0,
            valign = Gtk.Align.CENTER,
            hexpand = true
        };

        append (icon);
        append (label);
    }
}

}
