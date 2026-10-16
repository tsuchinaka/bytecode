/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Message model, mirroring the OpenCode v2 projected message shape:
 *   user      -> { id, time, text, type: "user" }
 *   assistant -> { id, time, type: "assistant", content: [ {type: text|reasoning|tool}, ... ] }
 */

namespace OpenClient {

public enum MessageRole {
    USER,
    ASSISTANT,
    SYSTEM,
    OTHER
}

public enum PartKind {
    TEXT,
    REASONING,
    TOOL,
    FILE,
    /** A failed turn's provider error (finish == "error"). Rendered
     *  as a persistent error line so failures survive reopening. */
    ERROR,
    OTHER
}

public class FileAttachment : GLib.Object {
    public string uri { get; set; default = ""; }
    public string name { get; set; default = ""; }
    public string mime { get; set; default = ""; }
    public string data_base64 { get; set; default = ""; }

    public bool is_image {
        get {
            return mime.has_prefix ("image/");
        }
    }

    public string display_name {
        owned get {
            if (name != "") {
                return name;
            }
            if (uri.has_prefix ("file://")) {
                return GLib.Path.get_basename (uri.substring (7));
            }
            return "attachment";
        }
    }

    public static FileAttachment? from_data_uri (string uri, string name = "") {
        if (!uri.has_prefix ("data:")) {
            return null;
        }
        var comma = uri.index_of_char (',');
        if (comma < 0) {
            return null;
        }
        var meta = uri.substring (5, comma - 5);
        var mime = meta.split (";")[0];
        return new FileAttachment () {
            uri = uri,
            name = name,
            mime = mime != "" ? mime : "application/octet-stream",
            data_base64 = uri.substring (comma + 1)
        };
    }

    public static FileAttachment? from_json (Json.Object obj) {
        var attachment = new FileAttachment ();
        attachment.data_base64 = JsonUtil.string_member (obj, "data") ?? "";
        attachment.mime = JsonUtil.string_member (obj, "mime") ?? "";
        attachment.name = JsonUtil.string_member (obj, "name") ?? "";
        var source = JsonUtil.object_member (obj, "source");
        if (source != null) {
            attachment.uri = JsonUtil.string_member (source, "uri") ?? "";
            if (attachment.mime == "") {
                attachment.mime = JsonUtil.string_member (source, "mime") ?? "";
            }
        }
        if (attachment.uri == "") {
            attachment.uri = JsonUtil.string_member (obj, "uri") ?? "";
        }
        /* Legacy text-only attachments carry no payload to render. */
        if (attachment.uri == "" && attachment.data_base64 == "") {
            return null;
        }
        if (attachment.mime == "") {
            attachment.mime = guess_mime (attachment.uri, attachment.name);
        }
        return attachment;
    }

    private static string guess_mime (string uri, string name) {
        var lower = (name != "" ? name : uri).down ();
        if (lower.has_suffix (".png")) return "image/png";
        if (lower.has_suffix (".jpg") || lower.has_suffix (".jpeg")) return "image/jpeg";
        if (lower.has_suffix (".gif")) return "image/gif";
        if (lower.has_suffix (".webp")) return "image/webp";
        if (lower.has_suffix (".svg")) return "image/svg+xml";
        if (lower.has_suffix (".bmp")) return "image/bmp";
        return "application/octet-stream";
    }

    /** Decodes the attachment into a pixbuf, capped at max_px on its long side. */
    public Gdk.Pixbuf? load_pixbuf (int max_px = 320) {
        uint8[]? bytes = null;
        if (data_base64 != "") {
            bytes = GLib.Base64.decode (data_base64);
        } else if (uri.has_prefix ("file://")) {
            try {
                uint8[] contents;
                string? etag;
                var file = GLib.File.new_for_uri (uri);
                /* The vapi maps this to an out uint8[], which Gio's
                 * char** prototype does not accept (see gtk-compat.c). */
                OpenClient.file_load_contents_raw (file, null, out contents, out etag);
                bytes = contents;
            } catch (Error e) {
                warning ("Could not load attachment %s: %s", uri, e.message);
                return null;
            }
        }
        if (bytes == null || bytes.length == 0) {
            return null;
        }
        try {
            var loader = new Gdk.PixbufLoader ();
            loader.write (bytes);
            loader.close ();
            var pixbuf = loader.get_pixbuf ();
            if (pixbuf == null) {
                return null;
            }
            if (int.max (pixbuf.width, pixbuf.height) <= max_px) {
                return pixbuf;
            }
            double scale = (double) max_px / (double) int.max (pixbuf.width, pixbuf.height);
            int width = int.max (1, (int) (pixbuf.width * scale));
            int height = int.max (1, (int) (pixbuf.height * scale));
            return pixbuf.scale_simple (width, height, Gdk.InterpType.BILINEAR);
        } catch (Error e) {
            warning ("Could not decode attachment %s: %s", display_name, e.message);
            return null;
        }
    }

    /** Decodes the attachment on a worker thread; the pixbuf is safe to
     *  turn into a texture on the main thread once this resumes. */
    public async Gdk.Pixbuf? load_pixbuf_async (int max_px = 320) {
        Gdk.Pixbuf? pixbuf = null;

        Work.submit_with_resume (() => {
            pixbuf = load_pixbuf (max_px);
        }, load_pixbuf_async.callback);

        yield;
        return pixbuf;
    }
}

public class MessagePart : GLib.Object {
    public PartKind kind { get; set; default = PartKind.OTHER; }
    public string text { get; set; default = ""; }
    public string tool_name { get; set; default = ""; }
    public string tool_status { get; set; default = ""; }
    public string tool_id { get; set; default = ""; }
    public string tool_input_summary { get; set; default = ""; }
    public string tool_output { get; set; default = ""; }
    public Gee.ArrayList<FileAttachment> tool_files;
    public int64 time_created { get; set; default = 0; }
    public int64 time_completed { get; set; default = 0; }
    public FileAttachment? file { get; set; default = null; }

    public MessagePart () {
        tool_files = new Gee.ArrayList<FileAttachment> ();
    }

    public string duration_label {
        owned get {
            if (time_created <= 0 || time_completed <= time_created) {
                return "";
            }
            var millis = time_completed - time_created;
            if (millis < 1000) {
                return "";
            }
            if (millis < 10000) {
                return "%.1fs".printf (millis / 1000.0);
            }
            return @"$((millis + 500) / 1000)s";
        }
    }
}

public class Message : GLib.Object {
    public string id { get; set; default = ""; }
    public MessageRole role { get; set; default = MessageRole.OTHER; }
    public int64 created { get; set; default = 0; }
    /** Model that produced an assistant turn (`provider/model`), when
     *  the server reports one. Used for the "Assistant · model" line. */
    public string model { get; set; default = ""; }
    /** Agent an assistant turn ran as, when the server reports one. */
    public string agent { get; set; default = ""; }
    public int64 completed { get; set; default = 0; }
    public string finish { get; set; default = ""; }
    public double cost { get; set; default = 0.0; }
    public int64 input_tokens { get; set; default = 0; }
    public int64 output_tokens { get; set; default = 0; }
    public int64 reasoning_tokens { get; set; default = 0; }
    public int64 cache_read { get; set; default = 0; }
    public int64 cache_write { get; set; default = 0; }
    public string system_status { get; set; default = ""; }
    public string system_reason { get; set; default = ""; }
    public string system_summary { get; set; default = ""; }
    public string system_icon { get; set; default = ""; }
    public Gee.ArrayList<MessagePart> parts;

    public Message () {
        parts = new Gee.ArrayList<MessagePart> ();
    }

    public string plain_text {
        owned get {
            var builder = new StringBuilder ();
            foreach (var part in parts) {
                if (part.kind == PartKind.TEXT && part.text != "") {
                    if (builder.len > 0) {
                        builder.append ("\n\n");
                    }
                    builder.append (part.text);
                }
            }
            return builder.str;
        }
    }

    /** Text shown on a centered system divider. */
    public string divider_text () {
        switch (system_status) {
            case "running":
                return system_reason == "auto" ? "Compacting context (auto)…" : "Compacting context…";
            case "failed":
                return "Compaction failed";
            case "completed":
                return system_reason == "auto" ? "Context compacted (auto)" : "Context compacted";
            default:
                break;
        }
        return plain_text;
    }

    public string divider_status () {
        switch (system_status) {
            case "running":
                return "running";
            case "failed":
                return "error";
            default:
                return "done";
        }
    }

    public bool renderable {
        get {
            switch (role) {
                case MessageRole.SYSTEM:
                    return divider_text () != "" || system_status != "";
                default:
                    break;
            }
            foreach (var part in parts) {
                if (part.kind == PartKind.TOOL || part.kind == PartKind.FILE
                    || part.kind == PartKind.ERROR) {
                    return true;
                }
                if (part.text.strip () != "") {
                    return true;
                }
            }
            return false;
        }
    }

    public static Message? from_json (Json.Object obj) {
        var id = JsonUtil.string_member (obj, "id");
        var type = JsonUtil.string_member (obj, "type");
        if (id == null || type == null) {
            return null;
        }

        var message = new Message () { id = id };

        /* Assistant turns carry the model and agent that produced them,
         *  which the conversation labels them with. Live turns learn it
         *  from the event stream, so history reads it here to keep the
         *  two paths identical. */
        var turn_model = JsonUtil.object_member (obj, "model");
        if (turn_model != null) {
            var model_id = JsonUtil.string_member (turn_model, "id") ?? "";
            var provider_id = JsonUtil.string_member (turn_model, "providerID") ?? "";
            if (model_id != "") {
                message.model = provider_id != "" ? @"$provider_id/$model_id" : model_id;
            }
        }
        message.agent = JsonUtil.string_member (obj, "agent") ?? "";

        switch (type) {
            case "user":
                message.role = MessageRole.USER;
                var text = JsonUtil.string_member (obj, "text");
                if (text == null) {
                    var payload = JsonUtil.object_member (obj, "payload");
                    if (payload != null) {
                        text = JsonUtil.string_member (payload, "text");
                    }
                }
                message.parts.add (new MessagePart () {
                    kind = PartKind.TEXT,
                    text = text ?? ""
                });
                foreach (var file_obj in JsonUtil.array_objects (obj, "files")) {
                    var attachment = FileAttachment.from_json (file_obj);
                    if (attachment != null) {
                        message.parts.add (new MessagePart () {
                            kind = PartKind.FILE,
                            file = attachment
                        });
                    }
                }
                break;

            case "assistant":
                message.role = MessageRole.ASSISTANT;
                foreach (var item in JsonUtil.array_objects (obj, "content")) {
                    var part = new MessagePart ();
                    switch (JsonUtil.string_member (item, "type") ?? "") {
                        case "text":
                            part.kind = PartKind.TEXT;
                            part.text = JsonUtil.string_member (item, "text") ?? "";
                            break;
                        case "reasoning":
                            part.kind = PartKind.REASONING;
                            part.text = JsonUtil.string_member (item, "text") ?? "";
                            var reasoning_time = JsonUtil.object_member (item, "time");
                            if (reasoning_time != null) {
                                part.time_created = JsonUtil.int_member (reasoning_time, "created");
                                part.time_completed = JsonUtil.int_member (reasoning_time, "completed");
                            }
                            break;
                        case "tool":
                            part.kind = PartKind.TOOL;
                            part.tool_name = JsonUtil.string_member (item, "name") ?? "tool";
                            part.tool_id = JsonUtil.string_member (item, "id") ?? "";
                            var state = JsonUtil.object_member (item, "state");
                            if (state != null) {
                                part.tool_status = JsonUtil.string_member (state, "status") ?? "";
                                var input = JsonUtil.object_member (state, "input");
                                part.tool_input_summary = ToolCard.summarize_input (part.tool_name, input);
                                var outputs = new StringBuilder ();
                                foreach (var content_obj in JsonUtil.array_objects (state, "content")) {
                                    var content_type = JsonUtil.string_member (content_obj, "type") ?? "";
                                    if (content_type == "text") {
                                        var chunk = JsonUtil.string_member (content_obj, "text") ?? "";
                                        if (chunk != "") {
                                            if (outputs.len > 0) {
                                                outputs.append ("\n");
                                            }
                                            outputs.append (chunk);
                                        }
                                    } else if (content_type == "file") {
                                        var uri = JsonUtil.string_member (content_obj, "uri") ?? "";
                                        var file = FileAttachment.from_data_uri (uri);
                                        if (file != null) {
                                            part.tool_files.add (file);
                                        }
                                    }
                                }
                                part.tool_output = outputs.str;
                                if (part.tool_output.length > 4000) {
                                    part.tool_output = part.tool_output.substring (0, 4000) + "\n… (truncated)";
                                }
                                var error_obj = JsonUtil.object_member (state, "error");
                                if (error_obj != null && (part.tool_status == "" || part.tool_status == "error")) {
                                    part.tool_status = "error";
                                    var error_text = JsonUtil.string_member (error_obj, "message")
                                        ?? JsonUtil.string_member (error_obj, "text") ?? "";
                                    if (error_text != "") {
                                        part.tool_output = error_text;
                                    }
                                }
                            }
                            var part_time = JsonUtil.object_member (item, "time");
                            if (part_time != null) {
                                part.time_created = JsonUtil.int_member (part_time, "created");
                                part.time_completed = JsonUtil.int_member (part_time, "completed");
                            }
                            break;
                        default:
                            part.kind = PartKind.OTHER;
                            break;
                    }
                    message.parts.add (part);
                }
                /* Failed turns persist server-side with finish "error"
                 * and an error object (content may be empty or partial).
                 * Keep it as an error part so the failure renders from
                 * history, not just from the live event that has already
                 * vanished after a reopen. */
                var finish = JsonUtil.string_member (obj, "finish") ?? "";
                var error_obj = JsonUtil.object_member (obj, "error");
                if (finish == "error" || error_obj != null) {
                    var error_text = "";
                    if (error_obj != null) {
                        error_text = JsonUtil.string_member (error_obj, "message")
                            ?? JsonUtil.string_member (error_obj, "type") ?? "";
                    }
                    if (error_text == "") {
                        error_text = "Turn failed";
                    }
                    message.parts.add (new MessagePart () {
                        kind = PartKind.ERROR,
                        text = error_text
                    });
                }
                break;

            case "system":
            case "synthetic":
                message.role = MessageRole.SYSTEM;
                var system_text = JsonUtil.string_member (obj, "text")
                    ?? JsonUtil.string_member (obj, "description") ?? "";
                message.parts.add (new MessagePart () {
                    kind = PartKind.TEXT,
                    text = system_text
                });
                message.system_icon = "dialog-information";
                break;

            case "compaction":
                message.role = MessageRole.SYSTEM;
                message.system_status = JsonUtil.string_member (obj, "status") ?? "";
                message.system_reason = JsonUtil.string_member (obj, "reason") ?? "";
                message.system_summary = JsonUtil.string_member (obj, "summary") ?? "";
                message.system_icon = "preferences-system";
                var compaction_error = JsonUtil.object_member (obj, "error");
                if (compaction_error != null && message.system_status == "failed") {
                    var error_text = JsonUtil.string_member (compaction_error, "message") ?? "";
                    if (error_text != "") {
                        message.system_summary = error_text;
                    }
                }
                break;

            case "model-switched":
                message.role = MessageRole.SYSTEM;
                var model_obj = JsonUtil.object_member (obj, "model");
                var model_label = "model";
                var model_icon = "applications-science";
                if (model_obj != null) {
                    var model_id = JsonUtil.string_member (model_obj, "id") ?? "model";
                    var provider_id = JsonUtil.string_member (model_obj, "providerID") ?? "";
                    var variant = JsonUtil.string_member (model_obj, "variant") ?? "";
                    model_label = model_id;
                    if (variant != "") {
                        model_label += @" ($variant)";
                    }
                    model_icon = ModelIcons.icon_for (provider_id, model_id);
                }
                message.system_icon = model_icon;
                message.parts.add (new MessagePart () {
                    kind = PartKind.TEXT,
                    text = @"Switched model to $model_label"
                });
                break;

            case "agent-switched":
                message.role = MessageRole.SYSTEM;
                message.system_icon = "system-run";
                message.parts.add (new MessagePart () {
                    kind = PartKind.TEXT,
                    text = @"Switched agent to $(JsonUtil.string_member (obj, "agent") ?? "agent")"
                });
                break;

            case "location-switched":
                message.role = MessageRole.SYSTEM;
                message.system_icon = "folder-open";
                message.parts.add (new MessagePart () {
                    kind = PartKind.TEXT,
                    text = "Switched location"
                });
                break;

            case "idle":
                message.role = MessageRole.OTHER;
                break;

            default:
                if (obj.has_member ("text")) {
                    message.role = MessageRole.SYSTEM;
                    message.system_icon = "dialog-information";
                    message.parts.add (new MessagePart () {
                        kind = PartKind.TEXT,
                        text = JsonUtil.string_member (obj, "text") ?? ""
                    });
                } else {
                    message.role = MessageRole.OTHER;
                }
                break;
        }

        var time = JsonUtil.object_member (obj, "time");
        if (time != null) {
            message.created = JsonUtil.int_member (time, "created");
            message.completed = JsonUtil.int_member (time, "completed");
        }
        message.finish = JsonUtil.string_member (obj, "finish") ?? "";
        message.cost = JsonUtil.double_member (obj, "cost");
        var tokens = JsonUtil.object_member (obj, "tokens");
        if (tokens != null) {
            message.input_tokens = JsonUtil.int_member (tokens, "input");
            message.output_tokens = JsonUtil.int_member (tokens, "output");
            message.reasoning_tokens = JsonUtil.int_member (tokens, "reasoning");
            var cache = JsonUtil.object_member (tokens, "cache");
            if (cache != null) {
                message.cache_read = JsonUtil.int_member (cache, "read");
                message.cache_write = JsonUtil.int_member (cache, "write");
            }
        }

        return message;
    }

    public static Message user_message (string id, string text) {
        var message = new Message () { id = id, role = MessageRole.USER };
        message.parts.add (new MessagePart () {
            kind = PartKind.TEXT,
            text = text
        });
        return message;
    }
}

}
