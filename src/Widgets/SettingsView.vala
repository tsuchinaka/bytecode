/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * In-window settings page, elementary style: a category sidebar on
 * the start side and one content stack on the end side, with no separate
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

/* H4-sized text. Granite moved this from a CSS-class constant to
 * HeaderLabel.Size, which only works on Granite.HeaderLabel widgets;
 * these are plain Gtk.Labels, so the theme class (what
 * Granite.STYLE_CLASS_H4_LABEL expands to, and what
 * Granite.HeaderLabel.Size.H4 applies) is used directly. */
internal const string TITLE_4_CSS_CLASS = "title-4";

public class SettingsView : Gtk.Box {
    private Config config;
    private Store store;
    private ServerProcess server;
    private Client? client;

    private Granite.ValidatedEntry host_entry;
    private Granite.ValidatedEntry port_entry;
    private Gtk.Entry password_entry;
    private Gtk.Entry workspace_entry;

    private Gtk.Label connection_status_label;
    /* App-owned server (ServerProcess): the switch, its settings and the
     *  live state line. */
    private Gtk.Switch managed_switch;
    private Gtk.Box managed_section;
    private Gtk.Box manual_section;
    private Gtk.Entry server_command_entry;
    private Gtk.Entry server_port_entry;
    private Gtk.Entry server_password_entry;
    private Gtk.Label server_state_label;
    private Gtk.Image connection_status_icon;
    private Gtk.Label server_version_label;
    private Gtk.Label service_watch_label;
    private bool service_watch_connected = false;
    private Gtk.Button test_button;

    private Gtk.ToggleButton theme_system_button;
    private Gtk.ToggleButton theme_light_button;
    private Gtk.ToggleButton theme_dark_button;

    private Gtk.Switch notify_turns_switch;
    private Gtk.Switch notify_permissions_switch;
    private Gtk.Switch notify_questions_switch;

    private Gtk.Box providers_box;
    private Gtk.Box credentials_box;
    private Gtk.Box mcp_box;
    private Gtk.Box worktrees_box;

    private Gtk.ListBox category_list;
    private Gtk.Stack content_stack;

    /** Watches the server config file for outside edits. */
    private GLib.FileMonitor? config_monitor = null;
    /** Watches the custom-agents directory (new/edited/removed agent
     *  files change the picker without touching opencode.jsonc). */
    private GLib.FileMonitor? agents_monitor = null;
    private uint config_debounce = 0;

    private string project_id = "";

    public SettingsView (Config config, Store store, ServerProcess server) {
        Object (
            orientation: Gtk.Orientation.HORIZONTAL,
            spacing: 0,
            hexpand: true,
            vexpand: true
        );
        this.config = config;
        this.store = store;
        this.server = server;
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
        store.mcp_changed.connect (() => {
            if (content_stack.visible_child_name == "mcp") {
                load_mcp.begin ();
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
        if (agents_monitor != null) {
            agents_monitor.cancel ();
            agents_monitor = null;
        }
        if (config_debounce != 0) {
            GLib.Source.remove (config_debounce);
            config_debounce = 0;
        }
        base.dispose ();
    }

    /** Reloads the server config file and the custom-agents directory
     *  for outside edits: edited here, in an editor, or via CLI, the
     *  app follows in real time with no polling. */
    private void watch_server_config () {
        var dir = GLib.Path.build_filename (
            GLib.Environment.get_user_config_dir (), "opencode");
        watch_path (GLib.Path.build_filename (dir, "opencode.jsonc"), true);
        watch_path (GLib.Path.build_filename (dir, "agents"), false);
    }

    /** Watches one config path (file or directory) with the shared
     *  debounced refresh. Missing paths are skipped silently. */
    private void watch_path (string path, bool is_file) {
        var file = GLib.File.new_for_path (path);
        try {
            if (!file.query_exists ()) {
                return;
            }
            var monitor = is_file
                ? file.monitor_file (GLib.FileMonitorFlags.NONE)
                : file.monitor_directory (GLib.FileMonitorFlags.NONE);
            if (is_file) {
                config_monitor = monitor;
            } else {
                agents_monitor = monitor;
            }
            monitor.changed.connect (() => {
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
            warning ("Could not watch %s: %s", path, e.message);
        }
    }

    private void refresh_from_disk () {
        client = store.client;
        update_server_state ();
        if (client == null) {
            return;
        }
        load_providers.begin ();
        load_credentials.begin ();
        store.load_models.begin ();
        /* Agents live in the watched paths too (custom agents are files
         *  under agents/): without this the picker keeps the set from
         *  connect time until the next restart. */
        store.load_agents.begin ();
        store.notice ("Server configuration reloaded");
    }

    /** Reloads server-side lists; called every time the page opens. */
    public void refresh () {
        client = store.client;
        host_entry.text = config.host;
        port_entry.text = config.port.to_string ();
        password_entry.text = config.password;
        server_command_entry.text = config.server_command;
        server_port_entry.text = config.server_port.to_string ();
        server_password_entry.text = config.server_password;
        managed_switch.active = config.manage_server;
        sync_connection_mode ();
        workspace_entry.text = config.workspace_directory;
        sync_theme_buttons ();
        update_connection_status ();
        update_service_watch ();
        load_all.begin ();
    }

    /** Background-service tap line (see ServiceWatcher): terminal
     *  turns move this app's indicators while it is watching. */
    private void update_service_watch () {
        var watcher = store.service_watcher;
        if (watcher == null) {
            service_watch_label.label = "";
            service_watch_label.visible = false;
            return;
        }
        if (!service_watch_connected) {
            service_watch_connected = true;
            watcher.state_changed.connect (() => update_service_watch ());
        }
        if (watcher.watching && watcher.detail != "") {
            service_watch_label.label = watcher.detail + ".";
            service_watch_label.visible = true;
        } else {
            service_watch_label.label = "No background service detected; only this app's own turns move the indicators.";
            service_watch_label.visible = true;
        }
    }

    /** One line under the app-server settings: what the server is doing
     *  right now, or where it stopped. */
    private void update_server_state () {
        switch (server.state) {
            case ServerState.RUNNING:
                server_state_label.label = server.detail;
                server_state_label.remove_css_class (Granite.CssClass.ERROR);
                break;
            case ServerState.STARTING:
                server_state_label.label = server.detail;
                server_state_label.remove_css_class (Granite.CssClass.ERROR);
                break;
            case ServerState.FAILED:
                server_state_label.label = server.detail;
                server_state_label.add_css_class (Granite.CssClass.ERROR);
                break;
            default:
                server_state_label.label = @"Not running on port $(config.server_port)";
                server_state_label.remove_css_class (Granite.CssClass.ERROR);
                break;
        }
    }

    private Gtk.ListBoxRow add_category (Gtk.ListBoxRow? first, string id, string title, string icon_name) {
        var row = new SettingsCategoryRow (id, title, icon_name);
        category_list.append (row);
        /* ListBox wraps our widget; return the wrapper for selection. */
        var wrapper = (Gtk.ListBoxRow) row.get_parent ();
        return first ?? wrapper;
    }

    /* -- page scaffolding (pantheon-tweaks pattern: H2 title with dim
     *  subtitle, then flat rows: a HeaderLabel carrying title plus
     *  description with the control at the end. No cards; the side
     *  margins live on the content container, not on every row.) -- */

    private static Gtk.Widget page_header (string title, string description) {
        var header = new Granite.HeaderLabel (title) {
            size = Granite.HeaderLabel.Size.H2,
            secondary_text = description,
            margin_top = 24,
            margin_bottom = 12
        };
        return header;
    }

    private static Gtk.Widget section_label (string title) {
        var label = new Granite.HeaderLabel (title) {
            margin_top = 18,
            margin_bottom = 6
        };
        return label;
    }

    private static Gtk.Widget page_wrap (Gtk.Widget header, Gtk.Widget[] sections) {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            hexpand = true,
            vexpand = true
        };
        var head_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            margin_start = 24,
            margin_end = 24
        };
        head_box.append (header);
        box.append (head_box);
        /* Tall pages (Behavior) must scroll instead of forcing the
         * window to grow beyond its default size. */
        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            hexpand = true,
            vexpand = true,
            margin_start = 24,
            margin_end = 24,
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

    /** One pantheon-tweaks setting row: title plus dim description with
     *  the control at the end, vertically centered. */
    private static Gtk.Box setting_row (string title, string subtitle, Gtk.Widget control) {
        var label = new Granite.HeaderLabel (title) {
            secondary_text = subtitle,
            hexpand = true
        };
        control.valign = Gtk.Align.CENTER;
        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
            margin_top = 6,
            margin_bottom = 6
        };
        row.append (label);
        row.append (control);
        return row;
    }

    /** One switch row in the pantheon-tweaks style: label plus a plain
     *  Gtk.Switch at the end. Returns the row; the caller connects to
     *  @sw itself (passing a callback in would have to copy the
     *  delegate, which Vala cannot do). */
    private static Gtk.Box switch_row (string title, string subtitle,
        bool initial, out Gtk.Switch sw) {
        sw = new Gtk.Switch () {
            active = initial
        };
        return setting_row (title, subtitle, sw);
    }

    /* -- Connection ---------------------------------------------------- */

    private Gtk.Widget build_connection_page () {
        /* Status row: live reachability, refreshed on open/test/save. */
        connection_status_icon = new Gtk.Image.from_icon_name ("network-server") {
            pixel_size = 24,
            valign = Gtk.Align.CENTER
        };
        connection_status_label = new Gtk.Label ("Checking…") {
            xalign = 0
        };
        connection_status_label.add_css_class (TITLE_4_CSS_CLASS);
        server_version_label = new Gtk.Label ("") {
            xalign = 0
        };
        server_version_label.add_css_class (Granite.CssClass.DIM);
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

        var status_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
            margin_top = 6,
            margin_bottom = 6
        };
        status_row.append (connection_status_icon);
        status_row.append (texts);
        status_row.append (test_button);

        /* Background-service tap: whether terminal CLIs' turns move
         *  this app's indicators (see ServiceWatcher). */
        service_watch_label = new Gtk.Label ("") {
            xalign = 0,
            wrap = true,
            margin_top = 6,
            margin_bottom = 6
        };
        service_watch_label.add_css_class (Granite.CssClass.DIM);
        service_watch_label.add_css_class ("caption");

        /* Credentials: one label-plus-entry row each (entries validate
         *  inline: Granite marks bad input with an error icon as you
         *  type). */
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
        var host_row = setting_row ("Host", "Address of the server you run yourself.", host_entry);
        var port_row = setting_row ("Port", "Port that server listens on.", port_entry);
        var password_row = setting_row ("Password", "Shown once by `opencode serve`.", password_entry);

        var save_button = new Gtk.Button.with_label ("Save & Reconnect") {
            halign = Gtk.Align.START,
            margin_top = 6,
            margin_bottom = 6
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

        /* -- app-owned server -------------------------------------- */

        Gtk.Switch managed_sw;
        var managed_row = switch_row (
            "Managed Server",
            "bytecode starts its own `opencode serve` on a private port with its own passcode.",
            config.manage_server,
            out managed_sw
        );
        managed_switch = managed_sw;
        managed_switch.notify["active"].connect (() => {
            var active = managed_switch.active;
            config.manage_server = active;
            config.save ();
            sync_connection_mode ();
            store.notice (active
                ? "The app will run its own server"
                : "Using the server you configure below");
        });

        server_command_entry = new Gtk.Entry () {
            text = config.server_command,
            hexpand = true,
            placeholder_text = "opencode"
        };
        server_port_entry = new Gtk.Entry () {
            text = config.server_port.to_string (),
            width_chars = 9,
            placeholder_text = "4599"
        };
        server_password_entry = new Gtk.Entry () {
            text = config.server_password,
            visibility = false,
            hexpand = true,
            placeholder_text = "generated on first use"
        };
        var reveal_passcode = new Gtk.ToggleButton () {
            icon_name = "view-reveal-symbolic",
            tooltip_text = "Show the passcode",
            valign = Gtk.Align.CENTER
        };
        reveal_passcode.toggled.connect (() => {
            server_password_entry.visibility = reveal_passcode.active;
        });

        var passcode_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            hexpand = true
        };
        passcode_box.append (server_password_entry);
        passcode_box.append (reveal_passcode);

        var command_row = setting_row ("Command", "Binary that serves the API.", server_command_entry);
        var server_port_row = setting_row ("Port", "Private port for the app's server.", server_port_entry);
        var passcode_row = setting_row ("Passcode", "Secret the app and its server share.", passcode_box);

        server_state_label = new Gtk.Label ("") {
            xalign = 0,
            wrap = true
        };
        server_state_label.add_css_class (Granite.CssClass.DIM);
        server_state_label.add_css_class ("caption");

        var restart_button = new Gtk.Button.with_label ("Apply & Restart Server") {
            valign = Gtk.Align.CENTER
        };
        restart_button.add_css_class ("suggested-action");
        restart_button.clicked.connect (() => apply_managed_settings.begin ());
        var log_button = new Gtk.Button.with_label ("Server Log") {
            valign = Gtk.Align.CENTER,
            tooltip_text = "Open the app server's log file"
        };
        log_button.clicked.connect (() => {
            Portals.open_file.begin (server.log_path);
        });
        var managed_actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            margin_top = 6,
            margin_bottom = 6
        };
        managed_actions.append (restart_button);
        managed_actions.append (log_button);

        managed_section = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            visible = config.manage_server,
            name = "app-server-section"
        };
        managed_section.append (command_row);
        managed_section.append (server_port_row);
        managed_section.append (passcode_row);
        managed_section.append (managed_actions);
        managed_section.append (server_state_label);

        /* -- manually configured server ---------------------------- */

        /* Only the active mode is visible, heading included: the section
         *  label is inside the section so it can never dangle over
         *  nothing when the managed server is in use. An off-screen
         *  Gtk.Stack page would still be measured by GTK, and a hidden
         *  half of the page would otherwise set the view's minimum
         *  height. */
        manual_section = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            visible = !config.manage_server,
            name = "manual-server-section"
        };
        manual_section.append (section_label ("Your Own Server"));
        manual_section.append (host_row);
        manual_section.append (port_row);
        manual_section.append (password_row);
        manual_section.append (save_button);

        return page_wrap (
            page_header ("Connection", "bytecode runs its own OpenCode server, or talks to one you run yourself."),
            { status_row, service_watch_label, managed_row, managed_section, manual_section }
        );
    }


    /** Shows the settings that belong to the active mode. */
    private void sync_connection_mode () {
        managed_section.visible = config.manage_server;
        manual_section.visible = !config.manage_server;
        update_connection_status ();
    }

    /** Saves the app-server settings and restarts the server so they
     *  take effect, then reconnects. */
    private async void apply_managed_settings () {
        config.server_command = server_command_entry.text.strip () != ""
            ? server_command_entry.text.strip () : "opencode";
        var parsed = int.parse (server_port_entry.text.strip ());
        if (parsed > 0 && parsed <= 65535) {
            config.server_port = (uint) parsed;
        }
        if (server_password_entry.text.strip () != "") {
            config.server_password = server_password_entry.text.strip ();
        }
        config.ensure_server_password ();
        config.save ();
        server_password_entry.text = config.server_password;
        server_port_entry.text = config.server_port.to_string ();

        server_state_label.label = "Restarting…";
        store.notice ("Restarting the app server");
        var restarted = yield server.restart ();
        if (restarted) {
            store.notice ("Server restarted");
        }
        yield store.connect_and_load ();
        refresh ();
    }

    /** Save needs a valid host plus a real port number. */
    private bool can_save_connection () {
        if (!host_entry.is_valid || !port_entry.is_valid) {
            return false;
        }
        var parsed = int.parse (port_entry.text.strip ());
        return parsed > 0 && parsed <= 65535;
    }

    private async void test_connection () {
        test_button.sensitive = false;
        connection_status_label.label = "Checking…";
        server_version_label.label = "";
        var use_managed = config.manage_server;
        var probe = new Client (
            use_managed ? "127.0.0.1" : host_entry.text.strip (),
            use_managed
                ? config.server_port
                : (uint) int.max (int.parse (port_entry.text.strip ()), 0),
            use_managed ? config.server_password : password_entry.text
        );
        var version = yield probe.version ();
        test_button.sensitive = true;
        if (version != null) {
            set_status (true, "Reachable", @"Server v$version · $(probe.base_url)");
        } else {
            set_status (false, "Unreachable",
                use_managed
                    ? @"Nothing answered on $(probe.base_url). Press Apply & Restart Server"
                    : @"Could not reach $(probe.base_url)");
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
        update_server_state ();
        if (store.client == null) {
            set_status (false, "Not connected", config.manage_server
                ? @"The app server is not reachable on port $(config.server_port)."
                : "Save credentials to connect.");
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
            valign = Gtk.Align.CENTER
        };
        segmented.add_css_class ("linked");
        segmented.append (theme_system_button);
        segmented.append (theme_light_button);
        segmented.append (theme_dark_button);
        sync_theme_buttons ();

        theme_system_button.toggled.connect (() => pick_theme ("system", theme_system_button));
        theme_light_button.toggled.connect (() => pick_theme ("light", theme_light_button));
        theme_dark_button.toggled.connect (() => pick_theme ("dark", theme_dark_button));

        var theme_row = setting_row (
            "Color Scheme",
            "Follow the system style, or force light / dark.",
            segmented
        );

        return page_wrap (
            page_header ("Appearance", "How the app follows your desktop style."),
            { theme_row }
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
        /* Notifications group: master plus per-event toggles. */
        Gtk.Switch master_sw;
        var notify_master = switch_row (
            "Desktop Notifications",
            "Bubbles for finished turns, permission requests and questions.",
            config.notifications_enabled,
            out master_sw
        );
        master_sw.notify["active"].connect (() => {
            config.notifications_enabled = master_sw.active;
            config.save ();
            sync_notify_subs ();
        });
        Gtk.Switch turns_sw;
        var turns_row = switch_row (
            "Finished Turns",
            "Notify when a background session finishes its turn.",
            config.notify_turns,
            out turns_sw
        );
        notify_turns_switch = turns_sw;
        notify_turns_switch.notify["active"].connect (() => {
            config.notify_turns = notify_turns_switch.active;
            config.save ();
        });
        Gtk.Switch perms_sw;
        var perms_row = switch_row (
            "Permission Requests",
            "Notify when the model asks to run something.",
            config.notify_permissions,
            out perms_sw
        );
        notify_permissions_switch = perms_sw;
        notify_permissions_switch.notify["active"].connect (() => {
            config.notify_permissions = notify_permissions_switch.active;
            config.save ();
        });
        Gtk.Switch questions_sw;
        var questions_row = switch_row (
            "Question Prompts",
            "Notify when the model waits for your answer.",
            config.notify_questions,
            out questions_sw
        );
        notify_questions_switch = questions_sw;
        notify_questions_switch.notify["active"].connect (() => {
            config.notify_questions = notify_questions_switch.active;
            config.save ();
        });

        Gtk.Switch playful_sw;
        var playful_row = switch_row (
            "Playful Status Lines",
            "\u201cDoing the cookies…\u201d while awaiting the first reply.",
            config.playful_status,
            out playful_sw
        );
        playful_sw.notify["active"].connect (() => {
            config.playful_status = playful_sw.active;
            config.save ();
        });

        Gtk.Switch ctrl_enter_sw;
        var ctrl_enter_row = switch_row (
            "Send With Ctrl+Enter",
            "Enter makes a new line; Ctrl+Enter sends the message.",
            config.send_with_ctrl_enter,
            out ctrl_enter_sw
        );
        ctrl_enter_sw.notify["active"].connect (() => {
            config.send_with_ctrl_enter = ctrl_enter_sw.active;
            config.save ();
        });

        Gtk.Switch confirm_sw;
        var confirm_row = switch_row (
            "Confirm Before Deleting",
            "Ask before a session is permanently removed.",
            config.confirm_delete,
            out confirm_sw
        );
        confirm_sw.notify["active"].connect (() => {
            config.confirm_delete = confirm_sw.active;
            config.save ();
        });

        sync_notify_subs ();

        return page_wrap (
            page_header ("Behavior", "Notifications and little delights."),
            {
                section_label ("Notifications"),
                notify_master, turns_row, perms_row, questions_row,
                section_label ("Chat"), playful_row,
                section_label ("Composer"), ctrl_enter_row,
                section_label ("Sessions"), confirm_row
            }
        );
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
        reveal_button.add_css_class (Granite.STYLE_CLASS_FLAT);
        reveal_button.clicked.connect (() => reveal_workspace.begin ());

        var save_button = new Gtk.Button.with_label ("Save workspace");
        save_button.add_css_class ("suggested-action");
        save_button.clicked.connect (() => {
            config.workspace_directory = workspace_entry.text.strip ();
            config.save ();
            store.notice ("Workspace saved");
        });

        var folder_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
            margin_top = 6,
            margin_bottom = 6
        };
        folder_row.append (workspace_entry);
        folder_row.append (choose_button);
        folder_row.append (reveal_button);
        folder_row.append (save_button);

        return page_wrap (
            page_header ("Workspace", "Default folder suggested for new sessions and worktrees."),
            { setting_row (
                "Default Codebase Folder",
                "New sessions and worktrees start here.",
                folder_row
            ) }
        );
    }

    /* -- Server lists -------------------------------------------------- */

    private Gtk.Widget build_providers_page () {
        var open_config = new Gtk.Button.with_label ("Config File") {
            tooltip_text = "Open opencode.jsonc in your editor"
        };
        open_config.clicked.connect (() => open_server_config ());
        var refresh = new Gtk.Button.with_label ("Refresh");
        refresh.clicked.connect (() => load_providers.begin ());
        var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            halign = Gtk.Align.START,
            margin_top = 12,
            margin_bottom = 6
        };
        actions.append (open_config);
        actions.append (refresh);

        providers_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

        return page_wrap (
            page_header ("Providers", "Backends installed on this server."),
            { providers_box, actions }
        );
    }

    private Gtk.Widget build_credentials_page () {
        var refresh = new Gtk.Button.with_label ("Refresh");
        refresh.clicked.connect (() => load_credentials.begin ());
        var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            halign = Gtk.Align.START,
            margin_top = 12,
            margin_bottom = 6
        };
        actions.append (refresh);

        credentials_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

        return page_wrap (
            page_header ("Credentials", "Accounts that let providers run models."),
            { credentials_box, actions }
        );
    }

    private Gtk.Widget build_mcp_page () {
        var refresh = new Gtk.Button.with_label ("Refresh");
        refresh.clicked.connect (() => load_mcp.begin ());
        var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            halign = Gtk.Align.START,
            margin_top = 12,
            margin_bottom = 6
        };
        actions.append (refresh);

        mcp_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

        return page_wrap (
            page_header ("MCP Servers", "External tools connected through the Model Context Protocol."),
            { mcp_box, actions }
        );
    }

    private Gtk.Widget build_worktree_page () {
        var create = new Gtk.Button.with_label ("New Worktree");
        create.clicked.connect (() => create_worktree.begin ());
        var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            halign = Gtk.Align.START,
            margin_top = 12,
            margin_bottom = 6
        };
        actions.append (create);

        worktrees_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

        return page_wrap (
            page_header ("Worktrees", "Git worktrees of the current project."),
            { worktrees_box, actions }
        );
    }

    /* -- helpers ------------------------------------------------------- */

    private static void clear_box (Gtk.Box box) {
        Gtk.Widget? child = box.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            box.remove (child);
            child = next;
        }
    }

    /** Dim centered line for an empty flat page (no rows to show) or a
     *  load failure. */
    private static Gtk.Widget flat_note (string text) {
        var label = new Gtk.Label (text) {
            xalign = 0.5f,
            wrap = true,
            margin_top = 18,
            margin_bottom = 18
        };
        label.add_css_class (Granite.CssClass.DIM);
        return label;
    }

    /* -- loading ------------------------------------------------------- */

    private async void load_all () {
        client = store.client;
        if (client == null) {
            clear_box (providers_box);
            providers_box.append (flat_note ("Not connected."));
            clear_box (credentials_box);
            credentials_box.append (flat_note ("Not connected."));
            clear_box (mcp_box);
            mcp_box.append (flat_note ("Not connected."));
            clear_box (worktrees_box);
            worktrees_box.append (flat_note ("Not connected."));
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
            var root = yield client.request ("GET", path);
            clear_box (providers_box);
            var count = 0;
            foreach (var obj in JsonUtil.root_objects (root)) {
                providers_box.append (provider_row (obj));
                count++;
            }
            if (count == 0) {
                providers_box.append (flat_note ("The server reports no backends."));
            }
        } catch (Error e) {
            clear_box (providers_box);
            providers_box.append (flat_note (@"Could not load providers: $(e.message)"));
        }
    }

    /** One provider as a flat Settings row: brand icon, name plus
     *  served models, activation as the trailing status. */
    private Gtk.Widget provider_row (Json.Object obj) {
        var id = JsonUtil.string_member (obj, "id") ?? "";
        var name = JsonUtil.string_member (obj, "name") ?? id;
        var activation = JsonUtil.string_member (obj, "activation") ?? "";
        var settings = JsonUtil.object_member (obj, "settings");
        var endpoint = settings != null ? (JsonUtil.string_member (settings, "baseURL") ?? "") : "";

        var brand = new Gtk.Image.from_icon_name (ModelIcons.icon_for (id, "")) {
            pixel_size = 24
        };

        var models_line = provider_models_line (id);
        var label = new Granite.HeaderLabel (name) {
            secondary_text = models_line != "" ? models_line : endpoint,
            hexpand = true
        };

        var status = new Gtk.Label (activation == "active" ? "Active" : activation) {
            valign = Gtk.Align.CENTER
        };
        status.add_css_class ("caption");
        if (activation == "active") {
            status.add_css_class (Granite.CssClass.SUCCESS);
        } else {
            status.add_css_class (Granite.CssClass.DIM);
        }

        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
            margin_top = 6,
            margin_bottom = 6
        };
        row.append (brand);
        row.append (label);
        if (activation != "") {
            row.append (status);
        }
        return row;
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
        var line = ListArrays.join (", ", names);
        if (max_ctx > 0) {
            line += @" · up to $(Store.format_tokens (max_ctx)) ctx";
        }
        return line;
    }

    /** One credential as a flat Settings row: account label plus id,
     *  with Activate (or the Active marker) and delete at the end. */
    private Gtk.Widget credential_row (string id, string label, string integration, bool active) {
        var controls = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            valign = Gtk.Align.CENTER
        };
        if (active) {
            var badge = new Gtk.Label ("Active");
            badge.add_css_class ("caption");
            badge.add_css_class (Granite.CssClass.SUCCESS);
            controls.append (badge);
        } else {
            var activate = new Gtk.Button.with_label ("Activate");
            activate.clicked.connect (() => activate_credential.begin (id));
            controls.append (activate);
        }
        var remove = new Gtk.Button.from_icon_name ("user-trash") {
            tooltip_text = "Delete credential"
        };
        remove.add_css_class (Granite.STYLE_CLASS_FLAT);
        remove.clicked.connect (() => delete_credential.begin (id));
        controls.append (remove);

        return setting_row (label, integration != "" ? @"$id · $integration" : id, controls);
    }

    private async void load_credentials () {
        if (client == null) {
            return;
        }
        try {
            var root = yield client.request ("GET", "/api/credential");
            clear_box (credentials_box);
            var count = 0;
            foreach (var obj in JsonUtil.root_objects (root)) {
                var id = JsonUtil.string_member (obj, "id") ?? "";
                var label = JsonUtil.string_member (obj, "label") ?? id;
                var integration = JsonUtil.string_member (obj, "integrationID") ?? "";
                var active = obj.get_boolean_member_with_default ("active", false);
                credentials_box.append (credential_row (id, label, integration, active));
                count++;
            }
            if (count == 0) {
                credentials_box.append (
                    flat_note ("Accounts that let providers run models appear here."));
            }
        } catch (Error e) {
            clear_box (credentials_box);
            credentials_box.append (flat_note (@"Could not load credentials: $(e.message)"));
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

    /** One MCP server as a flat Settings row: name plus connection
     *  status, with Connect/Disconnect at the end. */
    private Gtk.Widget mcp_row (string name, string status, bool connected) {
        var toggle = new Gtk.Button.with_label (connected ? "Disconnect" : "Connect");
        toggle.clicked.connect (() => toggle_mcp.begin (name, connected));
        return setting_row (name, status, toggle);
    }

    private async void load_mcp () {
        if (client == null) {
            return;
        }
        try {
            var root = yield client.request ("GET", "/api/mcp");
            clear_box (mcp_box);
            var count = 0;
            foreach (var obj in JsonUtil.root_objects (root)) {
                var name = JsonUtil.string_member (obj, "name") ?? "server";
                var status_obj = JsonUtil.object_member (obj, "status");
                var status = status_obj != null
                    ? (JsonUtil.string_member (status_obj, "status") ?? "unknown") : "unknown";
                mcp_box.append (mcp_row (name, status, status == "connected"));
                count++;
            }
            if (count == 0) {
                mcp_box.append (
                    flat_note ("External tools connected through the Model Context Protocol appear here."));
            }
        } catch (Error e) {
            clear_box (mcp_box);
            mcp_box.append (flat_note (@"Could not load MCP servers: $(e.message)"));
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

    /** One worktree as a flat Settings row: folder name plus location,
     *  with remove at the end. */
    private Gtk.Widget worktree_row (string directory, string strategy) {
        var remove = new Gtk.Button.from_icon_name ("user-trash") {
            tooltip_text = "Remove worktree"
        };
        remove.add_css_class (Granite.STYLE_CLASS_FLAT);
        remove.clicked.connect (() => remove_worktree.begin (directory));
        return setting_row (
            GLib.Path.get_basename (directory),
            strategy != "" ? @"$directory · $strategy" : directory,
            remove
        );
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
            clear_box (worktrees_box);
            if (project_id == "") {
                worktrees_box.append (flat_note ("No project available."));
                return;
            }
            var root = yield client.request ("GET", "/api/worktree?projectID=" + Uri.escape_string (project_id));
            var count = 0;
            foreach (var obj in JsonUtil.root_objects (root)) {
                var directory = JsonUtil.string_member (obj, "directory") ?? "";
                var strategy = JsonUtil.string_member (obj, "strategy") ?? "";
                worktrees_box.append (worktree_row (directory, strategy));
                count++;
            }
            if (count == 0) {
                worktrees_box.append (flat_note ("Git worktrees of the current project appear here."));
            }
        } catch (Error e) {
            clear_box (worktrees_box);
            worktrees_box.append (flat_note (@"Could not load worktrees: $(e.message)"));
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
