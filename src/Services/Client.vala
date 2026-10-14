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

    public Client (string host, uint port, string password) {
        Object (host: host, port: port, password: password);
    }

    construct {
        soup = new Soup.Session () {
            user_agent = "openclient/0.1"
        };
    }

    public string base_url {
        owned get {
            return @"http://$host:$port";
        }
    }

    public string auth_header {
        owned get {
            return "Basic " + Base64.encode ((@"opencode:$password").data);
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
            /* Bytes carry no NUL terminator: duplicate with explicit length. */
            text = ((string) data).ndup (data.length);
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
        SourceFunc callback = parse_json.callback;
        Json.Node? root = null;
        string? error_message = null;

        Work.submit (() => {
            var parser = new Json.Parser ();
            try {
                parser.load_from_data (text);
                root = parser.get_root ();
            } catch (Error e) {
                error_message = e.message;
            }
            Work.resume (callback);
        });

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

    /** Generic escape hatch: call ANY endpoint in the OpenCode API. */
    public async Json.Node request (string method, string path, Json.Node? body = null) throws RequestError {
        return yield api_request (method, path, body);
    }
}

}

