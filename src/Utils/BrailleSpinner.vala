/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * CLI-style braille spinner (⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏), used for thinking,
 * tool execution, compaction and retry states — the same rhythm
 * the OpenCode TUI uses.
 *
 * Note: Gtk.Label is final in GTK4, so this is a Box that owns
 * a label.
 */

namespace OpenClient {

public class BrailleSpinner : Gtk.Box {
    private const string[] FRAMES = {
        "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"
    };

    private Gtk.Label frame_label;
    private uint timer = 0;
    private int frame = 0;

    public bool spinning {
        get {
            return timer != 0;
        }
    }

    public BrailleSpinner () {
        Object (orientation: Gtk.Orientation.HORIZONTAL);

        frame_label = new Gtk.Label (FRAMES[0]) {
            valign = Gtk.Align.CENTER
        };
        frame_label.add_css_class ("braille-spinner");
        append (frame_label);

        visible = false;
        valign = Gtk.Align.CENTER;
    }

    public void start () {
        visible = true;
        if (timer != 0) {
            return;
        }
        timer = Timeout.add (90, () => {
            frame = (frame + 1) % FRAMES.length;
            frame_label.label = FRAMES[frame];
            return Source.CONTINUE;
        });
    }

    public void stop () {
        if (timer != 0) {
            Source.remove (timer);
            timer = 0;
        }
        visible = false;
    }

    public override void dispose () {
        stop ();
        base.dispose ();
    }
}

}
