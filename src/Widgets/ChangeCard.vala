/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * One file the agent changed, as part of the conversation: what the
 * file is, what changed about it (+N −M, added/deleted/modified) and
 * the patch itself, folded away until it is asked for.
 *
 * Tool cards say what the agent ran; this says what it left behind, at
 * the point in the thread where it happened, instead of in a dialog
 * apart from the conversation. The composer chip stays as the summary
 * and the way to the full list.
 */

namespace OpenClient {

public class ChangeCard : Gtk.Box {
    public string path { get; construct; }

    private Gtk.Image icon;
    private Gtk.Spinner spinner;
    private Gtk.Label add_label;
    private Gtk.Label del_label;
    private Gtk.Image chevron;
    private Gtk.Button header_button;
    private Gtk.Revealer body_revealer;
    private Gtk.ScrolledWindow scroller;

    private string patch = "";
    private string patch_built = "";
    private bool expanded = false;

    public ChangeCard (string path) {
        Object (
            path: path,
            orientation: Gtk.Orientation.VERTICAL,
            spacing: 0,
            halign: Gtk.Align.FILL,
            hexpand: true
        );
        add_css_class ("change-card");

        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
            margin_top = 7,
            margin_bottom = 7,
            margin_start = 10,
            margin_end = 10
        };

        icon = new Gtk.Image.from_icon_name ("text-x-generic") {
            pixel_size = 16,
            valign = Gtk.Align.CENTER
        };
        row.append (icon);

        /* The file being written spins where the icon would be, the
         *  same language the composer chip uses. */
        spinner = new Gtk.Spinner () {
            visible = false,
            valign = Gtk.Align.CENTER,
            tooltip_text = "Being changed now"
        };
        row.append (spinner);

        var path_label = new Gtk.Label (path) {
            xalign = 0,
            hexpand = true,
            ellipsize = Pango.EllipsizeMode.MIDDLE,
            valign = Gtk.Align.CENTER,
            tooltip_text = path
        };
        path_label.add_css_class (Granite.CssClass.MONOSPACE);
        path_label.add_css_class ("change-path");
        row.append (path_label);

        add_label = new Gtk.Label ("") {
            valign = Gtk.Align.CENTER,
            visible = false
        };
        add_label.add_css_class ("diff-add");
        row.append (add_label);

        del_label = new Gtk.Label ("") {
            valign = Gtk.Align.CENTER,
            visible = false
        };
        del_label.add_css_class ("diff-del");
        row.append (del_label);

        chevron = new Gtk.Image.from_icon_name ("pan-end-symbolic") {
            valign = Gtk.Align.CENTER
        };
        row.append (chevron);

        header_button = new Gtk.Button () {
            child = row
        };
        header_button.add_css_class ("flat");
        header_button.add_css_class ("change-header");
        header_button.clicked.connect (() => {
            if (!has_patch) {
                return;
            }
            if (expanded) {
                set_expanded (false);
                return;
            }
            /* Built on first open: a session can hold hundreds of
             *  thousands of patch lines, and nobody asked for them
             *  yet. */
            ensure_patch ();
            set_expanded (true);
        });
        append (header_button);

        /* Vertical is dynamic: the card takes the height the patch
         *  needs, so opening one shows the whole change. Only long
         *  lines scroll (sideways), which is how diffs are read. */
        scroller = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.AUTOMATIC,
            vscrollbar_policy = Gtk.PolicyType.NEVER,
            propagate_natural_height = true
        };
        scroller.add_css_class ("change-body");

        body_revealer = new Gtk.Revealer () {
            child = scroller,
            transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN,
            reveal_child = false
        };
        append (body_revealer);
        set_expanded (false);
    }

    /** Counts, state and patch. The lines are built on first open (see
     *  ensure_patch), so a file that keeps being written only carries
     *  its latest patch text around until someone looks. */
    public void set_change (int additions, int deletions, string status,
        string patch, bool editing) {
        var name = status == "added" ? "list-add"
            : (status == "deleted" ? "edit-delete" : "text-x-generic");
        icon.icon_name = name;
        icon.visible = !editing;
        spinner.visible = editing;
        spinner.spinning = editing;

        add_label.label = @"+$additions";
        del_label.label = @"−$deletions";
        /* Zero counts are noise, same as everywhere else. */
        add_label.visible = additions > 0;
        del_label.visible = deletions > 0;

        this.patch = patch;
        var has_patch = this.has_patch;
        chevron.visible = has_patch;
        header_button.tooltip_text = has_patch ? "Show the patch" : path;

        if (!has_patch) {
            patch_built = "";
            scroller.child = null;
            set_expanded (false);
        } else if (expanded) {
            /* Keep an open card current while the file is written. */
            ensure_patch ();
        }
    }

    private bool has_patch {
        get {
            return patch.strip () != "";
        }
    }

    private void ensure_patch () {
        if (patch_built == patch) {
            return;
        }
        patch_built = patch;
        scroller.child = new DiffPatchView (patch);
    }

    private void set_expanded (bool open) {
        expanded = open;
        body_revealer.reveal_child = open;
        chevron.icon_name = open ? "pan-down-symbolic" : "pan-end-symbolic";
        if (has_patch) {
            header_button.tooltip_text = open ? "Hide the patch" : "Show the patch";
        }
    }
}

}
