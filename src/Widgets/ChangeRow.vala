/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * One changed file as a plain row: status icon, a spinner while it
 * is being written, the file name, and +N/−M counts with zero counts
 * left out. Used by the composer chip's popover and the session
 * inspector, which previously built the same row twice with only
 * density differing (compact carries the caption styling and tighter
 * spacing for the inspector list).
 */

namespace OpenClient {

public class ChangeRow : Gtk.Box {
    /** Icon for a file status: added, deleted, anything else. */
    public static string icon_for_status (string status) {
        return status == "added" ? "list-add"
            : (status == "deleted" ? "edit-delete" : "text-x-generic");
    }

    /** Spinner marking a file that is being written right now. */
    public static Gtk.Spinner editing_spinner () {
        return new Gtk.Spinner () {
            spinning = true,
            valign = Gtk.Align.CENTER,
            tooltip_text = "Being changed now"
        };
    }

    /** +N/−M count labels; a side with nothing on it is left out
     *  rather than shown as "+0". */
    public static void add_counts (Gtk.Box row, int additions, int deletions,
        bool caption_style = false) {
        if (additions > 0) {
            row.append (count_label (@"+$additions", "diff-add", caption_style));
        }
        if (deletions > 0) {
            row.append (count_label (@"−$deletions", "diff-del", caption_style));
        }
    }

    private static Gtk.Label count_label (string text, string css_class, bool caption_style) {
        var label = new Gtk.Label (text) {
            valign = Gtk.Align.CENTER
        };
        label.add_css_class (css_class);
        if (caption_style) {
            label.add_css_class ("caption");
        }
        return label;
    }

    /** Negative counts mean "unknown yet" and show nothing. */
    public ChangeRow (string path, int additions, int deletions,
        string status, bool editing, bool compact = false) {
        Object (
            orientation: Gtk.Orientation.HORIZONTAL,
            spacing: compact ? 6 : 8
        );
        tooltip_text = path;

        if (!compact) {
            margin_top = 4;
            margin_bottom = 4;
            margin_start = 8;
            margin_end = 8;
        }

        append (new Gtk.Image.from_icon_name (icon_for_status (status)) {
            pixel_size = compact ? 12 : 14,
            valign = Gtk.Align.CENTER
        });

        if (editing) {
            append (editing_spinner ());
        }

        var name_label = new Gtk.Label (GLib.Path.get_basename (path)) {
            xalign = 0,
            hexpand = true,
            ellipsize = Pango.EllipsizeMode.MIDDLE
        };
        if (!compact) {
            name_label.max_width_chars = 28;
        } else {
            name_label.add_css_class ("caption");
        }
        append (name_label);

        add_counts (this, additions, deletions, compact);
    }
}

}
