/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * A rich tool-call card: status icon (spinner while running,
 * check when done, warning on error), tool name, one-line
 * input summary and an expandable details section with the
 * full input, text output and image results.
 */

namespace OpenClient {

public enum ToolStatus {
    RUNNING,
    DONE,
    ERROR
}

public class ToolCard : Gtk.Box {
    public ToolStatus current_status { get; private set; default = ToolStatus.RUNNING; }
    private Gtk.Image status_icon;
    private Gtk.Spinner spinner;
    private Gtk.Stack status_stack;
    private Gtk.Label name_label;
    private Gtk.Label summary_label;
    private Gtk.Expander details_expander;
    private Gtk.Box details_box;
    private Gtk.Label input_label;
    private Gtk.Label output_label;
    private Gtk.FlowBox files_box;
    /** True once an input summary arrived. Until then the placeholder
     *  describes a running tool and must not outlive it. */
    private bool summary_seen = false;

    public ToolCard (string tool_name) {
        Object (
            orientation: Gtk.Orientation.VERTICAL,
            spacing: 0
        );
        add_css_class ("tool-card");

        var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
            margin_top = 6,
            margin_bottom = 6,
            margin_start = 8,
            margin_end = 8
        };

        spinner = new Gtk.Spinner () {
            spinning = true,
            valign = Gtk.Align.CENTER
        };
        spinner.add_css_class ("tool-spinner");

        status_icon = new Gtk.Image.from_icon_name ("process-working-symbolic") {
            pixel_size = 16,
            valign = Gtk.Align.CENTER
        };

        status_stack = new Gtk.Stack () {
            transition_type = Gtk.StackTransitionType.CROSSFADE
        };
        status_stack.add_named (spinner, "running");
        status_stack.add_named (status_icon, "done");
        status_stack.visible_child_name = "running";

        var texts = new Gtk.Box (Gtk.Orientation.VERTICAL, 1) {
            hexpand = true,
            valign = Gtk.Align.CENTER
        };
        name_label = new Gtk.Label (display_name (tool_name)) {
            xalign = 0
        };
        name_label.add_css_class ("tool-name");
        summary_label = new Gtk.Label ("Working…") {
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.END
        };
        summary_label.add_css_class ("tool-summary");
        summary_label.add_css_class (Granite.CssClass.MONOSPACE);
        texts.append (name_label);
        texts.append (summary_label);

        var icon = new Gtk.Image.from_icon_name (icon_for (tool_name)) {
            pixel_size = 16,
            valign = Gtk.Align.CENTER
        };
        icon.add_css_class (Granite.CssClass.DIM);

        header.append (status_stack);
        header.append (texts);
        header.append (icon);
        append (header);

        details_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6) {
            margin_start = 8,
            margin_end = 8,
            margin_bottom = 8
        };

        input_label = new Gtk.Label ("") {
            xalign = 0,
            wrap = true,
            wrap_mode = Pango.WrapMode.WORD_CHAR,
            selectable = true,
            visible = false
        };
        input_label.add_css_class ("tool-detail");
        input_label.add_css_class (Granite.CssClass.MONOSPACE);

        output_label = new Gtk.Label ("") {
            xalign = 0,
            wrap = true,
            wrap_mode = Pango.WrapMode.WORD_CHAR,
            selectable = true,
            visible = false
        };
        output_label.add_css_class ("tool-output");
        output_label.add_css_class (Granite.CssClass.MONOSPACE);

        files_box = new Gtk.FlowBox () {
            column_spacing = 8,
            row_spacing = 8,
            selection_mode = Gtk.SelectionMode.NONE,
            visible = false
        };

        details_box.append (input_label);
        details_box.append (output_label);
        details_box.append (files_box);

        details_expander = new Gtk.Expander ("Details") {
            child = details_box,
            visible = false,
            margin_start = 8,
            margin_end = 8,
            margin_bottom = 4
        };
        append (details_expander);

        tooltip_text = display_name (tool_name);
    }

    /** Display names are row titles, so AP title case. */
    public static string display_name (string tool) {
        switch (tool) {
            case "shell":
                return "Shell";
            case "read":
                return "Read File";
            case "write":
                return "Write File";
            case "edit":
                return "Edit File";
            case "webfetch":
                return "Fetch URL";
            case "websearch":
                return "Web Search";
            case "grep":
                return "Search";
            case "glob":
                return "Find Files";
            case "todo":
            case "todowrite":
                return "Todo";
            case "question":
                return "Question";
            case "task":
                return "Subagent";
            default:
                return tool.length > 0 ? tool.substring (0, 1).up () + tool.substring (1) : tool;
        }
    }

    public static string icon_for (string tool) {
        switch (tool) {
            case "shell":
                return "utilities-terminal";
            case "read":
            case "write":
            case "edit":
                return "text-x-generic";
            case "webfetch":
            case "websearch":
                return "applications-internet";
            case "grep":
            case "glob":
                return "system-search";
            case "todo":
            case "todowrite":
                return "appointment";
            case "question":
                return "dialog-question";
            case "task":
                return "system-users";
            default:
                return "application-x-executable";
        }
    }

    /** First non-empty string member out of `keys`, or null. */
    private static string? pick_string (Json.Object input, string[] keys) {
        foreach (var key in keys) {
            var value = JsonUtil.string_member (input, key);
            if (value != null && value.strip () != "") {
                return value.strip ();
            }
        }
        return null;
    }

    /** One-line human summary of a tool input object. */
    public static string summarize_input (string tool, Json.Object? input) {
        if (input == null) {
            return "";
        }

        string? raw = null;
        switch (tool) {
            case "read":
            case "write":
            case "edit":
                raw = pick_string (input, { "path", "filePath", "file", "uri" });
                break;
            case "shell":
                raw = pick_string (input, { "command" });
                break;
            case "webfetch":
                raw = pick_string (input, { "url" });
                break;
            case "websearch":
                raw = pick_string (input, { "query" });
                break;
            case "grep":
            case "glob":
                raw = pick_string (input, { "pattern", "path" });
                break;
            default: {
                foreach (var key in input.get_members ()) {
                    var node = input.get_member (key);
                    if (node.get_node_type () == Json.NodeType.VALUE &&
                        node.get_value_type () == typeof (string)) {
                        var value = node.get_string ();
                        if (value.strip () != "") {
                            raw = @"$key: $value";
                            break;
                        }
                    }
                }
                break;
            }
        }

        if (raw == null) {
            return "";
        }
        var first_line = raw.split ("\n")[0].strip ();
        if (first_line.length > 120) {
            return first_line.substring (0, 120) + "…";
        }
        return first_line;
    }

    public void set_input_summary (string summary) {
        if (summary == "") {
            return;
        }
        if (summary == last_input_summary) {
            return;
        }
        last_input_summary = summary;
        summary_seen = true;
        summary_label.label = summary;
        input_label.label = summary;
        input_label.visible = true;
        refresh_details ();
    }

    public void set_output (string text, Gee.ArrayList<FileAttachment>? files = null) {
        if (text.strip () != "") {
            var capped = text;
            if (capped.length > 4000) {
                capped = capped.substring (0, 4000) + "\n… (truncated)";
            }
            output_label.label = capped;
            output_label.visible = true;
        }
        if (files != null) {
            foreach (var file in files) {
                add_file (file);
            }
        }
        refresh_details ();
    }

    public void set_status (ToolStatus status, string? error_text = null) {
        current_status = status;
        switch (status) {
            case ToolStatus.RUNNING:
                status_stack.visible_child_name = "running";
                break;
            case ToolStatus.DONE:
                status_icon.icon_name = "process-completed";
                status_stack.visible_child_name = "done";
                /* A tool that never reported an input kept its
                 *  "Working…" placeholder: it would otherwise still read
                 *  as running now that it is finished. */
                if (!summary_seen) {
                    summary_label.visible = false;
                }
                break;
            case ToolStatus.ERROR:
                status_icon.icon_name = "dialog-warning";
                status_stack.visible_child_name = "done";
                if (!summary_seen) {
                    summary_label.visible = false;
                }
                if (error_text != null && error_text.strip () != "") {
                    output_label.label = error_text;
                    output_label.visible = true;
                    refresh_details ();
                }
                break;
        }
    }

    private void add_file (FileAttachment file) {
        if (!file.is_image) {
            return;
        }
        file.load_pixbuf_async.begin (200, (obj, res) => {
            var pixbuf = file.load_pixbuf_async.end (res);
            if (pixbuf == null) {
                return;
            }
            var picture = new Gtk.Picture.for_paintable (pixbuf_texture (pixbuf)) {
                tooltip_text = file.display_name
            };
            picture.add_css_class ("attachment-image");
            files_box.append (picture);
            files_box.visible = true;
            refresh_details ();
        });
    }

    /** Shows the details expander exactly when it has something in it.
     *  Recomputed rather than latched: files can arrive after the text
     *  and a card whose details emptied must lose the expander. */
    private void refresh_details () {
        var has_details = input_label.visible || output_label.visible || files_box.visible;
        details_expander.visible = has_details;
    }

    private string last_input_summary = "\x00sentinel";
}

}
