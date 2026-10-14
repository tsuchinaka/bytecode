/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Centered system event: a horizontal rule broken in the middle
 * by a status indicator and a label, e.g.
 *
 *   ─────────────  ⠿ Compacting context…  ─────────────
 *
 * Used for events that are not part of the conversation itself:
 * compaction, model/agent switches, retries. Compaction streams
 * its summary into an expandable section while it runs.
 */

namespace OpenClient {

public class SystemDivider : Gtk.Box {
    public string divider_id { get; construct; }

    private BrailleSpinner spinner;
    private Gtk.Image status_icon;
    private Gtk.Stack indicator;
    private Gtk.Label title_label;
    private Gtk.Expander summary_expander;
    private Gtk.Label summary_label;
    private StringBuilder summary_buffer = new StringBuilder ();
    private string current_status = "done";

    public SystemDivider (string divider_id, string icon_name, string text, string status) {
        Object (
            divider_id: divider_id,
            orientation: Gtk.Orientation.VERTICAL,
            spacing: 2,
            halign: Gtk.Align.FILL,
            hexpand: true
        );
        add_css_class ("system-divider");

        var center = new Gtk.CenterBox ();

        var start_sep = new Gtk.Separator (Gtk.Orientation.HORIZONTAL) {
            hexpand = true,
            valign = Gtk.Align.CENTER,
            margin_end = 10
        };
        var end_sep = new Gtk.Separator (Gtk.Orientation.HORIZONTAL) {
            hexpand = true,
            valign = Gtk.Align.CENTER,
            margin_start = 10
        };

        var content = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            valign = Gtk.Align.CENTER
        };

        spinner = new BrailleSpinner ();

        status_icon = new Gtk.Image.from_icon_name (
            icon_name != "" ? icon_name : "dialog-information"
        ) {
            pixel_size = 14,
            valign = Gtk.Align.CENTER
        };

        indicator = new Gtk.Stack () {
            transition_type = Gtk.StackTransitionType.CROSSFADE
        };
        indicator.add_named (spinner, "running");
        indicator.add_named (status_icon, "static");

        title_label = new Gtk.Label (text) {
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 70
        };
        title_label.add_css_class ("system-divider-label");

        content.append (indicator);
        content.append (title_label);

        center.start_widget = start_sep;
        center.center_widget = content;
        center.end_widget = end_sep;
        append (center);

        summary_label = new Gtk.Label ("") {
            xalign = 0,
            yalign = 0,
            wrap = true,
            wrap_mode = Pango.WrapMode.WORD_CHAR,
            selectable = true,
            visible = false,
            margin_start = 24,
            margin_end = 24,
            margin_bottom = 6
        };
        summary_label.add_css_class ("reasoning-label");

        summary_expander = new Gtk.Expander ("Summary") {
            child = summary_label,
            visible = false,
            halign = Gtk.Align.CENTER,
            margin_top = 4
        };
        append (summary_expander);

        set_status (icon_name, text, status);
    }

    public void set_status (string icon_name, string text, string status) {
        current_status = status;
        if (text != "") {
            title_label.label = text;
        }
        if (icon_name != "") {
            status_icon.icon_name = icon_name;
        }

        if (status == "running") {
            spinner.start ();
            indicator.visible_child_name = "running";
        } else {
            spinner.stop ();
            indicator.visible_child_name = "static";
        }
    }

    /** Streams compaction output; expands automatically on first chunk. */
    public void append_summary (string delta) {
        if (!summary_expander.visible) {
            summary_expander.visible = true;
            summary_expander.expanded = true;
        }
        summary_buffer.append (delta);
        summary_label.label = summary_buffer.str;
        summary_label.visible = true;
    }

    public void set_summary (string text) {
        summary_buffer = new StringBuilder ();
        summary_buffer.append (text);
        summary_label.label = text;
        summary_label.visible = text != "";
        summary_expander.visible = text != "";
    }

    public void collapse_on_done () {
        if (current_status != "running" && summary_expander.visible) {
            summary_expander.expanded = false;
        }
    }
}

}
