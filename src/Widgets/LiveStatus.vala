/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * One-line live activity for an assistant message, e.g.
 *
 *   ⠋ Figuring out which file to read…
 *   ✓ Read file · src/MainWindow.vala
 *
 * Flat (never a bubble) and single-line: while the turn runs it
 * shows what the agent is doing right now with a CLI braille
 * spinner; when the turn ends the spinner becomes a check and the
 * last activity stays as a summary. Details keep streaming below
 * in the reasoning block and the tool cards.
 */

namespace OpenClient {

public class LiveStatus : Gtk.Box {
    private BrailleSpinner spinner;
    private Gtk.Image done_icon;
    private Gtk.Stack indicator;
    private Gtk.Label activity_label;
    private bool finished = false;

    public LiveStatus () {
        Object (
            orientation: Gtk.Orientation.HORIZONTAL,
            spacing: 6
        );
        add_css_class ("live-status");
        visible = false;

        spinner = new BrailleSpinner ();
        spinner.start ();
        done_icon = new Gtk.Image.from_icon_name ("process-completed") {
            pixel_size = 14,
            valign = Gtk.Align.CENTER
        };

        indicator = new Gtk.Stack () {
            transition_type = Gtk.StackTransitionType.CROSSFADE
        };
        indicator.add_named (spinner, "running");
        indicator.add_named (done_icon, "done");
        indicator.visible_child_name = "running";

        activity_label = new Gtk.Label ("") {
            xalign = 0,
            hexpand = true,
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 90
        };

        append (indicator);
        append (activity_label);
    }

    /** Shows the current activity with a running spinner. */
    public void set_activity (string text) {
        var clean = text.strip ();
        if (clean == "") {
            return;
        }
        finished = false;
        spinner.start ();
        indicator.visible_child_name = "running";
        activity_label.label = clean;
        visible = true;
    }

    /** Hides the line until the next activity (used while reasoning
     *  streams: the reasoning block already carries its own spinner
     *  and text, so echoing its first line here would duplicate it). */
    public void hide_status () {
        visible = false;
    }

    /** Freezes the last activity with a check mark. Always stops the
     *  spinner, even while hidden (reasoning hides this line mid-turn):
     *  otherwise a later event could resurrect a spinning line after
     *  the turn already ended. With @keep_summary false the line is
     *  dropped entirely, for phases that say nothing useful once the
     *  message itself is on screen. */
    public void set_done (bool keep_summary = true) {
        finished = true;
        spinner.stop ();
        if (!visible) {
            return;
        }
        if (!keep_summary) {
            visible = false;
            return;
        }
        indicator.visible_child_name = "done";
    }

    public bool is_finished () {
        return finished;
    }
}

}
