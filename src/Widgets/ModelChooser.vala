/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Model picker. Lists models from `GET /api/model` with search,
 * colored capability icons and provider brand logos, in a native
 * GTK popover sized to its content.
 */

namespace OpenClient {

public class ModelChooser : Gtk.Box {
    public signal void model_selected (string provider_id, string model_id, string variant);

    private Gtk.MenuButton button;
    private Gtk.Popover popover;
    private Gtk.ListBox list;
    private Gtk.SearchEntry search;
    private Gtk.Label button_label;
    private Gtk.Image button_icon;

    private Gee.ArrayList<ModelInfo> models;
    private string current_provider = "";
    private string current_model = "";

    public ModelChooser () {
        Object (orientation: Gtk.Orientation.HORIZONTAL);
        models = new Gee.ArrayList<ModelInfo> ();

        button = new Gtk.MenuButton ();
        button.add_css_class (Granite.STYLE_CLASS_FLAT);
        button.tooltip_text = "Choose model and thinking level";

        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            valign = Gtk.Align.CENTER
        };
        button_icon = new Gtk.Image.from_icon_name (ModelIcons.FALLBACK) {
            pixel_size = 16
        };
        button_label = new Gtk.Label ("Model") {
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 24
        };
        box.append (button_icon);
        box.append (button_label);
        button.child = box;

        var list_page = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        search = new Gtk.SearchEntry () {
            placeholder_text = "Search models",
            margin_top = 8,
            margin_bottom = 4,
            margin_start = 8,
            margin_end = 8
        };
        search.search_changed.connect (() => rebuild_model_list ());
        list_page.append (search);

        list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.NONE
        };
        list.add_css_class ("picker-list");
        list.row_activated.connect ((row) => {
            on_model_activated ((ModelRow) row);
        });

        var scrolled = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            /* Size to content, capped so the panel always fits the
             * space around its button — a fixed size would either clip
             * or leave dead space. propagate_natural_width keeps the
             * panel as wide as the widest row. */
            propagate_natural_width = true,
            propagate_natural_height = true,
            max_content_height = 300,
            child = list
        };
        list_page.append (scrolled);

        popover = new Gtk.Popover () {
            child = list_page
        };
        OpenClient.set_menu_popover (button, popover);

        button.notify["active"].connect (() => {
            if (button.active) {
                search.text = "";
                rebuild_model_list ();
                GLib.Idle.add (() => {
                    search.grab_focus ();
                    return false;
                });
            }
        });

        append (button);
    }

    public void set_models (Gee.ArrayList<ModelInfo> catalog) {
        models.clear ();
        models.add_all (catalog);
        update_button ();
    }

    public void set_current (string provider_id, string model_id) {
        current_provider = provider_id;
        current_model = model_id;
        update_button ();
    }

    private ModelInfo? find_current () {
        ModelInfo? id_match = null;
        foreach (var model in models) {
            if (model.provider_id == current_provider && model.id == current_model) {
                return model;
            }
            if (id_match == null && model.id == current_model) {
                id_match = model;
            }
        }
        return id_match;
    }

    private void update_button () {
        var info = find_current ();
        var display_name = current_model;
        if (info != null) {
            display_name = info.name;
            button_icon.icon_name = ModelIcons.icon_for (
                info.provider_id, info.id, info.name, info.family);
        } else {
            button_icon.icon_name = ModelIcons.icon_for (current_provider, current_model);
        }

        if (display_name == "") {
            display_name = "Model";
        }
        button_label.label = display_name;
    }

    private void rebuild_model_list () {
        Gtk.Widget? child = list.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            list.remove (child);
            child = next;
        }

        var filter = search.text.down ().strip ();
        foreach (var model in models) {
            if (filter != "") {
                var haystack = @"$(model.name) $(model.id) $(model.provider_id)".down ();
                if (!haystack.contains (filter)) {
                    continue;
                }
            }
            var row = new ModelRow (model);
            if (model.provider_id == current_provider && model.id == current_model) {
                row.mark_current ();
            }
            list.append (row);
        }
    }

    private void on_model_activated (ModelRow row) {
        button.popdown ();
        model_selected (row.model.provider_id, row.model.id, "");
    }
}

public class ModelRow : Gtk.ListBoxRow {
    public ModelInfo model;
    private Gtk.Box box;

    public ModelRow (ModelInfo model) {
        this.model = model;

        box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10) {
            margin_top = 3,
            margin_bottom = 3,
            margin_start = 10,
            margin_end = 10
        };

        var icon = new Gtk.Image.from_icon_name (
            ModelIcons.icon_for (model.provider_id, model.id, model.name, model.family)
        ) {
            pixel_size = 20,
            valign = Gtk.Align.CENTER
        };

        var texts = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) {
            hexpand = true,
            valign = Gtk.Align.CENTER
        };

        var name_label = new Gtk.Label (model.name) {
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 34
        };
        texts.append (name_label);

        var detail = model.provider_id;
        if (model.context_limit > 0) {
            detail += @" · $(model.context_limit / 1000)k ctx";
        }
        if (model.variants.size > 0) {
            detail += @" · $(model.variants.size) thinking levels";
        }
        var detail_label = new Gtk.Label (detail) {
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 34
        };
        detail_label.add_css_class (Granite.CssClass.DIM);
        detail_label.add_css_class ("caption");
        texts.append (detail_label);

        box.append (icon);
        box.append (texts);
        box.append (capabilities (model));
        child = box;
    }

    /** Small symbolic icons for what the model can take in / do:
     *  text, image (vision), audio, video, PDF and tool calling. */
    private static Gtk.Box capabilities (ModelInfo model) {
        var caps = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            valign = Gtk.Align.CENTER
        };

        var modalities = model.input_modalities;
        if (modalities.contains ("text")) {
            add_capability (caps, "text-x-generic", "Text input");
        }
        if (model.supports_vision || modalities.contains ("image")) {
            add_capability (caps, "image-x-generic", "Image input (vision)");
        }
        if (modalities.contains ("audio")) {
            add_capability (caps, "audio-x-generic", "Audio input");
        }
        if (modalities.contains ("video")) {
            add_capability (caps, "video-x-generic", "Video input");
        }
        if (modalities.contains ("pdf")) {
            add_capability (caps, "x-office-document", "PDF input");
        }
        if (model.supports_tools) {
            add_capability (caps, "system-run", "Tool calling");
        }
        return caps;
    }

    private static void add_capability (Gtk.Box box, string icon_name, string tooltip) {
        var icon = new Gtk.Image.from_icon_name (icon_name) {
            pixel_size = 14,
            valign = Gtk.Align.CENTER
        };
        icon.add_css_class ("model-cap");
        icon.tooltip_text = tooltip;
        box.append (icon);
    }

    public void mark_current () {
        var check = new Gtk.Image.from_icon_name ("object-select-symbolic") {
            valign = Gtk.Align.CENTER,
            tooltip_text = "Current"
        };
        box.append (check);
    }
}


}
