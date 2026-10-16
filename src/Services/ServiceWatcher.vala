/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Read-only tap on the background opencode service (`opencode serve
 * --service`, what terminal CLIs talk to). That server shares the
 * session database with the app's managed server, so session ids
 * match, but each server only broadcasts events to its own SSE
 * subscribers. Without this tap, turns driven from a terminal never
 * move the sidebar indicators.
 *
 * Only status/activity merge into the store; messages, tools and all
 * actions stay on the managed connection. Discovery reuses the CLI's
 * own answers: `opencode service status` for the URL and
 * ~/.config/opencode/service.json for the password.
 */

namespace OpenClient {

public class ServiceWatcher : GLib.Object {
    public signal void state_changed ();

    /** Human-readable state for Settings ("" while starting). */
    public string detail { get; private set; default = ""; }
    public bool watching { get; private set; default = false; }

    private Config config;
    private Store store;
    private EventStream? stream = null;
    /** Debounces rediscovery after stream failures. */
    private uint rediscover_source = 0;
    private bool stopped = false;

    public ServiceWatcher (Config config, Store store) {
        this.config = config;
        this.store = store;
    }

    /** Starts watching (idempotent). Silent when there is no
     *  background service to tap. */
    public void watch () {
        if (stream != null || stopped) {
            return;
        }
        discover.begin ();
    }

    public void stop () {
        stopped = true;
        if (rediscover_source != 0) {
            GLib.Source.remove (rediscover_source);
            rediscover_source = 0;
        }
        if (stream != null) {
            stream.stop ();
            stream = null;
        }
        set_watch_state (false, "");
    }

    /** Service URL from the CLI itself (`opencode service status`
     *  prints it), or "" when the service is not running. */
    private async string discover_url () {
        var command = ServerProcess.find_command (config.server_command);
        if (command == null) {
            return "";
        }
        try {
            /* Variadic form on purpose: the argv-array form hits the
             *  same const-qualified-array vapi gap as the dialog
             *  buttons (see gtk-compat.c). */
            var launcher = new GLib.SubprocessLauncher (
                GLib.SubprocessFlags.STDOUT_PIPE | GLib.SubprocessFlags.STDERR_SILENCE);
            var proc = launcher.spawn (command, "service", "status");
            string? stdout_buf;
            string? stderr_buf;
            yield proc.communicate_utf8_async (null, null, out stdout_buf, out stderr_buf);
            if (!proc.get_successful ()) {
                return "";
            }
            var url = (stdout_buf ?? "").strip ();
            /* Sanity: must be an http(s) URL, not usage text. */
            if (!url.has_prefix ("http://") && !url.has_prefix ("https://")) {
                return "";
            }
            return url.split ("\n")[0].strip ();
        } catch (Error e) {
            debug ("Service discovery failed: %s", e.message);
            return "";
        }
    }

    /** Password the CLI stores for its background service. */
    private static string? service_password () {
        var path = GLib.Path.build_filename (
            GLib.Environment.get_user_config_dir (), "opencode", "service.json");
        try {
            string contents;
            GLib.FileUtils.get_contents (path, out contents);
            var parser = new Json.Parser ();
            parser.load_from_data (contents);
            var root = parser.get_root ();
            if (root != null && root.get_node_type () == Json.NodeType.OBJECT) {
                return JsonUtil.string_member (root.get_object (), "password");
            }
        } catch (Error e) {
            debug ("No service password: %s", e.message);
        }
        return null;
    }

    private async void discover () {
        var url = yield discover_url ();
        if (stopped) {
            return;
        }
        if (url == "") {
            /* No background service: stay quiet, the managed server
             *  covers everything. */
            set_watch_state (false, "");
            return;
        }
        var password = service_password ();
        if (password == null || password == "") {
            set_watch_state (false, "");
            return;
        }
        var auth = "Basic " + Base64.encode (("opencode:" + password).data);
        stream = new EventStream (url, auth);
        stream.event_handler = on_event;
        stream.connection_error.connect (() => {
            /* The service may have restarted on a new port: drop this
             *  stream and rediscover instead of reconnecting blindly. */
            if (stream != null) {
                stream.stop ();
                stream = null;
            }
            set_watch_state (false, "");
            schedule_rediscover ();
        });
        stream.start ();
        var port = "";
        try {
            var uri = GLib.Uri.parse (url, GLib.UriFlags.NONE);
            port = uri.get_port ().to_string ();
        } catch (Error e) {
        }
        set_watch_state (true, port != "" && port != "-1"
            ? @"Watching the background service (port $port) for terminal activity"
            : @"Watching the background service for terminal activity");
    }

    private void schedule_rediscover () {
        if (stopped || rediscover_source != 0 || stream != null) {
            return;
        }
        rediscover_source = GLib.Timeout.add_seconds (10, () => {
            rediscover_source = 0;
            discover.begin ();
            return false;
        });
    }

    private void set_watch_state (bool next, string detail) {
        var changed = next != watching || detail != this.detail;
        watching = next;
        this.detail = detail;
        if (changed) {
            state_changed ();
        }
    }

    /** Status/activity subset of the event catalog: enough to move
     *  sidebar indicators and the open-session state for turns the
     *  terminal drives. Anything content-bearing stays untouched:
     *  the managed stream owns the conversation. */
    private void on_event (string type, Json.Object data) {
        var session_id = JsonUtil.string_member (data, "sessionID");
        switch (type) {
            case "session.created":
            case "session.updated":
            case "session.deleted":
            case "session.forked":
            case "session.moved":
                /* Same database: our list follows both servers. */
                store.request_reload ();
                return;
            default:
                break;
        }
        if (session_id == null) {
            return;
        }
        switch (type) {
            case "session.execution.started":
            case "session.step.started":
                store.note_remote_status (session_id, "running", "Running");
                break;
            case "session.tool.called": {
                var name = JsonUtil.string_member (data, "name") ?? "";
                store.note_remote_status (session_id, "running",
                    name != "" ? @"Running · $name" : "Running");
                break;
            }
            case "session.compaction.started":
                store.note_remote_status (session_id, "compacting", "Compacting");
                break;
            case "session.execution.succeeded":
            case "session.execution.failed":
            case "session.execution.interrupted":
            case "session.compaction.ended":
            case "session.compaction.failed":
            case "session.idle":
                store.note_remote_status (session_id, "idle");
                break;
            case "permission.asked":
                store.note_remote_status (session_id, "waiting", "Waiting for permission");
                break;
            case "permission.replied":
            case "form.created":
                store.note_remote_status (session_id, "question", "Input needed");
                break;
            case "form.replied":
            case "form.cancelled":
                store.note_remote_status (session_id, "running", "Running");
                break;
            default:
                break;
        }
    }
}

}
