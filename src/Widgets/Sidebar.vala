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
    public signal void session_rename_requested (string session_id);
    public signal void session_diff_requested (string session_id);
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
    private Gee.HashMap<string, int> row_sections;
    private Gee.ArrayList<Session> all_sessions;
    private bool suppress_selection = false;

    public Sidebar () {
        Object (orientation: Gtk.Orientation.VERTICAL, spacing: 0);
        rows = new Gee.HashMap<string, SidebarRow> ();
        row_statuses = new Gee.HashMap<string, string> ();
        row_sections = new Gee.HashMap<string, int> ();
        all_sessions = new Gee.ArrayList<Session> ();

        header_label = new Granite.HeaderLabel ("Sessions") {
            margin_start = 12,
            margin_end = 12,
            margin_top = 6,
            margin_bottom = 6
        };

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
        listbox.row_selected.connect ((row) => {
            if (suppress_selection || row == null) {
                return;
            }
            var item = row.get_child ();
            if (!(item is SidebarRow)) {
                return;
            }
            session_selected (((SidebarRow) item).session_id);
        });

        var scrolled = new Gtk.ScrolledWindow () {
            vexpand = true,
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            child = listbox
        };

        append (header_label);
        append (search_entry);
        append (filter_box);
        append (scrolled);
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

        /* 0. Headers occupy positions too: strip them so the row diff
         *  below works on raw row indices (re-placed at the end). */
        clear_section_headers ();

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
            empty.add_css_class ("dim-label");
            empty.add_css_class ("caption");
            var placeholder = new Gtk.ListBoxRow () {
                child = empty,
                selectable = false,
                activatable = false
            };
            listbox.append (placeholder);
        }

        place_section_headers ();
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
        apply_diff ();
    }

    private SidebarRow make_row (Session session) {
        var row = new SidebarRow (session);
        row.action_requested.connect ((action) => {
            switch (action) {
                case "rename":
                    session_rename_requested (session.id);
                    break;
                case "diff":
                    session_diff_requested (session.id);
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
        var row = listbox.get_selected_row ();
        if (row == null) {
            return;
        }
        suppress_selection = true;
        listbox.unselect_row (row);
        suppress_selection = false;
    }

    public void set_indicator (string session_id, string status, string activity) {
        var row = rows[session_id];
        if (row == null) {
            /* The row may be filtered out (or not yet built): still
             * remember the status so sections place it correctly. */
            row_statuses[session_id] = status;
            return;
        }
        row.set_indicator (
            status == "running" || status == "compacting",
            status == "waiting" || status == "question",
            activity
        );
        var before = row_sections.has_key (session_id) ? row_sections[session_id] : -1;
        row_statuses[session_id] = status;
        var after = section_of (status);
        row_sections[session_id] = after;
        if (before != after) {
            /* The session moved between Needs input / Working /
             * Recent: re-sort so it slides into its section. */
            apply_diff ();
        }
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

    /** Removes section headers so the row diff below works on raw
     *  row indices (headers occupy positions too). */
    private void clear_section_headers () {
        Gtk.Widget? hdr = listbox.get_first_child ();
        while (hdr != null) {
            var next = hdr.get_next_sibling ();
            if (hdr is Gtk.ListBoxRow && ((Gtk.ListBoxRow) hdr).get_child () is Granite.HeaderLabel) {
                listbox.remove (hdr);
            }
            hdr = next;
        }
    }

    /** (Re)places the Needs input / Working / Recent headers over the
     *  current row order. Headers are marker rows (child is a
     *  Granite.HeaderLabel); only sections with rows get one, and
     *  only in the All slice — Pinned/Archived stay flat lists. Real
     *  rows are untouched, so selection and scroll position survive. */
    private void place_section_headers () {
        clear_section_headers ();
        if (filter_mode != FilterMode.ALL) {
            return;
        }
        int current = -1;
        for (var c = listbox.get_first_child (); c != null; c = c.get_next_sibling ()) {
            if (!(c is Gtk.ListBoxRow) || !(((Gtk.ListBoxRow) c).get_child () is SidebarRow)) {
                continue;
            }
            var inner = (SidebarRow) ((Gtk.ListBoxRow) c).get_child ();
            var session = find_session (inner.session_id);
            int section = session != null ? section_of_session (session) : 2;
            if (section == current) {
                continue;
            }
            current = section;
            var header_row = new Gtk.ListBoxRow () {
                child = new Granite.HeaderLabel (section_title (section)) {
                    margin_start = 12,
                    margin_end = 12,
                    margin_top = 6
                },
                selectable = false,
                activatable = false
            };
            listbox.insert (header_row, row_index (c));
        }
    }
}

public class SidebarRow : Granite.ListItem {
    public signal void action_requested (string action);

    public string session_id { get; construct; }

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

    public SidebarRow (Session session) {
        Object (session_id: session.id);

        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10) {
            margin_start = 6,
            margin_end = 6,
            margin_top = 6,
            margin_bottom = 6
        };

        /* Avatar: model icon inside a rounded tinted badge, with a
         * small running indicator overlaid on its corner. */
        model_icon = new Gtk.Image.from_icon_name (
            ModelIcons.icon_for (session.provider_id, session.model_id)
        ) {
            pixel_size = 18,
            valign = Gtk.Align.CENTER,
            tooltip_text = session.model != "" ? session.model : "No model"
        };
        model_icon.add_css_class ("model-icon");

        var avatar = new Gtk.Overlay () {
            valign = Gtk.Align.CENTER,
            halign = Gtk.Align.CENTER
        };
        var avatar_badge = new Gtk.CenterBox () {
            width_request = 34,
            height_request = 34,
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
        subtitle_label.add_css_class ("dim-label");
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
        pin_icon.add_css_class ("dim-label");

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
     *  labels in place. */
    public void refresh (Session? session) {
        if (session == null) {
            return;
        }
        base_title = session.title;
        title_label.label = session.title;
        subtitle_default = session.directory_name;
        apply_subtitle ();
        /* Keep a live activity suffix across refreshes ("Title — Running"). */
        var dash = tooltip_text.index_of ("—");
        tooltip_text = dash >= 0
            ? session.title + " " + tooltip_text.substring (dash)
            : session.title;
        model_icon.set_from_icon_name (ModelIcons.icon_for (session.provider_id, session.model_id));
        model_icon.tooltip_text = session.model != "" ? session.model : "No model";
        pin_icon.visible = session.pinned;
        menu.remove_all ();
        menu.append ("Rename…", "row.rename");
        menu.append ("View Changes", "row.diff");
        menu.append ("Fork Session", "row.fork");
        menu.append ("Compact Context", "row.compact");
        menu.append (session.pinned ? "Unpin" : "Pin", session.pinned ? "row.unpin" : "row.pin");
        menu.append (session.archived ? "Unarchive" : "Archive", session.archived ? "row.unarchive" : "row.archive");
        menu.append ("Delete Session", "row.delete");
    }
}

}
