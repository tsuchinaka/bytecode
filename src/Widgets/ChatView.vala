/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Scrollable conversation view. Keeps a bubble per message id.
 *
 * Scroll policy: while the user stays near the bottom, every new
 * message is first shown from its top, then the live stream is
 * followed to the newest line. The moment the user scrolls up,
 * the view stops moving and a floating pill offers a jump back
 * to the latest message.
 *
 * Note: Gtk.ScrolledWindow is final in GTK4, so this is a Box
 * that owns a scrolled window inside an overlay.
 */

namespace OpenClient {

public class ChatView : Gtk.Box {
    private Gtk.ScrolledWindow scrolled;
    private Gtk.Box message_box;
    private Gtk.Button latest_pill;
    private Gee.HashMap<string, MessageBubble> bubbles;
    private Gee.HashMap<string, SystemDivider> dividers;
    /** One card per changed file, updated in place as a turn keeps
     *  writing it (see set_file_change). */
    private Gee.HashMap<string, ChangeCard> changes;
    /** The same cards in the order they arrived, so a rebuild can put
     *  them back after the conversation in a stable order. */
    private Gee.ArrayList<string> change_order;
    private Gee.HashMap<string, string> pending_models;
    private bool stick_to_bottom = true;
    private Gtk.Widget? pending_top_widget = null;
    private bool programmatic_scroll = false;
    /** While true, appends skip per-message scroll pinning; the
     *  caller pins once at the end via end_bulk (). */
    private bool bulk_loading = false;
    /** Playful rotating lines ("Doing the cookies…") vs a plain
     *  "Thinking…" while awaiting the first reply. */
    public bool playful { get; set; default = true; }
    /** "Model is working" placeholder shown between send and the first
     *  streamed content, with rotating playful status lines. */
    /** What the footer describes: real model work vs blocked on input. */
    public enum PendingState {
        WORKING,
        WAITING_PERMISSION,
        WAITING_ANSWER
    }

    private PendingState pending_state = PendingState.WORKING;
    private Gtk.Box? pending_box = null;
    private BrailleSpinner? pending_spinner = null;
    private Gtk.Label? pending_label = null;
    private uint quip_source = 0;
    private string[] quips;
    private int last_quip = -1;

    public ChatView () {
        Object (
            orientation: Gtk.Orientation.VERTICAL,
            vexpand: true
        );
        bubbles = new Gee.HashMap<string, MessageBubble> ();
        dividers = new Gee.HashMap<string, SystemDivider> ();
        changes = new Gee.HashMap<string, ChangeCard> ();
        change_order = new Gee.ArrayList<string> ();
        pending_models = new Gee.HashMap<string, string> ();
        quips = {
            "Doing the cookies…",
            "Warming up the GPUs…",
            "Consulting the oracle…",
            "Herding electrons…",
            "Polishing the tokens…",
            "Asking the hamsters…",
            "Reading the docs (for once)…",
            "Feeding the context window…",
            "Stirring the neural soup…",
            "Convincing the bits…",
            "Sharpening the pencils…",
            "Brewing the coffee…",
            "Untangling the cables…",
            "Waking up the model…"
        };

        message_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 18) {
            margin_top = 18,
            margin_bottom = 18,
            margin_start = 12,
            margin_end = 12,
            valign = Gtk.Align.START
        };

        scrolled = new Gtk.ScrolledWindow () {
            vexpand = true,
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            child = message_box
        };
        /* `changed` fires once the new content is really allocated,
         * so pinning here never reads a stale upper value. */
        scrolled.vadjustment.changed.connect (() => {
            if (pending_top_widget != null && stick_to_bottom) {
                scroll_widget_top (pending_top_widget);
                pending_top_widget = null;
            } else if (stick_to_bottom) {
                pin_to_bottom ();
            }
            update_pill ();
        });
        /* User scrolls re-derive stickiness; our own pins never do. */
        scrolled.vadjustment.value_changed.connect (() => {
            if (programmatic_scroll) {
                update_pill ();
                return;
            }
            stick_to_bottom = is_near_bottom ();
            if (!stick_to_bottom) {
                pending_top_widget = null;
            }
            update_pill ();
        });

        latest_pill = new Gtk.Button.with_label ("↓ Latest") {
            halign = Gtk.Align.CENTER,
            valign = Gtk.Align.END,
            margin_bottom = 12,
            visible = false
        };
        latest_pill.add_css_class ("pill");
        latest_pill.clicked.connect (() => scroll_to_bottom (true));

        var overlay = new Gtk.Overlay () {
            child = scrolled
        };
        overlay.add_overlay (latest_pill);

        append (overlay);
    }

    public void clear () {
        hide_pending ();
        Gtk.Widget? child = message_box.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            message_box.remove (child);
            child = next;
        }
        bubbles.clear ();
        dividers.clear ();
        changes.clear ();
        change_order.clear ();
        pending_models.clear ();
        latest_pill.visible = false;
        /* A fresh conversation starts at the bottom: the scroll state
         *  belongs to the conversation that was just dropped, and
         *  inheriting "user scrolled up" would open the next session
         *  part-way with the jump pill showing. */
        stick_to_bottom = true;
        pending_top_widget = null;
        programmatic_scroll = false;
    }

    /** Shows the "model is working" footer (spinner + status line),
     *  pinned after every message until the turn ends. At most one is
     *  ever visible; repeats just re-pin it last. */
    public void show_pending () {
        set_pending_state (PendingState.WORKING);
    }

    /** Same footer, but describing a turn blocked on the user instead
     *  of model work: the rotating quips give way to a static
     *  "waiting" line until the turn resumes or ends. */
    public void set_pending_state (PendingState state) {
        bool repeated = (state == pending_state) && pending_box != null;
        pending_state = state;
        if (pending_box == null) {
            pending_spinner = new BrailleSpinner ();
            pending_spinner.start ();
            pending_label = new Gtk.Label ("") {
                xalign = 0,
                ellipsize = Pango.EllipsizeMode.END
            };
            pending_label.add_css_class (Granite.CssClass.DIM);
            pending_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
                margin_top = 6,
                margin_bottom = 6,
                margin_start = 12,
                margin_end = 12
            };
            pending_box.append (pending_spinner);
            pending_box.append (pending_label);
            message_box.append (pending_box);
        } else if (!repeated) {
            /* Only move the footer when the state actually changed:
             *  permission/question flips arrive in bursts, and each one
             *  would otherwise reparent + rescroll for nothing. */
            pin_pending_last ();
        }
        apply_pending_text ();
        if (!repeated) {
            scroll_to_bottom ();
        }
    }

    /** Picks the footer line for the current state: rotating playful
     *  quips while the model works, a static waiting line while the
     *  turn is blocked on the user. */
    private void apply_pending_text () {
        if (pending_label == null) {
            return;
        }
        switch (pending_state) {
            case PendingState.WAITING_PERMISSION:
                stop_quips ();
                pending_label.label = "Waiting for permission…";
                break;
            case PendingState.WAITING_ANSWER:
                stop_quips ();
                pending_label.label = "Waiting for your answer…";
                break;
            default:
                if (!playful) {
                    stop_quips ();
                    pending_label.label = "Thinking…";
                    break;
                }
                spin_quip ();
                start_quips ();
                break;
        }
    }

    private void start_quips () {
        if (quip_source != 0) {
            return;
        }
        quip_source = GLib.Timeout.add (2600, () => {
            if (pending_box == null) {
                quip_source = 0;
                return false;
            }
            spin_quip ();
            return true;
        });
    }

    private void stop_quips () {
        if (quip_source != 0) {
            GLib.Source.remove (quip_source);
            quip_source = 0;
        }
    }

    public void hide_pending () {
        stop_quips ();
        if (pending_box != null) {
            message_box.remove (pending_box);
            pending_box = null;
            pending_spinner = null;
            pending_label = null;
        }
    }

    private void spin_quip () {
        if (pending_label == null || quips.length == 0) {
            return;
        }
        var i = GLib.Random.int_range (0, quips.length);
        if (quips.length > 1) {
            while (i == last_quip) {
                i = GLib.Random.int_range (0, quips.length);
            }
        }
        last_quip = i;
        pending_label.label = quips[i];
    }

    /** Keeps the pending footer after every real message, so a
     *  history rebuild landing mid-turn, or a freshly streamed
     *  bubble or divider, never buries it mid-list.
     *  (Re-append, not reorder: GtkBox treats a NULL sibling as the
     *  first position, which is the wrong end here.) */
    private void pin_pending_last () {
        if (pending_box == null || pending_box.get_parent () != message_box) {
            return;
        }
        /* Already the last child (the common case when messages stream
         * in one after another): skipping the move avoids GTK
         * unparenting/reparenting the footer and re-measuring every
         * sibling in the box for a no-op. */
        if (message_box.get_last_child () == pending_box) {
            return;
        }
        message_box.remove (pending_box);
        message_box.append (pending_box);
    }

    public void add_message (Message message, bool force_scroll = false) {
        if (bubbles.has_key (message.id) || dividers.has_key (message.id)) {
            return;
        }
        if (!message.renderable) {
            return;
        }

        if (message.role == MessageRole.SYSTEM) {
            var divider = new SystemDivider (
                message.id,
                message.system_icon,
                message.divider_text (),
                message.divider_status ()
            );
            if (message.system_summary != "") {
                divider.set_summary (message.system_summary);
                divider.collapse_on_done ();
            }
            dividers[message.id] = divider;
            message_box.append (divider);
            if (bulk_loading) {
                return;
            }
            /* Live arrival (not a history rebuild): play the entrance. */
            divider.add_css_class ("chat-arrive");
            pin_pending_last ();
            if (!force_scroll) {
                pending_top_widget = divider;
            }
            scroll_to_bottom (force_scroll);
            return;
        }

        var bubble = new MessageBubble (message);
        bubbles[message.id] = bubble;
        message_box.append (bubble);
        if (bulk_loading) {
            return;
        }
        bubble.add_css_class ("chat-arrive");
        pin_pending_last ();
        if (!force_scroll) {
            pending_top_widget = bubble;
        }
        scroll_to_bottom (force_scroll);
    }

    /** Starts a bulk rebuild: per-message scroll pinning is skipped
     *  until end_bulk (). */
    public void begin_bulk () {
        bulk_loading = true;
    }

    /** Ends a bulk rebuild: one pin at the end. */
    public void end_bulk () {
        bulk_loading = false;
        /* Change cards describe what the session looks like now, not
         *  where in its history a render happened to be: after a
         *  rebuild they belong after the conversation. */
        foreach (var path in change_order) {
            var card = changes[path];
            if (card == null || card.get_parent () != message_box) {
                continue;
            }
            message_box.remove (card);
            message_box.append (card);
        }
        pin_pending_last ();
        scroll_to_bottom (true);
    }

    /** Aborts a bulk rebuild (e.g. superseded by a newer one)
     *  without pinning the scroll position. */
    public void cancel_bulk () {
        bulk_loading = false;
    }

    /** Creates or updates a centered system divider (live events). */
    public void set_divider (string divider_id, string icon_name, string text, string status) {
        var divider = dividers[divider_id];
        if (divider == null) {
            divider = new SystemDivider (divider_id, icon_name, text, status);
            dividers[divider_id] = divider;
            message_box.append (divider);
            /* Live dividers enter like history-added ones. */
            divider.add_css_class ("chat-arrive");
            pin_pending_last ();
            pending_top_widget = divider;
            scroll_to_bottom ();
            return;
        }
        divider.set_status (icon_name, text, status);
        if (status != "running") {
            divider.collapse_on_done ();
        }
        scroll_to_bottom ();
    }

    public void append_divider_summary (string divider_id, string delta) {
        var divider = dividers[divider_id];
        if (divider == null) {
            return;
        }
        divider.append_summary (delta);
        scroll_to_bottom ();
    }

    /** A new turn starts: changes after this (even to a file an earlier
     *  turn already touched) get their own card, so the conversation
     *  records what each turn changed instead of one card silently
     *  growing for the whole session. The cards already on screen stay
     *  where they are. */
    public void begin_turn_changes () {
        changes.clear ();
        change_order.clear ();
    }

    /** A file the agent changed, shown in the conversation where it
     *  happened: one card per path within a turn, updated in place
     *  while that turn keeps writing it. */
    public void set_file_change (string path, int additions, int deletions,
        string status, string patch, bool editing) {
        var card = changes[path];
        var is_new = card == null;
        if (is_new) {
            card = new ChangeCard (path);
            changes[path] = card;
            change_order.add (path);
            message_box.append (card);
        }
        card.set_change (additions, deletions, status, patch, editing);
        if (!is_new || bulk_loading) {
            return;
        }
        card.add_css_class ("chat-arrive");
        pin_pending_last ();
        pending_top_widget = card;
        scroll_to_bottom ();
    }

    /** Records the model a message belongs to; applied when its bubble appears. */
    public void note_model (string message_id, string model) {
        if (model == "") {
            return;
        }
        if (bubbles.has_key (message_id)) {
            bubbles[message_id].set_model (model);
        } else {
            pending_models[message_id] = model;
        }
    }

    public MessageBubble ensure_bubble (string message_id) {
        if (bubbles.has_key (message_id)) {
            return bubbles[message_id];
        }
        var message = new Message () {
            id = message_id,
            role = MessageRole.ASSISTANT
        };
        var bubble = new MessageBubble (message);
        if (pending_models.has_key (message_id)) {
            bubble.set_model (pending_models[message_id]);
            pending_models.unset (message_id);
        }
        bubbles[message_id] = bubble;
        message_box.append (bubble);
        /* A streamed turn opening its bubble: same entrance as any
         *  other live arrival. */
        bubble.add_css_class ("chat-arrive");
        /* Streamed content must never bury the footer: it stays
         * pinned at the very bottom until the turn ends. */
        pin_pending_last ();
        pending_top_widget = bubble;
        scroll_to_bottom ();
        return bubble;
    }

    /** Freezes every live status line of the finished turn and drops
     *  the footer: the turn is over, so nothing streams anymore.
     *  Freezes ALL bubbles, not just ones created mid-turn: live
     *  events can spin lines on history-loaded bubbles too, and those
     *  must never be left running. */
    public void finish_live () {
        hide_pending ();
        foreach (var bubble in bubbles.values) {
            bubble.finish_live ();
        }
    }

    public void append_text (string message_id, string delta) {
        ensure_bubble (message_id).append_text (delta);
        scroll_to_bottom ();
    }

    public void finish_text (string message_id, string text) {
        ensure_bubble (message_id).set_text (text);
        scroll_to_bottom ();
    }

    public void append_reasoning (string message_id, string delta) {
        ensure_bubble (message_id).append_reasoning (delta);
        scroll_to_bottom ();
    }

    public void finish_reasoning (string message_id, string text, string duration_label = "") {
        var bubble = ensure_bubble (message_id);
        bubble.set_reasoning (text);
        bubble.finish_reasoning (duration_label);
    }

    public void tool_started (string message_id, string call_id, string tool_name) {
        ensure_bubble (message_id).tool_started (call_id, tool_name);
        scroll_to_bottom ();
    }

    public void tool_input (string message_id, string call_id, string summary) {
        if (bubbles.has_key (message_id)) {
            bubbles[message_id].tool_input (call_id, summary);
        }
    }

    public void tool_done (string message_id, string call_id, string output, Gee.ArrayList<FileAttachment>? files, bool error = false) {
        if (bubbles.has_key (message_id)) {
            bubbles[message_id].tool_done (call_id, output, files, error);
        }
    }

    /** Follows the stream only when the user is already at the bottom. */
    private bool is_near_bottom () {
        var adjustment = scrolled.vadjustment;
        if (adjustment == null) {
            return true;
        }
        return adjustment.value >= adjustment.upper - adjustment.page_size - 60;
    }

    private void update_pill () {
        if (latest_pill.visible == stick_to_bottom) {
            latest_pill.visible = !stick_to_bottom;
        }
    }

    public void scroll_to_bottom (bool force = false) {
        if (force) {
            stick_to_bottom = true;
            pending_top_widget = null;
        }
        if (!stick_to_bottom) {
            update_pill ();
            return;
        }
        /* Best effort now; the `changed` handler pins again once the
         * fresh allocation lands, so this never reads stale geometry. */
        pin_to_bottom ();
        update_pill ();
    }

    /** Pins the viewport to the newest line. */
    private void pin_to_bottom () {
        var adjustment = scrolled.vadjustment;
        if (adjustment == null) {
            return;
        }
        var target = adjustment.upper - adjustment.page_size;
        /* Already showing the newest line: the common case while a
         * turn streams, since every delta re-enters this method. Writing
         * the same value again only emits adjustment signals, so the
         * check is what keeps streaming cheap. */
        if (adjustment.value >= target - 0.5) {
            return;
        }
        programmatic_scroll = true;
        adjustment.set_value (target);
        programmatic_scroll = false;
    }

    /** Reveals a new message from its first line. */
    private void scroll_widget_top (Gtk.Widget widget) {
        var adjustment = scrolled.vadjustment;
        if (adjustment == null) {
            return;
        }
        /* Y inside the scrolled viewport: translate the widget's own
         *  top-left relative to the message list. Widget.get_allocation
         *  is deprecated and only gives the widget-local box. */
        Graphene.Point top;
        if (!widget.compute_point (message_box, Graphene.Point.zero (), out top)) {
            /* Not in the same hierarchy (yet): nothing to reveal. */
            return;
        }
        var max = adjustment.upper - adjustment.page_size;
        scroll_to_value (double.min (top.y, double.max (0, max)));
    }

    private void scroll_to_value (double target) {
        var adjustment = scrolled.vadjustment;
        if (adjustment != null) {
            programmatic_scroll = true;
            adjustment.set_value (double.max (0, target));
            programmatic_scroll = false;
        }
    }
}

}
