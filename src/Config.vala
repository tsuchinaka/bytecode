/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Connection configuration. Stored in
 * ~/.config/opencode-client/client.conf and overridable via env vars
 * (OPENCODE_PASSWORD / OPENCODE_HOST), matching how OpenChamber wires
 * managed servers.
 */

namespace OpenClient {

public class Config : GLib.Object {
    private const string CONFIG_DIR_NAME = "opencode-client";
    private const string CONFIG_FILE_NAME = "client.conf";

    public string host { get; set; default = "127.0.0.1"; }
    public uint port { get; set; default = 4096; }
    public string password { get; set; default = ""; }
    /** The app starts and owns its own `opencode serve`: a dedicated
     *  port and passcode, so there is no manual pairing to do. */
    public bool manage_server { get; set; default = true; }
    /** Command used to start that server (a name on PATH or a path). */
    public string server_command { get; set; default = "opencode"; }
    /** Port for the app's own server. Moved to the next free port when
     *  something else holds it. */
    public uint server_port { get; set; default = 4599; }
    /** Passcode for the app's own server, generated on first use. Kept
     *  so a server started by an earlier run can be re-adopted (and so
     *  the TUI can be pointed at the same port with the same secret). */
    public string server_password { get; set; default = ""; }
    /** Default workspace/codebase directory used when opening sessions. */
    public string workspace_directory { get; set; default = ""; }
    /** Desktop bubbles for turns, permissions and questions. */
    public bool notifications_enabled { get; set; default = true; }
    /** Per-event notification toggles (each ANDed with the master). */
    public bool notify_turns { get; set; default = true; }
    public bool notify_permissions { get; set; default = true; }
    public bool notify_questions { get; set; default = true; }
    /** Playful "Doing the cookies…" lines while awaiting a reply. */
    public bool playful_status { get; set; default = true; }
    /** Theme override: "system", "light" or "dark". */
    public string theme_mode { get; set; default = "system"; }
    /** Ask for confirmation before deleting a session. */
    public bool confirm_delete { get; set; default = true; }
    /** Send with Ctrl+Enter instead of Enter (Enter makes a new line). */
    public bool send_with_ctrl_enter { get; set; default = false; }
    /** Client-side session flags (the server has no pin/archive):
     *  session ids pinned to the top of the sidebar. */
    public string[] pinned_sessions { get; set; default = {}; }
    /** Session ids hidden from the main list, shown under Archived. */
    public string[] archived_sessions { get; set; default = {}; }
    /** Recently used workspace folders, most recent first (capped). */
    public string[] workspace_history { get; set; default = {}; }

    private static string config_dir () {
        return GLib.Path.build_filename (GLib.Environment.get_user_config_dir (), CONFIG_DIR_NAME);
    }

    private static string config_path () {
        return GLib.Path.build_filename (config_dir (), CONFIG_FILE_NAME);
    }

    /** Where the app keeps its own server's log (and other run state). */
    public static string state_dir () {
        var state_base = GLib.Environment.get_user_state_dir ();
        return GLib.Path.build_filename (state_base, CONFIG_DIR_NAME);
    }

    /** The connection the app actually uses: the server it manages, or
     *  the manually configured one. */
    public string effective_host {
        owned get {
            return manage_server ? "127.0.0.1" : host;
        }
    }

    public uint effective_port {
        get {
            return manage_server ? server_port : port;
        }
    }

    public string effective_password {
        owned get {
            return manage_server ? server_password : password;
        }
    }

    /** True when a connection can be attempted at all. */
    public bool has_connection {
        get {
            return manage_server ? true : password != "";
        }
    }

    /** Generates the app server's passcode once and keeps it. */
    public void ensure_server_password () {
        if (server_password == "") {
            server_password = GLib.Uuid.string_random ();
        }
    }

    public static Config load () {
        var config = new Config ();

        var env_password = GLib.Environment.get_variable ("OPENCODE_PASSWORD");
        if (env_password != null) {
            config.password = env_password;
            /* In managed mode the same variable is what the server will
             *  be told to use, so honour it there too. */
            config.server_password = env_password;
        }
        var env_host = GLib.Environment.get_variable ("OPENCODE_HOST");
        if (env_host != null) {
            config.host = env_host;
        }
        var env_port = GLib.Environment.get_variable ("OPENCODE_PORT");
        if (env_port != null) {
            var parsed = int.parse (env_port);
            if (parsed > 0) {
                config.port = (uint) parsed;
            }
        }

        var key_file = new GLib.KeyFile ();
        try {
            key_file.load_from_file (config_path (), GLib.KeyFileFlags.NONE);
        } catch (Error e) {
            return config;
        }

        try {
            if (key_file.has_group ("connection")) {
                if (key_file.has_key ("connection", "host")) {
                    config.host = key_file.get_string ("connection", "host");
                }
                if (key_file.has_key ("connection", "port")) {
                    var port = key_file.get_integer ("connection", "port");
                    if (port > 0) {
                        config.port = (uint) port;
                    }
                }
                if (key_file.has_key ("connection", "password")) {
                    var stored = key_file.get_string ("connection", "password");
                    if (stored != "") {
                        config.password = stored;
                    }
                }
            }
            if (key_file.has_group ("server")) {
                if (key_file.has_key ("server", "managed")) {
                    try {
                        config.manage_server = key_file.get_boolean ("server", "managed");
                    } catch (Error e) {
                    }
                }
                if (key_file.has_key ("server", "command")) {
                    var command = key_file.get_string ("server", "command");
                    if (command.strip () != "") {
                        config.server_command = command.strip ();
                    }
                }
                if (key_file.has_key ("server", "port")) {
                    var server_port = key_file.get_integer ("server", "port");
                    if (server_port > 0 && server_port <= 65535) {
                        config.server_port = (uint) server_port;
                    }
                }
                if (key_file.has_key ("server", "password")) {
                    var stored = key_file.get_string ("server", "password");
                    if (stored != "" && config.server_password == "") {
                        config.server_password = stored;
                    }
                }
            }
            if (key_file.has_group ("ui")) {
                if (key_file.has_key ("ui", "workspace-directory")) {
                    config.workspace_directory = key_file.get_string ("ui", "workspace-directory");
                }
                if (key_file.has_key ("ui", "notifications-enabled")) {
                    try {
                        config.notifications_enabled = key_file.get_boolean ("ui", "notifications-enabled");
                    } catch (Error e) {
                    }
                }
                if (key_file.has_key ("ui", "playful-status")) {
                    try {
                        config.playful_status = key_file.get_boolean ("ui", "playful-status");
                    } catch (Error e) {
                    }
                }
                if (key_file.has_key ("ui", "notify-turns")) {
                    try {
                        config.notify_turns = key_file.get_boolean ("ui", "notify-turns");
                    } catch (Error e) {
                    }
                }
                if (key_file.has_key ("ui", "notify-permissions")) {
                    try {
                        config.notify_permissions = key_file.get_boolean ("ui", "notify-permissions");
                    } catch (Error e) {
                    }
                }
                if (key_file.has_key ("ui", "notify-questions")) {
                    try {
                        config.notify_questions = key_file.get_boolean ("ui", "notify-questions");
                    } catch (Error e) {
                    }
                }
                if (key_file.has_key ("ui", "theme-mode")) {
                    var mode = key_file.get_string ("ui", "theme-mode");
                    if (mode == "light" || mode == "dark" || mode == "system") {
                        config.theme_mode = mode;
                    }
                }
                if (key_file.has_key ("ui", "confirm-delete")) {
                    try {
                        config.confirm_delete = key_file.get_boolean ("ui", "confirm-delete");
                    } catch (Error e) {
                    }
                }
                if (key_file.has_key ("ui", "send-with-ctrl-enter")) {
                    try {
                        config.send_with_ctrl_enter = key_file.get_boolean ("ui", "send-with-ctrl-enter");
                    } catch (Error e) {
                    }
                }
                if (key_file.has_key ("ui", "pinned-sessions")) {
                    try {
                        config.pinned_sessions = key_file.get_string_list ("ui", "pinned-sessions");
                    } catch (Error e) {
                    }
                }
                if (key_file.has_key ("ui", "archived-sessions")) {
                    try {
                        config.archived_sessions = key_file.get_string_list ("ui", "archived-sessions");
                    } catch (Error e) {
                    }
                }
                if (key_file.has_key ("ui", "workspace-history")) {
                    try {
                        config.workspace_history = key_file.get_string_list ("ui", "workspace-history");
                    } catch (Error e) {
                    }
                }
            }
        } catch (Error e) {
            warning ("Could not read config: %s", e.message);
        }

        return config;
    }

    public void save () {
        var key_file = new GLib.KeyFile ();
        key_file.set_string ("connection", "host", host);
        key_file.set_integer ("connection", "port", (int) port);
        key_file.set_string ("connection", "password", password);
        key_file.set_boolean ("server", "managed", manage_server);
        key_file.set_string ("server", "command", server_command);
        key_file.set_integer ("server", "port", (int) server_port);
        key_file.set_string ("server", "password", server_password);
        key_file.set_string ("ui", "workspace-directory", workspace_directory);
        key_file.set_boolean ("ui", "notifications-enabled", notifications_enabled);
        key_file.set_boolean ("ui", "notify-turns", notify_turns);
        key_file.set_boolean ("ui", "notify-permissions", notify_permissions);
        key_file.set_boolean ("ui", "notify-questions", notify_questions);
        key_file.set_boolean ("ui", "playful-status", playful_status);
        key_file.set_string ("ui", "theme-mode", theme_mode);
        key_file.set_boolean ("ui", "confirm-delete", confirm_delete);
        key_file.set_boolean ("ui", "send-with-ctrl-enter", send_with_ctrl_enter);
        key_file.set_string_list ("ui", "pinned-sessions", pinned_sessions);
        key_file.set_string_list ("ui", "archived-sessions", archived_sessions);
        key_file.set_string_list ("ui", "workspace-history", workspace_history);

        var data = key_file.to_data (null);
        var dir = config_dir ();
        var path = config_path ();

        /* Disk I/O runs off the main thread. */
        Work.submit (() => {
            try {
                GLib.DirUtils.create_with_parents (dir, 448); /* 0700 */
                GLib.FileUtils.set_contents (path, data);
                GLib.FileUtils.chmod (path, 384); /* 0600 */
            } catch (Error e) {
                warning ("Could not save config: %s", e.message);
            }
        });
    }

    /** The URL the app connects to (managed server, or the manual one). */
    public string base_url {
        owned get {
            return @"http://$(effective_host):$(effective_port)";
        }
    }
}

}
