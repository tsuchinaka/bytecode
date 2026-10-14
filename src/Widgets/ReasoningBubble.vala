/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Standalone reasoning block. Deliberately NOT a chat bubble:
 * a flat row with a symbolic flask icon, a CLI-style braille
 * spinner while thinking (check mark when done) and an expandable
 * body so the thought stays readable without mixing with the
 * answer text or the tool cards.
 */

namespace OpenClient {

public class ReasoningBubble : Gtk.Box {
    private BrailleSpinner spinner;
    private Gtk.Image done_icon;
    private Gtk.Stack indicator;
    private Gtk.Label title_label;
    private Gtk.Label body_label;
    private Gtk.Expander expander;

    private StringBuilder buffer = new StringBuilder ();
    private bool seen = false;
    private bool queued = false;
    private bool finished = false;
    /** True once the body shows the whole buffer (not a live tail). */
    private bool full_rendered = false;
    /** History text waiting for its first expand: parsing kilobytes
     *  of old thought is deferred until the user actually opens it. */
    private bool body_dirty = false;
    /** Fast coalescing while the thought is small… */
    private const int FAST_LIMIT = 8000;
    /** …slower once it grows, so long streams can't hog the loop… */
    private const int SLOW_DELAY_MS = 500;
    /** …and live renders are capped to this tail while streaming
     *  (the full thought renders once, on finish). */
    private const int LIVE_TAIL_LIMIT = 24000;

    public ReasoningBubble () {
        Object (
            orientation: Gtk.Orientation.VERTICAL,
            spacing: 2
        );
        add_css_class ("reasoning-block");
        visible = false;

        var think_icon = new Gtk.Image.from_icon_name ("applications-science") {
            pixel_size = 14,
            valign = Gtk.Align.CENTER
        };

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

        title_label = new Gtk.Label ("Thinking…") {
            xalign = 0
        };
        title_label.add_css_class ("reasoning-title");

        var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        header.append (think_icon);
        header.append (indicator);
        header.append (title_label);

        body_label = new Gtk.Label ("") {
            xalign = 0,
            wrap = true,
            wrap_mode = Pango.WrapMode.WORD_CHAR,
            selectable = true,
            visible = false
        };
        body_label.add_css_class ("reasoning-label");

        Markdown.wire_links (body_label);

        expander = new Gtk.Expander (null) {
            label_widget = header,
            child = body_label,
            expanded = false
        };
        expander.notify["expanded"].connect (() => {
            if (expander.expanded && body_dirty) {
                body_dirty = false;
                render_full ();
            }
        });

        append (expander);
    }

    public void append_reasoning (string delta) {
        if (!visible) {
            visible = true;
            expander.expanded = true;
        }
        buffer.append (delta);
        full_rendered = false;
        seen = true;
        queue_render ();
    }

    public void set_reasoning (string text) {
        buffer = new StringBuilder ();
        buffer.append (text);
        full_rendered = false;
        seen = text != "";
        visible = seen;
        /* Leave the expander state alone: history (fresh widget)
         * stays collapsed, live (already expanded by deltas) stays
         * open. */
        queued = false;
        if (!seen) {
            return;
        }
        if (expander.expanded || buffer.len <= LIVE_TAIL_LIMIT) {
            render_full ();
        } else {
            /* Collapsed history with a big thought: don't pay the
             * parse until the user opens it. */
            body_dirty = true;
        }
    }

    public void finish_reasoning (string duration_label = "") {
        if (!seen || finished) {
            return;
        }
        finished = true;
        visible = true;
        /* Expander state untouched (see set_reasoning). */
        if (duration_label != "") {
            title_label.label = @"Thought for $duration_label";
        } else {
            title_label.label = "Thought";
        }
        spinner.stop ();
        indicator.visible_child_name = "done";
        /* Settle the whole thought exactly once: the live view may be
         * showing the capped tail, while collapsed history stays
         * deferred until the user opens it. */
        if (!full_rendered) {
            if (body_label.visible) {
                render_full ();
            } else {
                body_dirty = true;
            }
        }
    }

    private void queue_render () {
        if (queued) {
            return;
        }
        queued = true;
        /* Coalesce rapid reasoning deltas: snappy while the thought
         * is small, throttled once it grows, instead of reformatting
         * the whole buffer on every event. */
        uint delay = buffer.len > FAST_LIMIT ? SLOW_DELAY_MS : 60;
        GLib.Timeout.add (delay, () => {
            queued = false;
            render_live ();
            return false;
        });
    }

    /** Streaming render, capped to a tail once the thought gets big
     *  so long chains can't jank the view. Cut at a line boundary;
     *  the converter tolerates the dangling open fence. */
    private void render_live () {
        if (!seen) {
            return;
        }
        if (buffer.len <= LIVE_TAIL_LIMIT) {
            render_full ();
            return;
        }
        var full = buffer.str;
        var start = full.length - LIVE_TAIL_LIMIT;
        var cut = full.index_of ("\n", start);
        var tail = cut > 0 ? full.substring (cut + 1) : full.substring (start);
        body_label.set_markup (Markdown.to_pango ("…\n\n" + tail));
        body_label.visible = true;
    }

    private void render_full () {
        if (!seen) {
            return;
        }
        body_dirty = false;
        full_rendered = true;
        body_label.set_markup (Markdown.to_pango (buffer.str));
        body_label.visible = true;
    }
}

}
