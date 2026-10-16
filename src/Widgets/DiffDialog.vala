/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Session changes dialog: lists every file touched by the agent
 * with addition/deletion counts and the unified patch.
 */

namespace OpenClient {

public class DiffDialog : Gtk.Window {
    private Gtk.ListBox list;
    private Gtk.Spinner spinner;
    private Gtk.Stack stack;
    private Gtk.Label summary_label;

    public DiffDialog (Gtk.Window parent, string session_title) {
        Object (
            transient_for: parent,
            modal: false,
            title: @"Changes · $session_title",
            default_width: 760,
            default_height: 560
        );

        var header = new Gtk.HeaderBar ();
        set_titlebar (header);

        summary_label = new Gtk.Label ("") {
            valign = Gtk.Align.CENTER
        };
        summary_label.add_css_class ("caption");
        header.pack_start (summary_label);

        spinner = new Gtk.Spinner () {
            spinning = true,
            halign = Gtk.Align.CENTER,
            valign = Gtk.Align.CENTER,
            width_request = 32,
            height_request = 32
        };

        list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.NONE,
            show_separators = true
        };

        var scrolled = new Gtk.ScrolledWindow () {
            vexpand = true,
            hexpand = true,
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            child = list
        };

        stack = new Gtk.Stack ();
        stack.add_named (spinner, "loading");
        stack.add_named (scrolled, "diffs");
        stack.visible_child_name = "loading";

        child = stack;
    }

    public void set_diffs (Gee.ArrayList<FileDiff> diffs) {
        Gtk.Widget? child = list.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            list.remove (child);
            child = next;
        }

        var additions = 0;
        var deletions = 0;
        foreach (var diff in diffs) {
            additions += diff.additions;
            deletions += diff.deletions;
        }
        summary_label.label = diffs.size > 0
            ? @"$(diffs.size) files · +$additions −$deletions"
            : "";

        if (diffs.size == 0) {
            var placeholder = new Granite.Placeholder ("No changes yet") {
                description = "Files the agent creates or edits will appear here."
            };
            placeholder.icon = new ThemedIcon ("document-open");
            list.append (placeholder);
        }

        foreach (var diff in diffs) {
            list.append (new DiffRow (diff));
        }

        stack.visible_child_name = "diffs";
    }
}

public class DiffRow : Gtk.ListBoxRow {
    public DiffRow (FileDiff diff) {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

        var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10) {
            margin_top = 6,
            margin_bottom = 6,
            margin_start = 6,
            margin_end = 6
        };

        string icon_name = "text-x-generic";
        if (diff.status == "added") {
            icon_name = "list-add";
        } else if (diff.status == "deleted") {
            icon_name = "edit-delete";
        }

        header.append (new Gtk.Image.from_icon_name (icon_name) {
            pixel_size = 16,
            valign = Gtk.Align.CENTER
        });

        var path_label = new Gtk.Label (diff.path) {
            xalign = 0,
            hexpand = true,
            ellipsize = Pango.EllipsizeMode.MIDDLE
        };
        path_label.add_css_class ("heading");
        header.append (path_label);

        /* Additions and deletions are separate labels so each can carry
         * its own colour, the way diff tools show them. A side with
         * nothing on it is left out rather than shown as "+0". */
        if (diff.additions > 0) {
            var add_label = new Gtk.Label (@"+$(diff.additions)") {
                valign = Gtk.Align.CENTER
            };
            add_label.add_css_class ("diff-add");
            header.append (add_label);
        }

        if (diff.deletions > 0) {
            var del_label = new Gtk.Label (@"−$(diff.deletions)") {
                valign = Gtk.Align.CENTER
            };
            del_label.add_css_class ("diff-del");
            header.append (del_label);
        }

        var expander = new Gtk.Expander ("Diff") {
            margin_start = 6,
            margin_end = 6,
            margin_bottom = 6
        };
        expander.child = new DiffPatchView (diff.patch);

        box.append (header);
        box.append (expander);
        child = box;
    }
}

/** A unified patch, one line per row so each line can be coloured:
 *  additions green, deletions red, hunk headers accented and context
 *  dim. Lines are capped so a huge patch cannot flood the widget
 *  tree. */
public class DiffPatchView : Gtk.Box {
    private const int MAX_LINES = 3000;

    public DiffPatchView (string patch) {
        Object (
            orientation: Gtk.Orientation.VERTICAL,
            spacing: 0
        );
        add_css_class ("diff-patch");

        var lines = patch.split ("\n");
        var shown = 0;
        foreach (var raw in lines) {
            if (shown >= MAX_LINES) {
                break;
            }
            shown++;
            var label = new Gtk.Label (raw != "" ? raw : " ") {
                xalign = 0,
                selectable = true
            };
            label.add_css_class (Granite.CssClass.MONOSPACE);
            label.add_css_class ("diff-line");
            label.add_css_class (line_class (raw));
            append (label);
        }
        if (lines.length > MAX_LINES) {
            var more = new Gtk.Label (@"… $((int) lines.length - MAX_LINES) more lines") {
                xalign = 0
            };
            more.add_css_class (Granite.CssClass.DIM);
            more.add_css_class ("caption");
            append (more);
        }
    }

    private static string line_class (string line) {
        if (line.has_prefix ("+++") || line.has_prefix ("---")) {
            return "diff-file";
        }
        if (line.has_prefix ("@@")) {
            return "diff-hunk";
        }
        if (line.has_prefix ("+")) {
            return "diff-added";
        }
        if (line.has_prefix ("-")) {
            return "diff-removed";
        }
        if (line.has_prefix ("diff --git") || line.has_prefix ("index ")
            || line.has_prefix ("new file") || line.has_prefix ("deleted file")) {
            return "diff-meta";
        }
        return "diff-context";
    }
}

}
