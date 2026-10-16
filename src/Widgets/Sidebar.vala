/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Session list sidebar. A Gtk.ListBox styled as a navigation
 * sidebar, with Granite.ListItem rows and a per-row context menu
 * for session management.
 */

namespace OpenClient {

public class Sidebar : Gtk.Box {
    public signal void session_selected (string session_id);
    public signal void session_delete_requested (string session_id);
    /** Bulk delete: the sessions ticked in selection mode. */
    public signal void sessions_delete_requested (Gee.ArrayList<string> session_ids);
    public signal void session_rename_requested (string session_id);
    public signal void session_diff_requested (string session_id);
    public signal void session_export_requested (string session_id);
    public signal void session_fork_requested (string session_id);
    public signal void session_compact_requested (string session_id);
    public signal void session_pin_requested (string session_id, bool pinned);
    public signal void session_archive_requested (string session_id, bool archived);

    /** Which slice of the session list is shown. */
    public enum FilterMode {
        ALL,
        PINNED,
        ARCHIVED
    }

    private Gtk.ListBox listbox;
    private Granite.HeaderLabel header_label;
    private Gtk.SearchEntry search_entry;
    private Gtk.ToggleButton filter_all_button;
    private Gtk.ToggleButton filter_pinned_button;
    private Gtk.ToggleButton filter_archived_button;
    private FilterMode filter_mode = FilterMode.ALL;
    private Gee.HashMap<string, SidebarRow> rows;
    private Gee.HashMap<string, string> row_statuses;
    /** Live activity text per session ("Running · Bash", …). Stored
     *  next to the status so a rebuilt row restores both. */
    private Gee.HashMap<string, string> row_activities;
    private Gee.HashMap<string, int> row_sections;
    private Gee.ArrayList<Session> all_sessions;
    private bool suppress_selection = false;
    /** Pending debounced rebuild from the search entry. */
    private uint search_source = 0;
    /* Bulk selection: a checkbox per row, an action bar under the list. */
    private Gtk.ToggleButton select_button;
    private Gtk.Revealer selection_bar;
    private Gtk.Label selection_label;
    private Gtk.Button select_all_button;
    private Gtk.Button delete_selected_button;
    private bool selecting = false;
    private Gee.HashSet<string> selected_ids;
    /** The row the app last marked active, so leaving selection mode can
     *  put the highlight back. */
    private string? highlighted_id = null;

    public Sidebar () {
        Object (orientation: Gtk.Orientation.VERTICAL, spacing: 0);
        selected_ids = new Gee.HashSet<string> ();
        rows = new Gee.HashMap<string, SidebarRow> ();
        row_statuses = new Gee.HashMap<string, string> ();
        row_activities = new Gee.HashMap<string, string> ();
        row_sections = new Gee.HashMap<string, int> ();
        all_sessions = new Gee.ArrayList<Session> ();

        header_label = new Granite.HeaderLabel ("Sessions") {
            hexpand = true
        };
        select_button = new Gtk.ToggleButton () {
            icon_name = "edit-select-all-symbolic",
            tooltip_text = "Select sessions to delete",
            valign = Gtk.Align.CENTER
        };
        select_button.add_css_class (Granite.STYLE_CLASS_FLAT);
        select_button.toggled.connect (() => set_selecting (select_button.active));
        var header_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            margin_start = 12,
            margin_end = 12,
            margin_top = 6,
            margin_bottom = 6
        };
        header_row.append (header_label);
        header_row.append (select_button);

        search_entry = new Gtk.SearchEntry () {
            placeholder_text = "Search sessions",
            margin_start = 12,
            margin_end = 12,
            margin_bottom = 6
        };
        search_entry.search_changed.connect (() => rebuild ());

        /* Filter slice: everything, pinned-first favourites, or the
         * archived drawer. One slice at a time, like a view switcher. */
        filter_all_button = new Gtk.ToggleButton.with_label ("All") {
            hexpand = true,
            active = true
        };
        filter_pinned_button = new Gtk.ToggleButton.with_label ("Pinned") {
            hexpand = true
        };
        filter_archived_button = new Gtk.ToggleButton.with_label ("Archived") {
            hexpand = true
        };
        filter_all_button.toggled.connect (() => set_filter (FilterMode.ALL, filter_all_button));
        filter_pinned_button.toggled.connect (() => set_filter (FilterMode.PINNED, filter_pinned_button));
        filter_archived_button.toggled.connect (() => set_filter (FilterMode.ARCHIVED, filter_archived_button));
        var filter_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) {
            margin_start = 12,
            margin_end = 12,
            margin_bottom = 6
        };
        filter_box.add_css_class ("linked");
        filter_box.append (filter_all_button);
        filter_box.append (filter_pinned_button);
        filter_box.append (filter_archived_button);

        listbox = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.SINGLE,
            activate_on_single_click = true
        };
        listbox.add_css_class ("navigation-sidebar");
        /* Section headers (Needs input / Working / Recent) are drawn by
         *  this function, not inserted as rows: header widgets sit above
         *  their row and never take row visuals (rounded cell
         *  background, hover, selection). */
        listbox.set_header_func ((row, before) => {
            if (filter_mode != FilterMode.ALL) {
                row.set_header (null);
                return;
            }
            if (!(row.get_child () is SidebarRow)) {
                row.set_header (null);
                return;
            }
            var section = section_of_id (((SidebarRow) row.get_child ()).session_id);
            int before_section = -1;
            if (before != null && before is Gtk.ListBoxRow
                && ((Gtk.ListBoxRow) before).get_child () is SidebarRow) {
                before_section = section_of_id (
                    ((SidebarRow) ((Gtk.ListBoxRow) before).get_child ()).session_id);
            }
            if (before == null || section != before_section) {
                row.set_header (new Granite.HeaderLabel (section_title (section)) {
                    margin_start = 12,
                    margin_end = 12,
                    margin_top = 6
                });
            } else {
                row.set_header (null);
            }
        });
        listbox.row_selected.connect ((row) => {
            if (suppress_selection || row == null || selecting) {
                return;
            }
            var item = row.get_child ();
            if (!(item is SidebarRow)) {
                return;
            }
            session_selected (((SidebarRow) item).session_id);
        });
        /* In selection mode a click ticks the row instead of opening it
         *  (the list is in SelectionMode.NONE then, so no row-selected). */
        listbox.row_activated.connect ((row) => {
            if (!selecting) {
                return;
            }
            var item = row.get_child ();
            if (item is SidebarRow) {
                var srow = (SidebarRow) item;
                /* A press that began on the checkbox already toggled it
                 *  (check_toggled): activating as well would untick it. */
                if (srow.consume_press_on_check ()) {
                    return;
                }
                set_row_ticked (srow.session_id);
            }
        });

        var scrolled = new Gtk.ScrolledWindow () {
            vexpand = true,
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            child = listbox
        };

        /* Bulk-action bar: shown only in selection mode. */
        selection_label = new Gtk.Label ("") {
            xalign = 0,
            hexpand = true
        };
        selection_label.add_css_class ("caption");
        select_all_button = new Gtk.Button.with_label ("All") {
            tooltip_text = "Select every session shown",
            valign = Gtk.Align.CENTER
        };
        select_all_button.add_css_class (Granite.STYLE_CLASS_FLAT);
        select_all_button.clicked.connect (() => toggle_select_all ());
        delete_selected_button = new Gtk.Button () {
            icon_name = "user-trash-symbolic",
            label = "Delete",
            tooltip_text = "Delete the selected sessions",
            valign = Gtk.Align.CENTER
        };
        delete_selected_button.add_css_class ("destructive-action");
        delete_selected_button.clicked.connect (() => request_delete_selected ());
        var selection_cancel = new Gtk.Button () {
            icon_name = "window-close-symbolic",
            tooltip_text = "Leave selection mode",
            valign = Gtk.Align.CENTER
        };
        selection_cancel.add_css_class (Granite.STYLE_CLASS_FLAT);
        selection_cancel.clicked.connect (() => {
            select_button.active = false;
        });
        var selection_toolbar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            margin_start = 12,
            margin_end = 12,
            margin_top = 6,
            margin_bottom = 6
        };
        selection_toolbar.append (selection_label);
        selection_toolbar.append (select_all_button);
        selection_toolbar.append (delete_selected_button);
        selection_toolbar.append (selection_cancel);
        selection_bar = new Gtk.Revealer () {
            transition_type = Gtk.RevealerTransitionType.SLIDE_UP,
            reveal_child = false,
            child = selection_toolbar
        };

        append (header_row);
        append (search_entry);
        append (filter_box);
        append (scrolled);
        append (selection_bar);

        /* Esc leaves selection mode (focus must be in the sidebar; the
         *  composer's own Esc handling runs first when it has focus). */
        var esc = new Gtk.EventControllerKey ();
        esc.key_pressed.connect ((keyval, keycode, state) => {
            if (keyval == Gdk.Key.Escape && selecting) {
                end_selection ();
                return true;
            }
            return false;
        });
        add_controller (esc);
    }

    /** Switches the visible slice; toggle buttons stay exclusive. */
    private void set_filter (FilterMode mode, Gtk.ToggleButton source) {
        if (source.active) {
            filter_mode = mode;
            foreach (var other in new Gtk.ToggleButton[] {
                filter_all_button, filter_pinned_button, filter_archived_button }) {
                if (other != source && other.active) {
                    other.active = false;
                }
            }
        } else if (filter_mode == mode) {
            /* The active slice can't be untoggled: exactly one slice
             * is always shown. */
            source.active = true;
            return;
        } else {
            return;
        }
        rebuild ();
    }

    public void set_sessions (Gee.ArrayList<Session> sessions) {
        all_sessions.clear ();
        all_sessions.add_all (sessions);
        /* Forget statuses of sessions the server dropped. */
        var known = new Gee.HashSet<string> ();
        foreach (var session in all_sessions) {
            known.add (session.id);
        }
        var stale_status = new Gee.ArrayList<string> ();
        foreach (var id in row_statuses.keys) {
            if (!known.contains (id)) {
                stale_status.add (id);
            }
        }
        foreach (var id in stale_status) {
            row_statuses.unset (id);
            row_activities.unset (id);
            row_sections.unset (id);
        }
        apply_diff ();
    }

    /** Updates one row's title in place (live rename): no rebuild,
     *  so scroll position, selection and focus survive. */
    public void update_title (string session_id, string title) {
        foreach (var session in all_sessions) {
            if (session.id == session_id) {
                session.title = title;
                break;
            }
        }
        var row = rows[session_id];
        if (row != null) {
            row.refresh (find_session (session_id));
        }
        update_header (rows.size);
    }

    private Session? find_session (string session_id) {
        foreach (var session in all_sessions) {
            if (session.id == session_id) {
                return session;
            }
        }
        return null;
    }

    /** Incremental diff: rows are added, removed or reordered in place
     *  instead of destroying the whole list. New CLI sessions slide in
     *  without flicker; selection and scroll position survive. */
    private void apply_diff () {
        var query = search_entry.text.down ().strip ();
        var wanted = new Gee.ArrayList<Session> ();
        var pinned_first = new Gee.ArrayList<Session> ();
        foreach (var session in all_sessions) {
            switch (filter_mode) {
                case FilterMode.PINNED:
                    if (!session.pinned || session.archived) {
                        continue;
                    }
                    break;
                case FilterMode.ARCHIVED:
                    if (!session.archived) {
                        continue;
                    }
                    break;
                default:
                    if (session.archived) {
                        continue;
                    }
                    break;
            }
            if (query != "") {
                var haystack = @"$(session.title) $(session.directory_name) $(session.model)".down ();
                if (!haystack.contains (query)) {
                    continue;
                }
            }
            /* Pinned sessions float above the rest in the All slice
             * (server order is otherwise preserved). */
            if (filter_mode == FilterMode.ALL && session.pinned) {
                pinned_first.add (session);
            } else {
                wanted.add (session);
            }
        }
        if (filter_mode == FilterMode.ALL) {
            /* Group the All slice into Needs input / Working / Recent
             * so live sessions surface structurally, not just by
             * spinner. Stable within each group (pinned first, then
             * server order). */
            var grouped = new Gee.ArrayList<Session> ();
            for (int section = 0; section <= 2; section++) {
                foreach (var session in pinned_first) {
                    if (section_of_session (session) == section) {
                        grouped.add (session);
                    }
                }
                foreach (var session in wanted) {
                    if (section_of_session (session) == section) {
                        grouped.add (session);
                    }
                }
            }
            wanted = grouped;
        } else if (pinned_first.size > 0) {
            var ordered = new Gee.ArrayList<Session> ();
            ordered.add_all (pinned_first);
            ordered.add_all (wanted);
            wanted = ordered;
        }

        var wanted_ids = new Gee.HashSet<string> ();
        foreach (var session in wanted) {
            wanted_ids.add (session.id);
        }

        suppress_selection = true;

        /* A re-sort can orphan the selected wrapper (moved rows are
         * re-wrapped): remember the session and re-highlight after. */
        string? selected_id = null;
        var selected_row = listbox.get_selected_row ();
        if (selected_row != null && ((Gtk.ListBoxRow) selected_row).get_child () is SidebarRow) {
            selected_id = ((SidebarRow) ((Gtk.ListBoxRow) selected_row).get_child ()).session_id;
        }

        /* Headers are drawn by the header func, not stored as rows, so
         *  the row diff below works on raw row indices directly. */

        /* 1. Drop rows that vanished or are now filtered out. */
        var drop = new Gee.ArrayList<string> ();
        foreach (var id in rows.keys) {
            if (!wanted_ids.contains (id)) {
                drop.add (id);
            }
        }
        foreach (var id in drop) {
            var row = rows[id];
            rows.unset (id);
            if (row != null) {
                var parent = row.get_parent ();
                if (parent != null) {
                    listbox.remove (parent);
                }
            }
        }
        /* Drop the empty-list placeholder if it is showing: placeholder
         * rows hold a bare Label, real rows hold a SidebarRow. */
        Gtk.Widget? child = listbox.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            if (child is Gtk.ListBoxRow) {
                var inner = ((Gtk.ListBoxRow) child).get_child ();
                if (inner is Gtk.Label) {
                    listbox.remove (child);
                }
            }
            child = next;
        }

        /* 2. Insert new rows and move reordered ones to server order.
         * Gtk.ListBox has no reorder API: moved rows are removed and
         * re-inserted. Untouched rows keep their widgets, so selection
         * and focus survive for everything that didn't move. */
        for (int i = 0; i < wanted.size; i++) {
            var session = wanted[i];
            var row = rows[session.id];
            if (row == null) {
                row = make_row (session);
                rows[session.id] = row;
                listbox.insert (row, i);
            } else {
                row.refresh (session);
                var parent = row.get_parent ();
                if (parent is Gtk.ListBoxRow && row_index (parent) != i) {
                    /* Detach first: the row is still parented to its old
                     * wrapper, and re-inserting it as-is trips
                     * gtk_list_box_row_set_child's parent assertion. */
                    ((Gtk.ListBoxRow) parent).set_child (null);
                    listbox.remove (parent);
                    listbox.insert (row, i);
                }
            }
            /* Fresh widgets start idle: restore the stored status and
             *  activity so a filter switch, search or re-sort never
             *  wipes a live session's indicator. */
            apply_stored_indicator (session.id);
        }

        suppress_selection = false;

        if (wanted.size == 0) {
            string empty_text = "No matching sessions";
            if (all_sessions.size == 0) {
                empty_text = "No sessions yet";
            } else if (filter_mode == FilterMode.PINNED) {
                empty_text = "No pinned sessions";
            } else if (filter_mode == FilterMode.ARCHIVED) {
                empty_text = "No archived sessions";
            }
            var empty = new Gtk.Label (empty_text) {
                margin_top = 18,
                margin_bottom = 18,
                xalign = 0.5f
            };
            empty.add_css_class (Granite.CssClass.DIM);
            empty.add_css_class ("caption");
            var placeholder = new Gtk.ListBoxRow () {
                child = empty,
                selectable = false,
                activatable = false
            };
            listbox.append (placeholder);
        }

        /* Section headers follow the new order (a status change may have
         *  moved a session across sections without adding rows). */
        listbox.invalidate_headers ();

        /* Selection mode survives a rebuild (search, filter, live rename):
         *  re-apply the checkbox and tick state to the rows on screen, and
         *  forget sessions that are no longer visible — deleting something
         *  the user cannot see would be a surprise. */
        if (selecting) {
            var stale = new Gee.ArrayList<string> ();
            foreach (var id in selected_ids) {
                if (!rows.has_key (id)) {
                    stale.add (id);
                }
            }
            foreach (var id in stale) {
                selected_ids.remove (id);
            }
            foreach (var id in rows.keys) {
                var row = rows[id];
                row.set_selecting (true);
                var ticked = selected_ids.contains (id);
                row.set_checked (ticked);
                if (ticked) {
                    apply_tick_style (id, true);
                }
            }
            update_selection_ui ();
        }

        if (selected_id != null && rows.has_key (selected_id)) {
            select (selected_id);
        }
        update_header (wanted.size);
    }

    /** Index of a ListBoxRow widget within the listbox, or -1. */
    private int row_index (Gtk.Widget listbox_row) {
        int index = 0;
        for (var c = listbox.get_first_child (); c != null; c = c.get_next_sibling ()) {
            if (c == listbox_row) {
                return index;
            }
            index++;
        }
        return -1;
    }

    private void update_header (int shown) {
        var query = search_entry.text.down ().strip ();
        string name = "Sessions";
        if (filter_mode == FilterMode.PINNED) {
            name = "Pinned";
        } else if (filter_mode == FilterMode.ARCHIVED) {
            name = "Archived";
        }
        header_label.label = query != ""
            ? @"$name ($(shown)/$(all_sessions.size))"
            : @"$name ($(shown))";
    }

    private void rebuild () {
        /* Typing re-sorts and re-labels the whole list: debounce so a
         *  burst of keystrokes (or the quick ones of a fast typist)
         *  produces one diff instead of one per key. */
        if (search_source != 0) {
            GLib.Source.remove (search_source);
        }
        search_source = GLib.Timeout.add (120, () => {
            search_source = 0;
            apply_diff ();
            return false;
        });
    }

    private SidebarRow make_row (Session session) {
        var row = new SidebarRow (session);
        row.check_toggled.connect ((session_id, checked) => {
            /* The checkbox was clicked directly: mirror the row state. */
            set_row_ticked_state (session_id, checked);
        });
        row.action_requested.connect ((action) => {
            switch (action) {
                case "rename":
                    session_rename_requested (session.id);
                    break;
                case "diff":
                    session_diff_requested (session.id);
                    break;
                case "export":
                    session_export_requested (session.id);
                    break;
                case "fork":
                    session_fork_requested (session.id);
                    break;
                case "compact":
                    session_compact_requested (session.id);
                    break;
                case "pin":
                    session_pin_requested (session.id, true);
                    break;
                case "unpin":
                    session_pin_requested (session.id, false);
                    break;
                case "archive":
                    session_archive_requested (session.id, true);
                    break;
                case "unarchive":
                    session_archive_requested (session.id, false);
                    break;
                case "delete":
                    session_delete_requested (session.id);
                    break;
                default:
                    break;
            }
        });
        return row;
    }

    public void select (string session_id) {
        highlighted_id = session_id;
        if (selecting) {
            /* Selection mode owns the highlight. */
            return;
        }
        var item = rows[session_id];
        if (item == null) {
            return;
        }
        var row = item.get_parent ();
        if (!(row is Gtk.ListBoxRow)) {
            return;
        }
        suppress_selection = true;
        listbox.select_row ((Gtk.ListBoxRow) row);
        suppress_selection = false;
    }

    /** Clears the current highlight without emitting session_selected.
     *  Used while composing a brand-new session, where no existing
     *  session should look active. */
    public void deselect () {
        highlighted_id = null;
        var row = listbox.get_selected_row ();
        if (row == null) {
            return;
        }
        suppress_selection = true;
        listbox.unselect_row (row);
        suppress_selection = false;
    }

    /* -- bulk selection ------------------------------------------------ */

    /** Enters or leaves selection mode: checkboxes in every row, an action
     *  bar under the list, and no session switching while it is on. */
    private void set_selecting (bool active) {
        if (selecting == active) {
            return;
        }
        selecting = active;
        selected_ids.clear ();
        listbox.selection_mode = active
            ? Gtk.SelectionMode.NONE
            : Gtk.SelectionMode.SINGLE;
        selection_bar.reveal_child = active;
        foreach (var row in rows.values) {
            row.set_selecting (active);
            var wrapper = row.get_parent ();
            if (wrapper is Gtk.ListBoxRow) {
                ((Gtk.ListBoxRow) wrapper).remove_css_class ("bulk-selected");
            }
        }
        if (active) {
            /* The row highlight belongs to the checkboxes now — but keep
             *  the id so leaving selection mode restores it (deselect
             *  clears it). */
            var keep = highlighted_id;
            deselect ();
            highlighted_id = keep;
        } else if (highlighted_id != null && rows.has_key (highlighted_id)) {
            select (highlighted_id);
        }
        update_selection_ui ();
    }

    /** Leaves selection mode (used after a bulk action was handed over). */
    public void end_selection () {
        if (selecting) {
            select_button.active = false;
        }
    }

    /** Flips one row's tick (row click in selection mode). */
    private void set_row_ticked (string session_id) {
        set_row_ticked_state (session_id, !selected_ids.contains (session_id));
    }

    /** Applies a tick state to one row and the selection bookkeeping. */
    private void set_row_ticked_state (string session_id, bool ticked) {
        if (ticked) {
            selected_ids.add (session_id);
        } else {
            selected_ids.remove (session_id);
        }
        apply_tick_style (session_id, ticked);
        update_selection_ui ();
    }

    /** Paints (or clears) the highlight of one row for its tick state. */
    private void apply_tick_style (string session_id, bool ticked) {
        var row = rows[session_id];
        if (row == null) {
            return;
        }
        row.set_checked (ticked);
        var wrapper = row.get_parent ();
        if (wrapper is Gtk.ListBoxRow) {
            if (ticked) {
                ((Gtk.ListBoxRow) wrapper).add_css_class ("bulk-selected");
            } else {
                ((Gtk.ListBoxRow) wrapper).remove_css_class ("bulk-selected");
            }
        }
    }

    /** Ticks every row currently on screen, or clears them all when the
     *  whole visible list is already ticked. */
    private void toggle_select_all () {
        var visible = new Gee.ArrayList<string> ();
        for (var c = listbox.get_first_child (); c != null; c = c.get_next_sibling ()) {
            if (!(c is Gtk.ListBoxRow)) {
                continue;
            }
            var inner = ((Gtk.ListBoxRow) c).get_child ();
            if (inner is SidebarRow) {
                visible.add (((SidebarRow) inner).session_id);
            }
        }
        var all_ticked = visible.size > 0;
        foreach (var id in visible) {
            if (!selected_ids.contains (id)) {
                all_ticked = false;
                break;
            }
        }
        foreach (var id in visible) {
            var row = rows[id];
            if (row == null) {
                continue;
            }
            if (all_ticked) {
                selected_ids.remove (id);
            } else {
                selected_ids.add (id);
            }
            row.set_checked (!all_ticked);
            var wrapper = row.get_parent ();
            if (wrapper is Gtk.ListBoxRow) {
                if (all_ticked) {
                    ((Gtk.ListBoxRow) wrapper).remove_css_class ("bulk-selected");
                } else {
                    ((Gtk.ListBoxRow) wrapper).add_css_class ("bulk-selected");
                }
            }
        }
        update_selection_ui ();
    }

    private void update_selection_ui () {
        selection_label.label = selected_ids.size == 1
            ? "1 session selected"
            : @"$(selected_ids.size) selected";
        delete_selected_button.sensitive = selected_ids.size > 0;
        select_all_button.label = all_visible_ticked () ? "None" : "All";
    }

    private bool all_visible_ticked () {
        var any = false;
        for (var c = listbox.get_first_child (); c != null; c = c.get_next_sibling ()) {
            if (!(c is Gtk.ListBoxRow)) {
                continue;
            }
            var inner = ((Gtk.ListBoxRow) c).get_child ();
            if (!(inner is SidebarRow)) {
                continue;
            }
            any = true;
            if (!selected_ids.contains (((SidebarRow) inner).session_id)) {
                return false;
            }
        }
        return any;
    }

    private void request_delete_selected () {
        if (selected_ids.size == 0) {
            return;
        }
        var ids = new Gee.ArrayList<string> ();
        foreach (var id in selected_ids) {
            ids.add (id);
        }
        debug ("Bulk delete requested for %d session(s)", ids.size);
        sessions_delete_requested (ids);
    }

    public void set_indicator (string session_id, string status, string activity) {
        /* Remember both, even while the row is filtered out or not yet
         *  built: apply_diff restores them onto fresh widgets. */
        row_statuses[session_id] = status;
        row_activities[session_id] = activity;
        var row = rows[session_id];
        if (row == null) {
            return;
        }
        apply_stored_indicator (session_id);
        var before = row_sections.has_key (session_id) ? row_sections[session_id] : -1;
        var after = section_of (status);
        row_sections[session_id] = after;
        if (before != after) {
            /* The session moved between Needs input / Working /
             * Recent: re-sort so it slides into its section. */
            apply_diff ();
        }
    }

    /** Paints a row from the stored status/activity maps. Called for
     *  live updates (via set_indicator) and for fresh widgets (via
     *  apply_diff), so both paths can never disagree. */
    private void apply_stored_indicator (string session_id) {
        var row = rows[session_id];
        if (row == null) {
            return;
        }
        var status = row_statuses.has_key (session_id) ? row_statuses[session_id] : "idle";
        var activity = row_activities.has_key (session_id) ? row_activities[session_id] : "";
        row.set_indicator (
            status == "running" || status == "compacting",
            status == "waiting" || status == "question",
            activity
        );
    }

    /** Status bucket for section grouping: 0 needs input, 1 working,
     *  2 everything settled. Unknown sessions read as settled. */
    private int section_of (string status) {
        if (status == "waiting" || status == "question") {
            return 0;
        }
        if (status == "running" || status == "compacting") {
            return 1;
        }
        return 2;
    }

    private int section_of_session (Session session) {
        return section_of (row_statuses.has_key (session.id) ? row_statuses[session.id] : "idle");
    }

    /** Section bucket for a session id (unknown sessions read as
     *  settled). Used by the header func, which only sees row widgets. */
    private int section_of_id (string session_id) {
        return section_of (row_statuses.has_key (session_id) ? row_statuses[session_id] : "idle");
    }

    private string section_title (int section) {
        switch (section) {
            case 0:
                return "Needs input";
            case 1:
                return "Working";
            default:
                return "Recent";
        }
    }
}

public class SidebarRow : Granite.ListItem {
    public signal void action_requested (string action);
    /** Emitted when the row's bulk-selection checkbox is toggled by the
     *  user (not when the sidebar sets it programmatically). */
    public signal void check_toggled (string session_id, bool checked);

    public string session_id { get; construct; }

    private Gtk.CheckButton check;
    /** True while set_checked() writes the checkbox, so its own toggled
     *  signal does not bounce back to the sidebar. */
    private bool updating_check = false;
    /** Whether the current press began on the checkbox. A press there
     *  toggles the button itself AND would also activate the row (a
     *  double toggle = a no-op click), so the sidebar reads this in its
     *  row_activated handler to skip the second toggle. Recorded by a
     *  capture-phase press controller below. */
    private bool press_on_check = false;

    private Gtk.Image status_dot;
    private Gtk.Spinner spinner;
    private Gtk.Image model_icon;
    private Gtk.Label title_label;
    private Gtk.Label subtitle_label;
    private Gtk.Image pin_icon;
    private GLib.Menu menu;
    private string base_title = "";
    private string subtitle_default = "";
    private bool last_spinning = false;
    private bool last_attention = false;
    private string last_activity = "";
    /* Last values refresh() applied, so repeated (no-op) refreshes are
     *  cheap: sentinel-initialised so the first refresh always applies. */
    private string last_title = "\x00sentinel";
    private string last_subtitle = "\x00sentinel";
    private string last_model = "\x00sentinel";
    private string? last_icon = null;
    private bool last_pinned = false;
    /** The pin/archive pair the context menu was last built for, or -1
     *  while it has never been built. Without the sentinel a plain
     *  (unpinned, unarchived) row — the common case — would look
     *  "unchanged" on the first refresh and never get a menu. */
    private int last_menu_state = -1;

    public SidebarRow (Session session) {
        Object (session_id: session.id);

        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
            margin_start = 4,
            margin_end = 4,
            margin_top = 3,
            margin_bottom = 3
        };

        /* Bulk-selection checkbox: only shown while the sidebar is in
         * selection mode (see Sidebar.set_selecting). */
        check = new Gtk.CheckButton () {
            valign = Gtk.Align.CENTER,
            visible = false,
            tooltip_text = "Select this session"
        };
        check.toggled.connect (() => {
            if (!updating_check) {
                check_toggled (session_id, check.active);
            }
        });
        box.append (check);

        /* Records where each press began (capture runs before the
         *  button and the listbox handle it). GTK 4.12 deprecated
         *  get_allocation, so the checkbox bounds are resolved against
         *  this box with compute_bounds instead. */
        var press = new Gtk.GestureClick ();
        press.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        press.pressed.connect ((n_press, x, y) => {
            Graphene.Rect bounds;
            press_on_check = check.compute_bounds (box, out bounds)
                && bounds.contains_point (
                    Graphene.Point () { x = (float) x, y = (float) y });
        });
        box.add_controller (press);

        /* Avatar: model icon inside a rounded tinted badge, with a
         * small running indicator overlaid on its corner. */
        model_icon = new Gtk.Image.from_icon_name (
            ModelIcons.icon_for (session.provider_id, session.model_id)
        ) {
            pixel_size = 16,
            valign = Gtk.Align.CENTER,
            tooltip_text = session.model != "" ? session.model : "No model"
        };
        model_icon.add_css_class ("model-icon");

        var avatar = new Gtk.Overlay () {
            valign = Gtk.Align.CENTER,
            halign = Gtk.Align.CENTER
        };
        var avatar_badge = new Gtk.CenterBox () {
            width_request = 28,
            height_request = 28,
            halign = Gtk.Align.CENTER,
            valign = Gtk.Align.CENTER
        };
        avatar_badge.add_css_class ("sidebar-avatar");
        avatar_badge.set_center_widget (model_icon);

        status_dot = new Gtk.Image.from_icon_name ("media-record-symbolic") {
            pixel_size = 8,
            visible = false,
            halign = Gtk.Align.END,
            valign = Gtk.Align.END
        };
        status_dot.add_css_class ("status-dot");

        /* Live activity spinner: spins over the avatar's corner while
         * the model is working (running / compacting). */
        spinner = new Gtk.Spinner () {
            visible = false,
            spinning = false,
            halign = Gtk.Align.END,
            valign = Gtk.Align.END
        };
        spinner.add_css_class ("session-spinner");

        avatar.set_child (avatar_badge);
        avatar.add_overlay (status_dot);
        avatar.add_overlay (spinner);

        var texts = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) {
            hexpand = true,
            valign = Gtk.Align.CENTER
        };

        var title_label = new Gtk.Label (session.title) {
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.END
        };
        title_label.add_css_class ("sidebar-title");
        this.title_label = title_label;

        subtitle_label = new Gtk.Label (session.directory_name) {
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.START
        };
        subtitle_label.add_css_class (Granite.CssClass.DIM);
        subtitle_label.add_css_class ("caption");

        texts.append (title_label);
        texts.append (subtitle_label);

        /* Pinned marker: symbolic state indicator at the row's end. */
        pin_icon = new Gtk.Image.from_icon_name ("view-pin-symbolic") {
            pixel_size = 12,
            valign = Gtk.Align.CENTER,
            visible = false,
            tooltip_text = "Pinned"
        };
        pin_icon.add_css_class (Granite.CssClass.DIM);

        box.append (avatar);
        box.append (texts);
        box.append (pin_icon);

        child = box;
        base_title = session.title;
        tooltip_text = session.title;

        /* Context menu is built by Granite.ListItem from a menu model
         * and shown on secondary click / long press / Menu key.
         * Pin/archive labels follow the row's state (rebuilt below). */
        menu = new GLib.Menu ();
        menu_model = menu;

        var group = new GLib.SimpleActionGroup ();
        add_row_action (group, "rename");
        add_row_action (group, "diff");
        add_row_action (group, "export");
        add_row_action (group, "fork");
        add_row_action (group, "compact");
        add_row_action (group, "pin");
        add_row_action (group, "unpin");
        add_row_action (group, "archive");
        add_row_action (group, "unarchive");
        add_row_action (group, "delete");
        insert_action_group ("row", group);

        refresh (session);
    }

    private void add_row_action (GLib.SimpleActionGroup group, string name) {
        var action = new GLib.SimpleAction (name, null);
        action.activate.connect (() => {
            action_requested (name);
        });
        group.add_action (action);
    }

    public void set_running (bool running) {
        set_indicator (running, false, "");
    }

    /** Shows or hides the bulk-selection checkbox (and clears it when
     *  leaving selection mode). */
    public void set_selecting (bool selecting) {
        check.visible = selecting;
        press_on_check = false;
        if (!selecting) {
            set_checked (false);
        }
    }

    /** Whether the current press began on the checkbox (consumed: each
     *  press is reported once, to the row_activated right after it). */
    public bool consume_press_on_check () {
        var was = press_on_check;
        press_on_check = false;
        return was;
    }

    /** Ticks the checkbox without emitting check_toggled. */
    public void set_checked (bool checked) {
        updating_check = true;
        check.active = checked;
        updating_check = false;
    }

    /** Live indicator over the model avatar: a spinner while the model
     *  works, an accent dot while it waits on the user, plus a tooltip
     *  naming the current activity ("Running · Bash", …). While live,
     *  the activity also replaces the directory subtitle — the video
     *  shows the working session's current job inline. */
    public void set_indicator (bool spinning, bool attention, string activity) {
        last_spinning = spinning;
        last_attention = attention;
        last_activity = activity;
        spinner.visible = spinning;
        spinner.spinning = spinning;
        status_dot.visible = !spinning && attention;
        if (activity != "") {
            tooltip_text = @"$base_title — $activity";
        } else if (spinning) {
            tooltip_text = @"$base_title — Running";
        } else if (attention) {
            tooltip_text = @"$base_title — Waiting";
        } else {
            tooltip_text = base_title;
        }
        apply_subtitle ();
    }

    /** Subtitle shows the live activity while the session needs input
     *  or is working, the directory otherwise. */
    private void apply_subtitle () {
        if ((last_spinning || last_attention) && last_activity != "") {
            subtitle_label.label = last_activity;
        } else {
            subtitle_label.label = subtitle_default;
        }
    }

    /** Refreshes title, subtitle, model icon, pin marker and menu
     *  labels in place. Every session event triggers a refresh of every
     *  visible row, so any field that is already correct is left alone:
     *  resolving an icon hits the icon theme and rebuilding the menu
     *  model invalidates the popover. */
    public void refresh (Session? session) {
        if (session == null) {
            return;
        }
        if (session.title != last_title) {
            base_title = session.title;
            title_label.label = session.title;
            last_title = session.title;
        }
        if (session.directory_name != last_subtitle) {
            subtitle_default = session.directory_name;
            last_subtitle = session.directory_name;
            apply_subtitle ();
        }
        var icon = ModelIcons.icon_for (session.provider_id, session.model_id);
        if (icon != last_icon) {
            model_icon.set_from_icon_name (icon);
            last_icon = icon;
        }
        var model_label = session.model != "" ? session.model : "No model";
        if (model_label != last_model) {
            model_icon.tooltip_text = model_label;
            last_model = model_label;
        }
        if (session.pinned != last_pinned) {
            pin_icon.visible = session.pinned;
            last_pinned = session.pinned;
        }
        /* Keep a live activity suffix across refreshes ("Title — Running"). */
        var dash = tooltip_text.index_of ("—");
        var next_tip = dash >= 0
            ? session.title + " " + tooltip_text.substring (dash)
            : session.title;
        if (next_tip != tooltip_text) {
            tooltip_text = next_tip;
        }
        /* Only the pin/archive pair changes the menu's labels. Bit 2
         *  marks the Export-item generation, so rows built before it
         *  rebuild once more instead of missing the item. */
        var menu_state = (session.pinned ? 1 : 0) | (session.archived ? 2 : 0) | 4;
        if (menu_state != last_menu_state) {
            last_menu_state = menu_state;
            menu.remove_all ();
            menu.append ("Rename…", "row.rename");
            menu.append ("View Changes", "row.diff");
            menu.append ("Export Session", "row.export");
            menu.append ("Fork Session", "row.fork");
            menu.append ("Compact Context", "row.compact");
            menu.append (session.pinned ? "Unpin" : "Pin", session.pinned ? "row.unpin" : "row.pin");
            menu.append (session.archived ? "Unarchive" : "Archive", session.archived ? "row.unarchive" : "row.archive");
            menu.append ("Delete Session", "row.delete");
        }
    }
}

}
