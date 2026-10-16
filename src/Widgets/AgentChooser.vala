/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Agent picker: Plan, Build and any other primary agent available
 * from `GET /api/agent`. This is the permissions mode of a session:
 * each agent carries its own permission ruleset. Native GTK popover
 * sized to its content.
 */

namespace OpenClient {

public class AgentChooser : Gtk.Box {
    public signal void agent_selected (string agent_id);

    private Gtk.MenuButton button;
    private Gtk.Popover popover;
    private Gtk.ListBox list;
    private Gtk.Label button_label;
    private Gee.ArrayList<AgentInfo> agents;
    private string current_id = "";

    public AgentChooser () {
        Object (orientation: Gtk.Orientation.HORIZONTAL);
        agents = new Gee.ArrayList<AgentInfo> ();

        button = new Gtk.MenuButton ();
        button.add_css_class (Granite.STYLE_CLASS_FLAT);
        button.tooltip_text = "Permissions mode (agent)";

        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            valign = Gtk.Align.CENTER
        };
        var icon = new Gtk.Image.from_icon_name ("system-run") {
            pixel_size = 16
        };
        button_label = new Gtk.Label ("Agent") {
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 16
        };
        box.append (icon);
        box.append (button_label);
        button.child = box;

        list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.NONE
        };
        list.add_css_class ("picker-list");
        list.row_activated.connect ((row) => {
            var agent_row = (AgentRow) row;
            button.popdown ();
            agent_selected (agent_row.agent.id);
        });

        var scrolled = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            propagate_natural_width = true,
            propagate_natural_height = true,
            max_content_height = 320,
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

    public void set_agents (Gee.ArrayList<AgentInfo> catalog) {
        agents.clear ();
        foreach (var agent in catalog) {
            if (agent.pickable) {
                agents.add (agent);
            }
        }
        update_button ();
    }

    public void set_current (string agent_id) {
        current_id = agent_id;
        update_button ();
    }

    private void update_button () {
        var display_name = current_id;
        foreach (var agent in agents) {
            if (agent.id == current_id) {
                display_name = agent.name;
                break;
            }
        }
        button_label.label = display_name != "" ? display_name : "Agent";
    }

    private void rebuild () {
        Gtk.Widget? child = list.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            list.remove (child);
            child = next;
        }

        foreach (var agent in agents) {
            var row = new AgentRow (agent);
            if (agent.id == current_id) {
                row.mark_current ();
            }
            list.append (row);
        }
    }
}

public class AgentRow : Gtk.ListBoxRow {
    public AgentInfo agent;
    private Gtk.Box box;

    public AgentRow (AgentInfo agent) {
        this.agent = agent;

        box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10) {
            margin_top = 4,
            margin_bottom = 4,
            margin_start = 10,
            margin_end = 10
        };

        var texts = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) {
            hexpand = true,
            valign = Gtk.Align.CENTER
        };

        var name_label = new Gtk.Label (agent.name) {
            xalign = 0
        };
        texts.append (name_label);

        if (agent.description != "") {
            var description_label = new Gtk.Label (agent.description) {
                xalign = 0,
                wrap = true,
                max_width_chars = 40,
                lines = 3,
                ellipsize = Pango.EllipsizeMode.END
            };
            description_label.add_css_class (Granite.CssClass.DIM);
            description_label.add_css_class ("caption");
            texts.append (description_label);
        }

        box.append (texts);
        child = box;
    }

    public void mark_current () {
        box.append (new Gtk.Image.from_icon_name ("object-select-symbolic") {
            valign = Gtk.Align.START
        });
    }
}

}
