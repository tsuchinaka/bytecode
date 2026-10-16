/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * A unified patch, one line per row so each line can be coloured:
 * additions green, deletions red, hunk headers accented and context
 * dim. Used by the change cards the conversation shows after the agent
 * touches a file.
 *
 * Lines are capped so a huge patch cannot flood the widget tree; the
 * cap is the only limit, the view itself grows to fit whatever it
 * shows.
 */

namespace OpenClient {

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
