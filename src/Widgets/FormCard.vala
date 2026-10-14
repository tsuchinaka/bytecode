/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Agent question card, docked above the composer. Renders the typed
 * fields of an OpenCode form (string, number, integer, boolean,
 * multiselect, external) with their constraints, honours conditional
 * `when` guards and hidden fields, validates before submitting, and
 * offers a Cancel that settles the form server-side.
 */

namespace OpenClient {

public class FormCard : Gtk.Box {
    public signal void submitted (string form_id, Json.Node answer);
    public signal void cancelled (string form_id);

    private FormInfo? form = null;
    private Gtk.Label title_label;
    private Gtk.Box fields_box;
    private Gtk.Label error_label;
    private Gtk.Button submit_button;
    private Gtk.Button cancel_button;

    private Gee.HashMap<string, Gtk.Widget> inputs;
    private Gee.HashMap<string, Gee.ArrayList<Gtk.CheckButton>> multi_checks;
    private Gee.HashMap<string, Gtk.Box> field_rows;
    private bool applying = false;

    public FormCard () {
        Object (
            orientation: Gtk.Orientation.VERTICAL,
            spacing: 8
        );
        margin_start = 12;
        margin_end = 12;
        margin_top = 6;
        add_css_class ("card");
        add_css_class ("form-card");

        inputs = new Gee.HashMap<string, Gtk.Widget> ();
        multi_checks = new Gee.HashMap<string, Gee.ArrayList<Gtk.CheckButton>> ();
        field_rows = new Gee.HashMap<string, Gtk.Box> ();

        var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        var icon = new Gtk.Image.from_icon_name ("dialog-question") {
            pixel_size = 16,
            valign = Gtk.Align.START,
            margin_top = 2
        };
        title_label = new Gtk.Label ("") {
            xalign = 0,
            wrap = true,
            hexpand = true
        };
        title_label.add_css_class ("heading");
        header.append (icon);
        header.append (title_label);
        append (header);

        fields_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        append (fields_box);

        error_label = new Gtk.Label ("") {
            xalign = 0,
            wrap = true,
            visible = false
        };
        error_label.add_css_class ("chat-error-label");
        append (error_label);

        var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
            halign = Gtk.Align.END,
            margin_top = 2
        };
        cancel_button = new Gtk.Button.with_label ("Cancel");
        cancel_button.add_css_class ("flat");
        cancel_button.clicked.connect (() => {
            if (form != null) {
                cancelled (form.id);
            }
        });
        submit_button = new Gtk.Button.with_label ("Submit");
        submit_button.add_css_class ("suggested-action");
        submit_button.clicked.connect (() => submit ());
        actions.append (cancel_button);
        actions.append (submit_button);
        append (actions);
    }

    public void set_form (FormInfo? form) {
        this.form = form;
        error_label.visible = false;

        Gtk.Widget? child = fields_box.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            fields_box.remove (child);
            child = next;
        }
        inputs.clear ();
        multi_checks.clear ();
        field_rows.clear ();

        if (form == null) {
            return;
        }

        title_label.label = form.title;
        foreach (var field in form.fields) {
            if (field.hidden) {
                continue;
            }
            var row = build_field (field);
            field_rows[field.key] = row;
            fields_box.append (row);
        }
        update_visibility ();
    }

    /* -- field building ---------------------------------------------- */

    private Gtk.Box build_field (FormField field) {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);

        var label = new Gtk.Label (field.title + (field.required ? " *" : "")) {
            xalign = 0
        };
        label.add_css_class ("heading");
        box.append (label);

        if (field.description != "") {
            var description = new Gtk.Label (field.description) {
                xalign = 0,
                wrap = true,
                max_width_chars = 60
            };
            description.add_css_class ("dim-label");
            description.add_css_class ("caption");
            box.append (description);
        }

        switch (field.field_type) {
            case "boolean": {
                var check = new Gtk.CheckButton.with_label ("Yes") {
                    active = field.default_bool
                };
                connect_changed (check);
                inputs[field.key] = check;
                box.append (check);
                break;
            }
            case "integer":
            case "number": {
                var lower = field.has_minimum ? field.minimum : -1e9;
                var upper = field.has_maximum ? field.maximum : 1e9;
                if (upper < lower) {
                    upper = lower;
                }
                var spin = new Gtk.SpinButton.with_range (lower, upper, 1.0) {
                    digits = field.field_type == "integer" ? 0 : 2,
                    value = field.has_default_number ? field.default_number : lower,
                    hexpand = false,
                    halign = Gtk.Align.START,
                    width_chars = 10
                };
                connect_changed (spin);
                inputs[field.key] = spin;
                box.append (spin);
                break;
            }
            case "multiselect": {
                var checks = new Gee.ArrayList<Gtk.CheckButton> ();
                foreach (var option in field.options) {
                    var check = new Gtk.CheckButton.with_label (option.label) {
                        tooltip_text = option.description
                    };
                    check.active = field.default_multi.contains (option.value);
                    check.set_data<string> ("option-value", option.value);
                    connect_changed (check);
                    checks.add (check);
                    box.append (check);
                }
                multi_checks[field.key] = checks;
                break;
            }
            case "external": {
                var link = new Gtk.LinkButton.with_label (
                    field.url != "" ? field.url : "Open link", "More info"
                ) {
                    halign = Gtk.Align.START
                };
                var done = new Gtk.CheckButton.with_label ("Done") {
                    margin_top = 4
                };
                connect_changed (done);
                inputs[field.key] = done;
                box.append (link);
                box.append (done);
                break;
            }
            default: {
                if (field.is_dropdown) {
                    var labels = new Gee.ArrayList<string> ();
                    foreach (var option in field.options) {
                        labels.add (option.label);
                    }
                    var dropdown = new Gtk.DropDown.from_strings (labels.to_array ()) {
                        selected = 0,
                        halign = Gtk.Align.START
                    };
                    dropdown.set_data<Gee.ArrayList<FormOption>> ("options", field.options);
                    connect_changed (dropdown);
                    inputs[field.key] = dropdown;
                    box.append (dropdown);
                    if (field.custom) {
                        var entry = new Gtk.Entry () {
                            placeholder_text = "Or type a custom answer…",
                            margin_top = 4
                        };
                        connect_changed (entry);
                        inputs[field.key + "__custom"] = entry;
                        box.append (entry);
                    }
                } else {
                    var entry = new Gtk.Entry () {
                        hexpand = true,
                        text = field.default_string,
                        placeholder_text = field.placeholder
                    };
                    if (field.max_length > 0) {
                        entry.max_length = field.max_length;
                    }
                    entry.activate.connect (() => submit ());
                    connect_changed (entry);
                    inputs[field.key] = entry;
                    box.append (entry);
                }
                break;
            }
        }

        return box;
    }

    private void connect_changed (Gtk.Widget widget) {
        if (widget is Gtk.Entry) {
            ((Gtk.Entry) widget).changed.connect (() => update_visibility ());
        } else if (widget is Gtk.CheckButton) {
            ((Gtk.CheckButton) widget).toggled.connect (() => update_visibility ());
        } else if (widget is Gtk.SpinButton) {
            ((Gtk.SpinButton) widget).value_changed.connect (() => update_visibility ());
        } else if (widget is Gtk.DropDown) {
            ((Gtk.DropDown) widget).notify["selected"].connect (() => update_visibility ());
        }
    }

    /* -- conditional visibility -------------------------------------- */

    private void update_visibility () {
        if (applying || form == null) {
            return;
        }
        applying = true;
        foreach (var field in form.fields) {
            var row = field_rows[field.key];
            if (row == null) {
                continue;
            }
            row.visible = field_visible (field);
        }
        applying = false;
    }

    private bool field_visible (FormField field) {
        foreach (var when in field.when) {
            if (!when.matches (current_value (when.key))) {
                return false;
            }
        }
        return true;
    }

    /** Current answer for @key as a plain string ("" when unset). */
    private string current_value (string key) {
        if (multi_checks.has_key (key)) {
            foreach (var check in multi_checks[key]) {
                if (check.active) {
                    return check.get_data<string> ("option-value") ?? "";
                }
            }
            return "";
        }
        var widget = inputs[key];
        if (widget == null) {
            return "";
        }
        if (widget is Gtk.Entry) {
            return ((Gtk.Entry) widget).text;
        }
        if (widget is Gtk.CheckButton) {
            return ((Gtk.CheckButton) widget).active ? "true" : "false";
        }
        if (widget is Gtk.SpinButton) {
            var spin = (Gtk.SpinButton) widget;
            return spin.digits == 0
                ? ((int64) spin.value).to_string ()
                : spin.value.to_string ();
        }
        if (widget is Gtk.DropDown) {
            return dropdown_value ((Gtk.DropDown) widget);
        }
        return "";
    }

    private string dropdown_value (Gtk.DropDown dropdown) {
        var options = dropdown.get_data<Gee.ArrayList<FormOption>> ("options");
        var index = (int) dropdown.selected;
        if (options == null || index < 0 || index >= options.size) {
            return "";
        }
        return options[index].value;
    }

    /* -- submission --------------------------------------------------- */

    private void submit () {
        if (form == null) {
            return;
        }

        var builder = new Json.Builder ();
        builder.begin_object ();
        foreach (var field in form.fields) {
            if (field.hidden) {
                continue;
            }
            var row = field_rows[field.key];
            if (row != null && !row.visible) {
                continue;
            }
            if (!field.is_answerable) {
                /* External steps acknowledge with the Done toggle. */
                builder.set_member_name (field.key);
                var done = inputs[field.key];
                builder.add_boolean_value (done is Gtk.CheckButton && ((Gtk.CheckButton) done).active);
                continue;
            }
            string problem;
            if (!validate (field, out problem)) {
                error_label.label = problem;
                error_label.visible = true;
                return;
            }
            error_label.visible = false;
            if (multi_checks.has_key (field.key)) {
                builder.set_member_name (field.key);
                builder.begin_array ();
                foreach (var check in multi_checks[field.key]) {
                    if (check.active) {
                        builder.add_string_value (check.get_data<string> ("option-value") ?? "");
                    }
                }
                builder.end_array ();
                continue;
            }
            if (field.is_dropdown) {
                var dropdown = inputs[field.key];
                var custom = inputs[field.key + "__custom"];
                var typed = "";
                if (custom is Gtk.Entry) {
                    typed = ((Gtk.Entry) custom).text.strip ();
                }
                builder.set_member_name (field.key);
                builder.add_string_value (typed != "" ? typed : dropdown_value ((Gtk.DropDown) dropdown));
                continue;
            }
            if (!inputs.has_key (field.key)) {
                continue;
            }
            var widget = inputs[field.key];
            builder.set_member_name (field.key);
            if (widget is Gtk.Entry) {
                builder.add_string_value (((Gtk.Entry) widget).text);
            } else if (widget is Gtk.CheckButton) {
                builder.add_boolean_value (((Gtk.CheckButton) widget).active);
            } else if (widget is Gtk.SpinButton) {
                var spin = (Gtk.SpinButton) widget;
                if (spin.digits == 0) {
                    builder.add_int_value ((int64) spin.value);
                } else {
                    builder.add_double_value (spin.value);
                }
            } else {
                builder.add_boolean_value (true);
            }
        }
        builder.end_object ();

        submitted (form.id, builder.get_root ());
    }

    /** Validates a field against the constraints the server sent. */
    private bool validate (FormField field, out string problem) {
        problem = "";
        if (multi_checks.has_key (field.key)) {
            var count = 0;
            foreach (var check in multi_checks[field.key]) {
                if (check.active) {
                    count++;
                }
            }
            if (field.required && count == 0) {
                problem = @"“$(field.title)” needs at least one selection.";
                return false;
            }
            if (field.min_items > 0 && count < field.min_items) {
                problem = @"“$(field.title)” needs at least $(field.min_items) selections.";
                return false;
            }
            if (field.max_items > 0 && count > field.max_items) {
                problem = @"“$(field.title)” allows at most $(field.max_items) selections.";
                return false;
            }
            return true;
        }
        if (field.is_dropdown) {
            var custom = inputs[field.key + "__custom"];
            var typed = "";
            if (custom is Gtk.Entry) {
                typed = ((Gtk.Entry) custom).text.strip ();
            }
            if (field.required && typed == "" && dropdown_value ((Gtk.DropDown) inputs[field.key]) == "") {
                problem = @"“$(field.title)” is required.";
                return false;
            }
            return true;
        }
        var widget = inputs[field.key];
        if (widget == null) {
            return true;
        }
        if (widget is Gtk.Entry) {
            var text = ((Gtk.Entry) widget).text;
            if (field.required && text.strip () == "") {
                problem = @"“$(field.title)” is required.";
                return false;
            }
            if (field.min_length > 0 && text.length < field.min_length) {
                problem = @"“$(field.title)” needs at least $(field.min_length) characters.";
                return false;
            }
            if (field.max_length > 0 && text.length > field.max_length) {
                problem = @"“$(field.title)” allows at most $(field.max_length) characters.";
                return false;
            }
            if (field.format == "email" && text != "" && !text.contains ("@")) {
                problem = @"“$(field.title)” must be an email address.";
                return false;
            }
            if (field.format == "uri" && text != "" && !text.contains ("://")) {
                problem = @"“$(field.title)” must be a URL.";
                return false;
            }
        } else if (widget is Gtk.SpinButton) {
            var value = ((Gtk.SpinButton) widget).value;
            if (field.has_minimum && value < field.minimum) {
                problem = @"“$(field.title)” must be at least $(field.minimum).";
                return false;
            }
            if (field.has_maximum && value > field.maximum) {
                problem = @"“$(field.title)” must be at most $(field.maximum).";
                return false;
            }
        }
        return true;
    }
}

}
