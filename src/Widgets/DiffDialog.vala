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

    public DiffDialog (Gtk.Window parent, string session_title) {
        Object (
            transient_for: parent,
            modal: false,
            title: @"Changes · $session_title",
            default_width: 720,
            default_height: 520
        );

        var header = new Gtk.HeaderBar ();
        set_titlebar (header);

        spinner = new Gtk.Spinner () {
            spinning = true,
            halign = Gtk.Align.CENTER,
            valign = Gtk.Align.CENTER,
            width_request = 32,
            height_request = 32
        };

        list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.NONE
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

        var stat_label = new Gtk.Label (diff.summary) {
            valign = Gtk.Align.CENTER
        };
        stat_label.add_css_class ("diff-stat");
        header.append (stat_label);

        var expander = new Gtk.Expander ("Patch") {
            margin_start = 6,
            margin_end = 6,
            margin_bottom = 6
        };
        var patch_label = new Gtk.Label (diff.patch) {
            xalign = 0,
            selectable = true
        };
        patch_label.add_css_class (Granite.CssClass.MONOSPACE);
        patch_label.add_css_class ("diff-patch");
        expander.child = patch_label;

        box.append (header);
        box.append (expander);
        child = box;
    }
}

}
