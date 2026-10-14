/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Session model, mirroring the OpenCode v2 `Session.Info` shape.
 */

namespace OpenClient {

public class Session : GLib.Object {
    public string id { get; set; default = ""; }
    public string title { get; set; default = ""; }
    public string directory { get; set; default = ""; }
    public string agent { get; set; default = ""; }
    public string model { get; set; default = ""; }
    public string model_id { get; set; default = ""; }
    public string provider_id { get; set; default = ""; }
    public string variant { get; set; default = ""; }
    public double cost { get; set; default = 0.0; }
    public int64 input_tokens { get; set; default = 0; }
    public int64 output_tokens { get; set; default = 0; }
    public int64 updated { get; set; default = 0; }
    /** Coarse permission mode inferred from the session's ruleset:
     *  "readonly", "ask" or "yolo". */
    public string permission_mode { get; set; default = "ask"; }
    /** Client-side only: pinned sessions sort first. Kept out of
     *  from_json (the server has no such concept) and applied by the
     *  store from persisted config after every reload. */
    public bool pinned { get; set; default = false; }
    /** Client-side only: archived sessions hide from the All/Pinned
     *  filters and show under Archived. Same sourcing as pinned. */
    public bool archived { get; set; default = false; }

    public static Session? from_json (Json.Object obj) {
        var id = JsonUtil.string_member (obj, "id");
        if (id == null) {
            return null;
        }

        var session = new Session () { id = id };
        session.title = JsonUtil.string_member (obj, "title") ?? "Untitled";
        session.agent = JsonUtil.string_member (obj, "agent") ?? "";

        var location = JsonUtil.object_member (obj, "location");
        if (location != null) {
            session.directory = JsonUtil.string_member (location, "directory") ?? "";
        }

        var model = JsonUtil.object_member (obj, "model");
        if (model != null) {
            var provider = JsonUtil.string_member (model, "providerID") ?? "";
            var model_id = JsonUtil.string_member (model, "id") ?? "";
            var variant = JsonUtil.string_member (model, "variant") ?? "";
            session.provider_id = provider;
            session.model_id = model_id;
            session.variant = variant;
            session.model = @"$provider/$model_id";
            if (variant != "") {
                session.model = @"$(session.model)#$variant";
            }
        }

        session.cost = JsonUtil.double_member (obj, "cost");

        var tokens = JsonUtil.object_member (obj, "tokens");
        if (tokens != null) {
            session.input_tokens = JsonUtil.int_member (tokens, "input");
            session.output_tokens = JsonUtil.int_member (tokens, "output");
        }

        var time = JsonUtil.object_member (obj, "time");
        if (time != null) {
            session.updated = JsonUtil.int_member (time, "updated");
        }

        /* Infer the coarse permission mode from the session's ruleset. */
        var mode = "ask";
        foreach (var rule in JsonUtil.array_objects (obj, "permissions")) {
            var action = JsonUtil.string_member (rule, "action") ?? "";
            var resource = JsonUtil.string_member (rule, "resource") ?? "";
            var effect = JsonUtil.string_member (rule, "effect") ?? "";
            if (action == "*" && resource == "*") {
                if (effect == "deny") {
                    mode = "readonly";
                } else if (effect == "ask") {
                    mode = "ask";
                } else if (effect == "allow") {
                    mode = "yolo";
                }
            }
        }
        session.permission_mode = mode;

        return session;
    }

    public string directory_name {
        owned get {
            if (directory == "" || directory == "/") {
                return directory;
            }
            return GLib.Path.get_basename (directory);
        }
    }
}

}
