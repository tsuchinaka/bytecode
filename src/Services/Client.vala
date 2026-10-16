/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * HTTP client for the OpenCode v2 server API.
 *
 * Auth is HTTP Basic with username `opencode` and the server password
 * (OPENCODE_PASSWORD or the value printed by `opencode serve`).
 */

namespace OpenClient {

public errordomain RequestError {
    NETWORK_ERROR,
    HTTP_ERROR,
    PARSE_ERROR
}

public class Client : GLib.Object {
    public string host { get; construct; }
    public uint port { get; construct; }
    public string password { get; construct; }

    private Soup.Session soup;
    /** Cached because every request was rebuilding the interpolation +
     *  Base64 encode of the same string. */
    private string cached_auth_header;

    public Client (string host, uint port, string password) {
        Object (host: host, port: port, password: password);
    }

    construct {
        soup = new Soup.Session () {
            user_agent = "openclient/0.1",
            /* A hung server must not wedge the UI behind an
             *  unbounded request. */
            timeout = 60,
            idle_timeout = 60
        };
        cached_auth_header = "Basic " + Base64.encode (("opencode:" + password).data);
    }

    public string base_url {
        owned get {
            return @"http://$host:$port";
        }
    }

    public string auth_header {
        owned get {
            return cached_auth_header;
        }
    }

    public string event_url {
        owned get {
            return @"$base_url/api/event";
        }
    }

    private async Json.Node api_request (string method, string path, Json.Node? body = null) throws RequestError {
        var message = new Soup.Message (method, base_url + path);
        message.request_headers.append ("Authorization", auth_header);

        if (body != null) {
            var generator = new Json.Generator ();
            generator.set_root (body);
            size_t length;
            var data = generator.to_data (out length);
            message.set_request_body_from_bytes ("application/json", new Bytes (data.data));
        }

        GLib.Bytes response;
        try {
            response = yield soup.send_and_read_async (message, GLib.Priority.DEFAULT, null);
        } catch (Error e) {
            throw new RequestError.NETWORK_ERROR (e.message);
        }

        var data = response.get_data ();
        var text = "";
        if (data != null && data.length > 0) {
            /* Bytes carry no NUL terminator: copy exactly this many
             *  bytes (substring with an explicit end is ndup's drop-in
             *  replacement). */
            text = ((string) data).substring (0, (int) data.length);
        }

        if (message.status_code < 200 || message.status_code >= 300) {
            var detail = text.length > 300 ? text.substring (0, 300) : text;
            throw new RequestError.HTTP_ERROR (@"HTTP $(message.status_code): $detail");
        }

        if (text.strip () == "") {
            var empty = new Json.Node (Json.NodeType.OBJECT);
            empty.set_object (new Json.Object ());
            return empty;
        }

        return yield parse_json (text);
    }

    /** Parses a JSON document off the main thread. */
    private async Json.Node parse_json (string text) throws RequestError {
        Json.Node? root = null;
        string? error_message = null;

        Work.submit_with_resume (() => {
            var parser = new Json.Parser ();
            try {
                parser.load_from_data (text);
                root = parser.get_root ();
            } catch (Error e) {
                error_message = e.message;
            }
        }, parse_json.callback);

        yield;

        if (root == null) {
            throw new RequestError.PARSE_ERROR (error_message ?? "invalid JSON");
        }
        return root;
    }

    /** Returns the server version, or null when unreachable. */
    public async string? version () {
        try {
            var root = yield api_request ("GET", "/api/info");
            if (root.get_node_type () == Json.NodeType.OBJECT) {
                return JsonUtil.string_member (root.get_object (), "version");
            }
        } catch (Error e) {
            debug ("Version check failed: %s", e.message);
        }
        return null;
    }

    public async Gee.ArrayList<Session> list_sessions () throws RequestError {
        var result = new Gee.ArrayList<Session> ();
        var root = yield api_request ("GET", "/api/session");
        foreach (var obj in JsonUtil.data_objects (root)) {
            var session = Session.from_json (obj);
            if (session != null) {
                result.add (session);
            }
        }
        return result;
    }

    public async Session? create_session (string? title = null, string? directory = null) throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        if (title != null) {
            builder.set_member_name ("title");
            builder.add_string_value (title);
        }
        /* The server only accepts the workspace at creation time
         * (location.directory); later changes are ignored. */
        if (directory != null && directory.strip () != "") {
            builder.set_member_name ("location");
            builder.begin_object ();
            builder.set_member_name ("directory");
            builder.add_string_value (directory.strip ());
            builder.end_object ();
        }
        builder.end_object ();

        var root = yield api_request ("POST", "/api/session", builder.get_root ());
        var data = JsonUtil.data_object (root);
        return data != null ? Session.from_json (data) : null;
    }

    public async void delete_session (string session_id) throws RequestError {
        yield api_request ("DELETE", "/api/session/" + Uri.escape_string (session_id));
    }

    /** Sends a prompt; returns the created user message data, when present. */
    public async Json.Object? prompt (string session_id, string text, Gee.ArrayList<FileAttachment>? files = null) throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("text");
        builder.add_string_value (text);
        if (files != null && files.size > 0) {
            builder.set_member_name ("files");
            builder.begin_array ();
            foreach (var file in files) {
                builder.begin_object ();
                builder.set_member_name ("uri");
                builder.add_string_value (file.uri);
                if (file.name != "") {
                    builder.set_member_name ("name");
                    builder.add_string_value (file.name);
                }
                builder.end_object ();
            }
            builder.end_array ();
        }
        builder.end_object ();

        var root = yield api_request (
            "POST",
            "/api/session/" + Uri.escape_string (session_id) + "/prompt",
            builder.get_root ()
        );
        return JsonUtil.data_object (root);
    }

    public async void interrupt (string session_id) throws RequestError {
        yield api_request ("POST", "/api/session/" + Uri.escape_string (session_id) + "/interrupt");
    }

    public async Gee.ArrayList<ModelInfo> list_models () throws RequestError {
        var result = new Gee.ArrayList<ModelInfo> ();
        var root = yield api_request ("GET", "/api/model");
        foreach (var obj in JsonUtil.data_objects (root)) {
            var model = ModelInfo.from_json (obj);
            if (model != null && model.enabled) {
                result.add (model);
            }
        }
        return result;
    }

    public async Gee.ArrayList<AgentInfo> list_agents () throws RequestError {
        var result = new Gee.ArrayList<AgentInfo> ();
        var root = yield api_request ("GET", "/api/agent");
        foreach (var obj in JsonUtil.data_objects (root)) {
            var agent = AgentInfo.from_json (obj);
            if (agent != null) {
                result.add (agent);
            }
        }
        return result;
    }

    public async void set_model (string session_id, string provider_id, string model_id, string variant) throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("model");
        builder.begin_object ();
        builder.set_member_name ("id");
        builder.add_string_value (model_id);
        builder.set_member_name ("providerID");
        builder.add_string_value (provider_id);
        if (variant != "") {
            builder.set_member_name ("variant");
            builder.add_string_value (variant);
        }
        builder.end_object ();
        builder.end_object ();

        yield api_request ("POST", "/api/session/" + Uri.escape_string (session_id) + "/model", builder.get_root ());
    }

    public async void set_agent (string session_id, string agent_id) throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("agent");
        builder.add_string_value (agent_id);
        builder.end_object ();

        yield api_request ("POST", "/api/session/" + Uri.escape_string (session_id) + "/agent", builder.get_root ());
    }

    public async void reply_permission (string session_id, string request_id, string decision) throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("decision");
        builder.add_string_value (decision);
        builder.end_object ();

        yield api_request (
            "POST",
            "/api/session/" + Uri.escape_string (session_id) + "/permission/" + Uri.escape_string (request_id) + "/reply",
            builder.get_root ()
        );
    }

    public async Gee.ArrayList<CommandInfo> list_commands () throws RequestError {
        var result = new Gee.ArrayList<CommandInfo> ();
        var root = yield api_request ("GET", "/api/command");
        foreach (var obj in JsonUtil.data_objects (root)) {
            var command = CommandInfo.from_json (obj);
            if (command != null) {
                result.add (command);
            }
        }
        return result;
    }

    public async void execute_command (string session_id, string name, string text) throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("name");
        builder.add_string_value (name);
        builder.set_member_name ("text");
        builder.add_string_value (text);
        builder.end_object ();

        yield api_request ("POST", "/api/session/" + Uri.escape_string (session_id) + "/command", builder.get_root ());
    }

    public async void rename_session (string session_id, string title) throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("title");
        builder.add_string_value (title);
        builder.end_object ();

        yield api_request ("PATCH", "/api/session/" + Uri.escape_string (session_id), builder.get_root ());
    }

    /** Forks a session; returns the new session, when present. */
    public async Session? fork_session (string session_id) throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.end_object ();

        var root = yield api_request ("POST", "/api/session/" + Uri.escape_string (session_id) + "/fork", builder.get_root ());
        var data = JsonUtil.data_object (root);
        return data != null ? Session.from_json (data) : null;
    }

    /** Sets the session permission ruleset (used by the composer shield). */
    public async void set_permissions (string session_id, Json.Node permissions) throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("permissions");
        builder.add_value (permissions);
        builder.end_object ();

        yield api_request ("PATCH", "/api/session/" + Uri.escape_string (session_id), builder.get_root ());
    }

    public async void compact_session (string session_id) throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.end_object ();

        yield api_request ("POST", "/api/session/" + Uri.escape_string (session_id) + "/compact", builder.get_root ());
    }

    public async Gee.ArrayList<FileDiff> get_diff (string session_id) throws RequestError {
        var result = new Gee.ArrayList<FileDiff> ();
        var root = yield api_request ("GET", "/api/session/" + Uri.escape_string (session_id) + "/diff");
        foreach (var obj in JsonUtil.data_objects (root)) {
            var diff = FileDiff.from_json (obj);
            if (diff != null) {
                result.add (diff);
            }
        }
        return result;
    }

    /** Pending question forms for a session (state.status == "pending"). */
    public async Gee.ArrayList<FormInfo> list_forms (string session_id) throws RequestError {
        var result = new Gee.ArrayList<FormInfo> ();
        var root = yield api_request ("GET", "/api/session/" + Uri.escape_string (session_id) + "/form");
        foreach (var obj in JsonUtil.data_objects (root)) {
            var state = JsonUtil.object_member (obj, "state");
            if (state != null && (JsonUtil.string_member (state, "status") ?? "") != "pending") {
                continue;
            }
            var form = FormInfo.from_json (obj);
            if (form != null) {
                form.session_id = session_id;
                result.add (form);
            }
        }
        return result;
    }

    /** Cancels a pending form server-side (the agent is told why). */
    public async void cancel_form (string session_id, string form_id, string message = "") throws RequestError {
        var path = "/api/session/" + Uri.escape_string (session_id)
            + "/form/" + Uri.escape_string (form_id);
        if (message != "") {
            path += "?message=" + Uri.escape_string (message);
        }
        yield api_request ("DELETE", path);
    }

    public async void reply_form (string session_id, string form_id, Json.Node answer) throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("answer");
        builder.add_value (answer);
        builder.end_object ();

        yield api_request (
            "POST",
            "/api/session/" + Uri.escape_string (session_id) + "/form/" + Uri.escape_string (form_id) + "/reply",
            builder.get_root ()
        );
    }

    /** Live context-window usage (input + output + cache read of the
        latest snapshot), or -1 when unknown. */
    public async int64 context_used (string session_id) {
        try {
            var root = yield api_request ("GET", "/api/session/" + Uri.escape_string (session_id) + "/context");
            int64 used = -1;
            foreach (var obj in JsonUtil.data_objects (root)) {
                var tokens = JsonUtil.object_member (obj, "tokens");
                if (tokens == null) {
                    continue;
                }
                int64 input = JsonUtil.int_member (tokens, "input");
                int64 output = JsonUtil.int_member (tokens, "output");
                var cache = JsonUtil.object_member (tokens, "cache");
                int64 cached = cache != null ? JsonUtil.int_member (cache, "read") : 0;
                used = input + output + cached;
            }
            return used;
        } catch (Error e) {
            debug ("Context usage failed: %s", e.message);
            return -1;
        }
    }

    /** Projected messages for a session, oldest first. */
    public async Gee.ArrayList<Message> list_messages (string session_id) throws RequestError {
        var result = new Gee.ArrayList<Message> ();
        var root = yield api_request ("GET", "/api/session/" + Uri.escape_string (session_id) + "/message");
        foreach (var obj in JsonUtil.data_objects (root)) {
            var message = Message.from_json (obj);
            if (message != null) {
                result.add (message);
            }
        }
        if (result.size > 1 && result[0].created > result[result.size - 1].created) {
            var reversed = new Gee.ArrayList<Message> ();
            for (int i = result.size - 1; i >= 0; i--) {
                reversed.add (result[i]);
            }
            return reversed;
        }

        return result;
    }

    /* -- full v2 surface ---------------------------------------------
     *
     * Every endpoint below was verified live against opencode 2.0.29
     * (method + path + body shape). Models are returned where the UI
     * consumes them (Session, Message, AgentInfo, ModelInfo, FormInfo,
     * PermissionRequest); admin/config surfaces come back as Json for
     * callers to read with JsonUtil. Live-execution plumbing (pty,
     * shells, tunnels, rpc, fs writes, vcs mutations, pair, debug)
     * stays on the generic request() escape hatch: reachable, but
     * with no app use case to type it for. */

    /** One session by id. */
    public async Session? get_session (string session_id) throws RequestError {
        var root = yield api_request ("GET", "/api/session/" + Uri.escape_string (session_id));
        var data = JsonUtil.data_object (root);
        return data != null ? Session.from_json (data) : null;
    }

    /** Marks the idle transition as viewed (called when a session is
     *  opened, so unread tracking settles). */
    public async void mark_viewed (string session_id) throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("idle");
        builder.add_int_value (GLib.get_real_time () / 1000);
        builder.end_object ();

        yield api_request (
            "POST",
            "/api/session/" + Uri.escape_string (session_id) + "/view",
            builder.get_root ()
        );
    }

    /** Moves blocking tool execution to the background. */
    public async void background_session (string session_id) throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.end_object ();

        yield api_request (
            "POST",
            "/api/session/" + Uri.escape_string (session_id) + "/background",
            builder.get_root ()
        );
    }

    /** Moves a session to another project directory at the next
     *  delivery boundary. */
    public async void move_session (string session_id, string directory) throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("directory");
        builder.add_string_value (directory);
        builder.end_object ();

        yield api_request (
            "POST",
            "/api/session/" + Uri.escape_string (session_id) + "/move",
            builder.get_root ()
        );
    }

    /** Appends a synthetic (system-note) message; returns its id. */
    public async string synthetic (string session_id, string text, string description = "") throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("text");
        builder.add_string_value (text);
        if (description != "") {
            builder.set_member_name ("description");
            builder.add_string_value (description);
        }
        builder.end_object ();

        var root = yield api_request (
            "POST",
            "/api/session/" + Uri.escape_string (session_id) + "/synthetic",
            builder.get_root ()
        );
        var data = JsonUtil.data_object (root);
        return data != null ? (JsonUtil.string_member (data, "id") ?? "") : "";
    }

    /** Global usage stats (sessions, tokens, cost, activity). */
    public async Json.Object? session_stats () throws RequestError {
        var root = yield api_request ("GET", "/api/experimental/session/stats");
        return JsonUtil.data_object (root);
    }

    /** Full session export (messages included); optionally sanitized. */
    public async Json.Node export_session (string session_id, bool sanitize = true) throws RequestError {
        return yield api_request (
            "GET",
            "/api/experimental/session/" + Uri.escape_string (session_id)
                + "/export?sanitize=" + (sanitize ? "true" : "false")
        );
    }

    /** One message by id. */
    public async Message? get_message (string session_id, string message_id) throws RequestError {
        var root = yield api_request (
            "GET",
            "/api/session/" + Uri.escape_string (session_id)
                + "/message/" + Uri.escape_string (message_id)
        );
        var data = JsonUtil.data_object (root);
        return data != null ? Message.from_json (data) : null;
    }

    /** Pending inbox items (undelivered prompts/steers). */
    public async Json.Node list_inbox (string session_id) throws RequestError {
        return yield api_request ("GET", "/api/session/" + Uri.escape_string (session_id) + "/inbox");
    }

    /** Cancels an undelivered inbox item. */
    public async void cancel_inbox (string session_id, string inbox_id) throws RequestError {
        yield api_request (
            "DELETE",
            "/api/session/" + Uri.escape_string (session_id)
                + "/inbox/" + Uri.escape_string (inbox_id)
        );
    }

    /** Changes a pending inbox item's delivery mode. */
    public async void set_inbox_delivery (string session_id, string inbox_id, string delivery) throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("delivery");
        builder.add_string_value (delivery);
        builder.end_object ();

        yield api_request (
            "PATCH",
            "/api/session/" + Uri.escape_string (session_id)
                + "/inbox/" + Uri.escape_string (inbox_id),
            builder.get_root ()
        );
    }

    /** Durable instruction entries ({key: value}). */
    public async Gee.HashMap<string, string> list_instructions (string session_id) throws RequestError {
        var result = new Gee.HashMap<string, string> ();
        var root = yield api_request (
            "GET",
            "/api/experimental/session/" + Uri.escape_string (session_id) + "/instructions/entries"
        );
        foreach (var obj in JsonUtil.data_objects (root)) {
            var key = JsonUtil.string_member (obj, "key");
            var value = JsonUtil.string_member (obj, "value");
            if (key != null && value != null) {
                result[key] = value;
            }
        }
        return result;
    }

    /** Attaches or replaces one durable instruction entry. */
    public async void put_instruction (string session_id, string key, string value) throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("value");
        builder.add_string_value (value);
        builder.end_object ();

        yield api_request (
            "PUT",
            "/api/experimental/session/" + Uri.escape_string (session_id)
                + "/instructions/entries/" + Uri.escape_string (key),
            builder.get_root ()
        );
    }

    public async void remove_instruction (string session_id, string key) throws RequestError {
        yield api_request (
            "DELETE",
            "/api/experimental/session/" + Uri.escape_string (session_id)
                + "/instructions/entries/" + Uri.escape_string (key)
        );
    }

    /** Replaces the environment for local shell commands. */
    public async void set_environment (string session_id, Gee.Map<string, string> variables) throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("variables");
        builder.begin_object ();
        foreach (var entry in variables.entries) {
            builder.set_member_name (entry.key);
            builder.add_string_value (entry.value);
        }
        builder.end_object ();
        builder.end_object ();

        yield api_request (
            "PUT",
            "/api/session/" + Uri.escape_string (session_id) + "/environment",
            builder.get_root ()
        );
    }

    /** Creates a permission request; returns its id. */
    public async string create_permission (string session_id, string action,
        Gee.Collection<string> resources) throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("action");
        builder.add_string_value (action);
        builder.set_member_name ("resources");
        builder.begin_array ();
        foreach (var resource in resources) {
            builder.add_string_value (resource);
        }
        builder.end_array ();
        builder.end_object ();

        var root = yield api_request (
            "POST",
            "/api/session/" + Uri.escape_string (session_id) + "/permission",
            builder.get_root ()
        );
        var data = JsonUtil.data_object (root);
        return data != null ? (JsonUtil.string_member (data, "id") ?? "") : "";
    }

    /** Open permission requests for a session. */
    public async Gee.ArrayList<PermissionRequest> list_permissions (string session_id) throws RequestError {
        var result = new Gee.ArrayList<PermissionRequest> ();
        var root = yield api_request ("GET", "/api/session/" + Uri.escape_string (session_id) + "/permission");
        foreach (var obj in JsonUtil.data_objects (root)) {
            var id = JsonUtil.string_member (obj, "id");
            if (id == null) {
                continue;
            }
            var request = new PermissionRequest () {
                id = id,
                session_id = session_id,
                action = JsonUtil.string_member (obj, "action") ?? ""
            };
            request.resources = ListArrays.join (", ", JsonUtil.array_strings (obj, "resources"));
            result.add (request);
        }
        return result;
    }

    /** One permission request by id. */
    public async PermissionRequest? get_permission (string session_id, string request_id) throws RequestError {
        var root = yield api_request (
            "GET",
            "/api/session/" + Uri.escape_string (session_id)
                + "/permission/" + Uri.escape_string (request_id)
        );
        var data = JsonUtil.data_object (root);
        if (data == null) {
            return null;
        }
        var request = new PermissionRequest () {
            id = JsonUtil.string_member (data, "id") ?? request_id,
            session_id = session_id,
            action = JsonUtil.string_member (data, "action") ?? ""
        };
        request.resources = ListArrays.join (", ", JsonUtil.array_strings (data, "resources"));
        return request;
    }

    /** Creates a form (question card) on a session; returns it. */
    public async FormInfo? create_form (string session_id, string title, Json.Node fields) throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("title");
        builder.add_string_value (title);
        builder.set_member_name ("fields");
        builder.add_value (fields);
        builder.end_object ();

        var root = yield api_request (
            "POST",
            "/api/session/" + Uri.escape_string (session_id) + "/form",
            builder.get_root ()
        );
        var data = JsonUtil.data_object (root);
        if (data == null) {
            return null;
        }
        var form = FormInfo.from_json (data);
        if (form != null && form.session_id == "") {
            form.session_id = session_id;
        }
        return form;
    }

    /** One form by id. */
    public async FormInfo? get_form (string session_id, string form_id) throws RequestError {
        var root = yield api_request (
            "GET",
            "/api/session/" + Uri.escape_string (session_id)
                + "/form/" + Uri.escape_string (form_id)
        );
        var data = JsonUtil.data_object (root);
        if (data == null) {
            return null;
        }
        var form = FormInfo.from_json (data);
        if (form != null && form.session_id == "") {
            form.session_id = session_id;
        }
        return form;
    }

    /** Stages a revert boundary at a message; returns whether the
     *  server staged one. Follows with commit_revert(), or
     *  clear_revert() on failure (the t3code-verified flow). */
    public async bool stage_revert (string session_id, string message_id,
        Gee.Collection<string>? files = null) throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("messageID");
        builder.add_string_value (message_id);
        if (files != null) {
            builder.set_member_name ("files");
            builder.begin_array ();
            foreach (var file in files) {
                builder.add_string_value (file);
            }
            builder.end_array ();
        }
        builder.end_object ();

        var root = yield api_request (
            "POST",
            "/api/session/" + Uri.escape_string (session_id) + "/revert/stage",
            builder.get_root ()
        );
        /* {data: bool} is a VALUE node, not an object, so read it raw. */
        if (root.get_node_type () != Json.NodeType.OBJECT) {
            return false;
        }
        var data = root.get_object ().get_member ("data");
        return data != null
            && data.get_node_type () == Json.NodeType.VALUE
            && data.get_value_type () == typeof (bool)
            && data.get_boolean ();
    }

    public async void commit_revert (string session_id) throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.end_object ();

        yield api_request (
            "POST",
            "/api/session/" + Uri.escape_string (session_id) + "/revert/commit",
            builder.get_root ()
        );
    }

    public async void clear_revert (string session_id) throws RequestError {
        yield api_request ("DELETE", "/api/session/" + Uri.escape_string (session_id) + "/revert");
    }

    /** One agent by id. Unlike the list, the single get requires a
     *  directory scope (verified live: unscoped returns
     *  AgentNotFoundError). */
    public async AgentInfo? get_agent (string agent_id, string directory = "") throws RequestError {
        var path = "/api/agent/" + Uri.escape_string (agent_id);
        if (directory != "") {
            path += "?directory=" + Uri.escape_string (directory);
        }
        var root = yield api_request ("GET", path);
        var data = JsonUtil.data_object (root);
        return data != null ? AgentInfo.from_json (data) : null;
    }

    /** The server default model. */
    public async ModelInfo? default_model () throws RequestError {
        var root = yield api_request ("GET", "/api/model/default");
        var data = JsonUtil.data_object (root);
        return data != null ? ModelInfo.from_json (data) : null;
    }

    /** Global server configuration sources. */
    public async Json.Node server_config () throws RequestError {
        return yield api_request ("GET", "/api/config");
    }

    /** One provider by id (raw: endpoint, package, auth state). */
    public async Json.Object? get_provider (string provider_id) throws RequestError {
        var root = yield api_request ("GET", "/api/provider/" + Uri.escape_string (provider_id));
        return JsonUtil.data_object (root);
    }

    public async Json.Node list_integrations () throws RequestError {
        return yield api_request ("GET", "/api/integration");
    }

    public async Json.Object? get_integration (string integration_id) throws RequestError {
        var root = yield api_request ("GET", "/api/integration/" + Uri.escape_string (integration_id));
        return JsonUtil.data_object (root);
    }

    public async Json.Node list_saved_permissions () throws RequestError {
        return yield api_request ("GET", "/api/permission/saved");
    }

    public async void delete_saved_permission (string id) throws RequestError {
        yield api_request ("DELETE", "/api/permission/saved/" + Uri.escape_string (id));
    }

    public async Json.Node list_skills () throws RequestError {
        return yield api_request ("GET", "/api/skill");
    }

    public async Json.Node list_references () throws RequestError {
        return yield api_request ("GET", "/api/reference");
    }

    public async Json.Node list_locations () throws RequestError {
        return yield api_request ("GET", "/api/location");
    }

    public async void reload_locations () throws RequestError {
        yield api_request ("POST", "/api/location/reload");
    }

    public async Json.Node mcp_catalog () throws RequestError {
        return yield api_request ("GET", "/api/mcp/resource");
    }

    /** Registers (or replaces) an MCP server; verified shape is
     *  {config: {type, command[], ...}, enabled?}. */
    public async void put_mcp (string server, Json.Node config, bool enabled = true) throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("config");
        builder.add_value (config);
        builder.set_member_name ("enabled");
        builder.add_boolean_value (enabled);
        builder.end_object ();

        yield api_request (
            "PUT",
            "/api/experimental/mcp/" + Uri.escape_string (server),
            builder.get_root ()
        );
    }

    public async void delete_mcp (string server) throws RequestError {
        yield api_request ("DELETE", "/api/experimental/mcp/" + Uri.escape_string (server));
    }

    /** Creates a stored credential for an integration. The payload
     *  shape depends on the integration (api key, oauth, …), so it
     *  passes through as Json. */
    public async Json.Object? create_credential (Json.Node payload) throws RequestError {
        var root = yield api_request ("POST", "/api/credential", payload);
        return JsonUtil.data_object (root);
    }

    public async void update_credential (string id, string label) throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("label");
        builder.add_string_value (label);
        builder.end_object ();

        yield api_request (
            "PATCH",
            "/api/credential/" + Uri.escape_string (id),
            builder.get_root ()
        );
    }

    public async void delete_credential (string id) throws RequestError {
        yield api_request ("DELETE", "/api/credential/" + Uri.escape_string (id));
    }

    /** Refreshes worktree discovery for a project. */
    public async void refresh_worktrees (string project_id) throws RequestError {
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("projectID");
        builder.add_string_value (project_id);
        builder.end_object ();

        yield api_request ("POST", "/api/worktree/refresh", builder.get_root ());
    }

    public async Json.Node list_plugins () throws RequestError {
        return yield api_request ("GET", "/api/plugin");
    }

    /** Generic escape hatch: call ANY endpoint in the OpenCode API. */
    public async Json.Node request (string method, string path, Json.Node? body = null) throws RequestError {
        return yield api_request (method, path, body);
    }
}

}

