/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Thinking-level picker, kept separate from the model picker.
 * Shows the variants of the active model (none/low/…/max) and
 * applies the chosen level with the current model. Hidden when
 * the model exposes no variants. Native GTK popover.
 */

namespace OpenClient {

public class VariantChooser : Gtk.Box {
    public signal void variant_selected (string variant);

    private Gtk.MenuButton button;
    private Gtk.Popover popover;
    private Gtk.ListBox list;
    private Gtk.Label button_label;
    private Gee.ArrayList<string> variants;
    private string current = "";

    public VariantChooser () {
        Object (orientation: Gtk.Orientation.HORIZONTAL);
        variants = new Gee.ArrayList<string> ();

        button = new Gtk.MenuButton ();
        button.add_css_class (Granite.STYLE_CLASS_FLAT);
        button.tooltip_text = "Thinking level";

        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            valign = Gtk.Align.CENTER
        };
        var icon = new Gtk.Image.from_icon_name ("applications-science") {
            pixel_size = 14,
            valign = Gtk.Align.CENTER
        };
        button_label = new Gtk.Label ("Level") {
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 12
        };
        box.append (icon);
        box.append (button_label);
        button.child = box;

        list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.NONE
        };
        list.add_css_class ("picker-list");
        list.row_activated.connect ((row) => {
            var variant_row = (VariantRow) row;
            button.popdown ();
            variant_selected (variant_row.variant_id);
        });

        var scrolled = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            propagate_natural_width = true,
            propagate_natural_height = true,
            max_content_height = 300,
            child = list
        };
        popover = new Gtk.Popover () {
            child = scrolled
        };
        OpenClient.set_menu_popover (button, popover);

        button.notify["active"].connect (() => {
            if (button.active) {
                rebuild ();
            }
        });

        append (button);
    }

    public void set_variants (Gee.ArrayList<string> variants, string current) {
        this.variants = new Gee.ArrayList<string> ();
        this.variants.add_all (variants);
        this.current = current;

        visible = variants.size > 0;
        update_button ();
    }

    private void update_button () {
        button_label.label = current != "" ? VariantRow.display_name (current) : "Default";
    }

    private void rebuild () {
        Gtk.Widget? child = list.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            list.remove (child);
            child = next;
        }

        foreach (var variant in variants) {
            var row = new VariantRow (variant);
            if (variant == current) {
                row.mark_current ();
            }
            list.append (row);
        }
    }
}

public class VariantRow : Gtk.ListBoxRow {
    public string variant_id { get; construct; }
    private Gtk.Box box;

    public VariantRow (string variant_id) {
        Object (variant_id: variant_id);

        box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10) {
            margin_top = 3,
            margin_bottom = 3,
            margin_start = 10,
            margin_end = 10
        };

        var label = new Gtk.Label (display_name (variant_id)) {
            xalign = 0,
            hexpand = true
        };
        box.append (label);

        if (variant_id == "none") {
            var hint = new Gtk.Label ("thinking disabled") {
                xalign = 1
            };
            hint.add_css_class (Granite.CssClass.DIM);
            hint.add_css_class ("caption");
            box.append (hint);
        }

        child = box;
    }

    public void mark_current () {
        box.append (new Gtk.Image.from_icon_name ("object-select-symbolic") {
            valign = Gtk.Align.CENTER
        });
    }

    public static string display_name (string variant_id) {
        switch (variant_id) {
            case "none":
                return "None";
            case "low":
                return "Low";
            case "medium":
                return "Medium";
            case "high":
                return "High";
            case "xhigh":
                return "Extra High";
            case "max":
                return "Max";
            default:
                return variant_id;
        }
    }
}

}
