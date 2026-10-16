/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Small widget helpers shared across the conversation UI.
 */

namespace OpenClient {

/** Removes every child from a box. */
internal void clear_box (Gtk.Box box) {
    Gtk.Widget? child = box.get_first_child ();
    while (child != null) {
        var next = child.get_next_sibling ();
        box.remove (child);
        child = next;
    }
}

/** Removes every row from a list box. */
internal void clear_list (Gtk.ListBox list) {
    Gtk.Widget? child = list.get_first_child ();
    while (child != null) {
        var next = child.get_next_sibling ();
        list.remove (child);
        child = next;
    }
}

/** Removes every chip from a flow box. */
internal void clear_flow (Gtk.FlowBox flow) {
    Gtk.Widget? child = flow.get_first_child ();
    while (child != null) {
        var next = child.get_next_sibling ();
        flow.remove (child);
        child = next;
    }
}

}
