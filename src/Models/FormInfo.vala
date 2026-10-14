/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Agent question form, mirroring the OpenCode v2 `Form.Detail` shape.
 * A form is one blocking request with several typed fields; the
 * reply carries one answer object for all of them.
 */

namespace OpenClient {

/** One `when` guard: the field is shown only if the referenced
 *  field's current answer satisfies `op` against `value`. */
public class FormWhen : GLib.Object {
    public string key { get; set; default = ""; }
    public string op { get; set; default = "eq"; }
    public string value_string { get; set; default = ""; }
    public double value_number { get; set; default = 0.0; }
    public bool value_bool { get; set; default = false; }
    /* 0 = string, 1 = number, 2 = boolean */
    public int value_kind { get; set; default = 0; }

    public static FormWhen? from_json (Json.Object obj) {
        var key = JsonUtil.string_member (obj, "key");
        if (key == null) {
            return null;
        }
        var when = new FormWhen () {
            key = key,
            op = JsonUtil.string_member (obj, "op") ?? "eq"
        };
        var node = obj.has_member ("value") ? obj.get_member ("value") : null;
        if (node != null && node.get_node_type () == Json.NodeType.VALUE) {
            var vt = node.get_value_type ();
            if (vt == typeof (bool)) {
                when.value_kind = 2;
                when.value_bool = node.get_boolean ();
            } else if (vt == typeof (double)) {
                when.value_kind = 1;
                when.value_number = node.get_double ();
            } else if (vt == typeof (int64)) {
                when.value_kind = 1;
                when.value_number = (double) node.get_int ();
            } else if (vt == typeof (string)) {
                when.value_kind = 0;
                when.value_string = node.get_string ();
            }
        }
        return when;
    }

    /** True when @current (the referenced field's answer) passes. */
    public bool matches (string current) {
        var equal = false;
        switch (value_kind) {
            case 2:
                equal = (current == (value_bool ? "true" : "false"));
                break;
            case 1:
                var parsed = double.parse (current);
                equal = (parsed == value_number);
                break;
            default:
                equal = (current == value_string);
                break;
        }
        return op == "neq" ? !equal : equal;
    }
}

public class FormField : GLib.Object {
    public string key { get; set; default = ""; }
    public string title { get; set; default = ""; }
    public string description { get; set; default = ""; }
    public string field_type { get; set; default = "string"; }
    public bool required { get; set; default = false; }
    public bool hidden { get; set; default = false; }
    public string default_string { get; set; default = ""; }
    public bool default_bool { get; set; default = false; }
    public double default_number { get; set; default = 0.0; }
    public bool has_default_number { get; set; default = false; }
    public string placeholder { get; set; default = ""; }
    public string format { get; set; default = ""; }
    public int min_length { get; set; default = 0; }
    public int max_length { get; set; default = 0; }
    public string pattern { get; set; default = ""; }
    public double minimum { get; set; default = 0.0; }
    public double maximum { get; set; default = 0.0; }
    public bool has_minimum { get; set; default = false; }
    public bool has_maximum { get; set; default = false; }
    public int min_items { get; set; default = 0; }
    public int max_items { get; set; default = 0; }
    public bool custom { get; set; default = false; }
    /** External fields carry a URL instead of options. */
    public string url { get; set; default = ""; }
    public Gee.ArrayList<FormOption> options;
    public Gee.ArrayList<FormWhen> when;
    public Gee.ArrayList<string> default_multi;

    public FormField () {
        options = new Gee.ArrayList<FormOption> ();
        when = new Gee.ArrayList<FormWhen> ();
        default_multi = new Gee.ArrayList<string> ();
    }

    public static FormField? from_json (Json.Object obj) {
        var key = JsonUtil.string_member (obj, "key");
        var field_type = JsonUtil.string_member (obj, "type");
        if (key == null || field_type == null) {
            return null;
        }
        var field = new FormField () {
            key = key,
            field_type = field_type
        };
        field.title = JsonUtil.string_member (obj, "title") ?? key;
        field.description = JsonUtil.string_member (obj, "description") ?? "";
        field.required = JsonUtil.bool_member (obj, "required", false);
        field.hidden = JsonUtil.bool_member (obj, "hidden", false);
        field.placeholder = JsonUtil.string_member (obj, "placeholder") ?? "";
        field.format = JsonUtil.string_member (obj, "format") ?? "";
        field.pattern = JsonUtil.string_member (obj, "pattern") ?? "";
        field.url = JsonUtil.string_member (obj, "url") ?? "";
        field.custom = JsonUtil.bool_member (obj, "custom", false);
        field.min_length = (int) JsonUtil.int_member (obj, "minLength", 0);
        field.max_length = (int) JsonUtil.int_member (obj, "maxLength", 0);
        field.min_items = (int) JsonUtil.int_member (obj, "minItems", 0);
        field.max_items = (int) JsonUtil.int_member (obj, "maxItems", 0);
        if (obj.has_member ("minimum")) {
            field.has_minimum = true;
            field.minimum = JsonUtil.double_member (obj, "minimum", 0.0);
        }
        if (obj.has_member ("maximum")) {
            field.has_maximum = true;
            field.maximum = JsonUtil.double_member (obj, "maximum", 0.0);
        }
        foreach (var option_obj in JsonUtil.array_objects (obj, "options")) {
            var value = JsonUtil.string_member (option_obj, "value");
            if (value == null) {
                continue;
            }
            field.options.add (new FormOption () {
                value = value,
                label = JsonUtil.string_member (option_obj, "label") ?? value,
                description = JsonUtil.string_member (option_obj, "description") ?? ""
            });
        }
        foreach (var when_obj in JsonUtil.array_objects (obj, "when")) {
            var when = FormWhen.from_json (when_obj);
            if (when != null) {
                field.when.add (when);
            }
        }
        var default_node = obj.has_member ("default") ? obj.get_member ("default") : null;
        if (default_node != null && default_node.get_node_type () == Json.NodeType.VALUE) {
            var vt = default_node.get_value_type ();
            if (vt == typeof (string)) {
                field.default_string = default_node.get_string ();
            } else if (vt == typeof (bool)) {
                field.default_bool = default_node.get_boolean ();
            } else if (vt == typeof (double)) {
                field.default_number = default_node.get_double ();
                field.has_default_number = true;
            } else if (vt == typeof (int64)) {
                field.default_number = (double) default_node.get_int ();
                field.has_default_number = true;
            }
        } else if (default_node != null && default_node.get_node_type () == Json.NodeType.ARRAY) {
            foreach (var node in JsonUtil.node_array (default_node)) {
                if (node.get_node_type () == Json.NodeType.VALUE
                    && node.get_value_type () == typeof (string)) {
                    field.default_multi.add (node.get_string ());
                }
            }
        }
        return field;
    }

    public bool is_answerable {
        get {
            return field_type != "external";
        }
    }

    /** A string field with options behaves as a dropdown. */
    public bool is_dropdown {
        get {
            return field_type == "string" && options.size > 0;
        }
    }
}

public class FormOption : GLib.Object {
    public string value { get; set; default = ""; }
    public string label { get; set; default = ""; }
    public string description { get; set; default = ""; }
}

public class FormInfo : GLib.Object {
    public string id { get; set; default = ""; }
    public string session_id { get; set; default = ""; }
    public string title { get; set; default = ""; }
    public Gee.ArrayList<FormField> fields;

    public FormInfo () {
        fields = new Gee.ArrayList<FormField> ();
    }

    public static FormInfo? from_json (Json.Object obj) {
        var id = JsonUtil.string_member (obj, "id");
        if (id == null) {
            return null;
        }
        var form = new FormInfo () { id = id };
        form.session_id = JsonUtil.string_member (obj, "sessionID") ?? "";
        form.title = JsonUtil.string_member (obj, "title") ?? "Question";
        foreach (var field_obj in JsonUtil.array_objects (obj, "fields")) {
            var field = FormField.from_json (field_obj);
            if (field != null) {
                form.fields.add (field);
            }
        }
        return form;
    }
}

public class FileDiff : GLib.Object {
    public string path { get; set; default = ""; }
    public string patch { get; set; default = ""; }
    public int additions { get; set; default = 0; }
    public int deletions { get; set; default = 0; }
    public string status { get; set; default = ""; }

    public static FileDiff? from_json (Json.Object obj) {
        var path = JsonUtil.string_member (obj, "file");
        if (path == null) {
            return null;
        }
        return new FileDiff () {
            path = path,
            patch = JsonUtil.string_member (obj, "patch") ?? "",
            additions = (int) JsonUtil.int_member (obj, "additions"),
            deletions = (int) JsonUtil.int_member (obj, "deletions"),
            status = JsonUtil.string_member (obj, "status") ?? ""
        };
    }

    public string summary {
        owned get {
            return @"+$additions/−$deletions";
        }
    }
}

}
