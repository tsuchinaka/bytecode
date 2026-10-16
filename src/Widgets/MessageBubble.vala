/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * A single chat message. User turns are accent-tinted blocks pinned
 * right; assistant answers are flat full-width text (T3-style) with
 * rich tool cards and image attachments.
 *
 * Thinking lives OUTSIDE the bubble in a flat ReasoningBubble
 * above it, so thoughts never mix with the answer or the actions.
 *
 * Streaming renders are coalesced: deltas accumulate in the
 * buffer and the expensive Markdown pass runs at most once per
 * main-loop idle round, with a final full render on completion.
 */

namespace OpenClient {

public class MessageBubble : Gtk.Box {
    public string message_id { get; construct; }

    private Gtk.Box text_box;
    private Gtk.Label meta_label;
    private LiveStatus live;
    private ReasoningBubble reasoning;
    private Gee.HashMap<string, string> live_tools;
    private Gee.HashMap<string, string> live_tool_names;
    /** Call ids of the tools still running, in start order, so the live
     *  line can name the most recent one instead of whichever the map
     *  happens to hand back. */
    private Gee.ArrayList<string> live_tool_order;
    private string live_last_tool = "";
    private string live_phase = "";
    private Gtk.Box tool_box;
    private Gtk.Box files_box;
    private Gtk.Box content;
    /** Persistent turn-failure line (history), same icon language as
     *  the live error divider. Hidden when the turn was healthy. */
    private Gtk.Box error_box;

    private Gee.HashMap<string, ToolCard> tool_cards;

    private StringBuilder text_buffer = new StringBuilder ();
    private bool text_seen = false;
    private bool tools_seen = false;
    private bool files_seen = false;
    private bool text_queued = false;
    /** Handle of the queued coalesced render, so a real render that is
     *  already due can cancel it instead of running a second pass. */
    private uint text_render_source = 0;
    /** True for a coalesced render driven by streaming deltas (never
     *  for a full render from history or turn completion), which is the
     *  only path allowed to trade completeness for speed. */
    private bool live_render = false;
    /** True once a streaming render showed a capped tail, so the turn's
     *  end knows the full text still has to be rendered. */
    private bool tail_shown = false;
    /** Widest an attachment preview is drawn (and decoded) at. */
    /** History text beyond this is collapsed behind "Show more". */
    private const int HISTORY_TEXT_LIMIT = 2000;
    /** Coalescing: snappy while the answer is small… */
    private const int FAST_LIMIT = 8000;
    /** …and throttled once it grows, so a long answer can't spend
     *  every frame re-parsing its whole buffer. */
    private const int SLOW_DELAY_MS = 250;
    /** While streaming, only this much tail of the buffer is converted
     *  per render. The whole answer is rendered once the turn ends. */
    private const int LIVE_TAIL_LIMIT = 12000;
    private string? collapsed_full_text = null;
    private Gtk.Button? show_more_button = null;

    public MessageBubble (Message message) {
        /* Assistant answers are flat full-width text (T3-style), not
         * bubbles: no background, no border; tool cards and
         * attachments keep their own styling inside the flat answer.
         * User turns live in UserBubble. */
        Object (
            message_id: message.id,
            orientation: Gtk.Orientation.VERTICAL,
            spacing: 6,
            halign: Gtk.Align.FILL,
            hexpand: true
        );
        tool_cards = new Gee.HashMap<string, ToolCard> ();
        live_tools = new Gee.HashMap<string, string> ();
        live_tool_names = new Gee.HashMap<string, string> ();
        live_tool_order = new Gee.ArrayList<string> ();
        rendered_blocks = new Gee.ArrayList<Markdown.Block> ();
        block_widgets = new Gee.ArrayList<Gtk.Widget> ();
        if (message.created > 0) {
            var time = new DateTime.from_unix_local (message.created / 1000);
            tooltip_text = time.format ("%Y-%m-%d %H:%M");
        }

        content = new Gtk.Box (Gtk.Orientation.VERTICAL, 6) {
            hexpand = true
        };
        content.add_css_class ("assistant-bubble");

        meta_label = new Gtk.Label ("Assistant") {
            xalign = 0,
            visible = false
        };
        meta_label.add_css_class ("message-meta");
        /* Both roles are labelled, from history and while streaming:
         *  live turns learn the model from the event stream, history
         *  from the message itself, and an unknown model falls back to
         *  the time so the line never disappears between the two. */
        var stamp = message.created > 0
            ? new DateTime.from_unix_local (message.created / 1000).format ("%H:%M")
            : "";
        var model = message.model;
        if (model != "") {
            meta_label.label = @"Assistant · $model";
        } else if (stamp != "") {
            meta_label.label = @"Assistant · $stamp";
        }
        meta_label.visible = true;

        live = new LiveStatus ();
        reasoning = new ReasoningBubble ();

        tool_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        tool_box.visible = false;

        /* One block per attachment, top to bottom: a chip that becomes
         *  the picture once it decodes, with the file's name under it.
         *  A vertical box rather than a flow box, because the swap is
         *  what has to end up visible. */
        files_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8) {
            halign = Gtk.Align.START,
            visible = false
        };

        text_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6) {
            visible = false
        };

        error_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            visible = false,
            margin_top = 2
        };

        var history_reasoning = new StringBuilder ();
        var history_reasoning_seen = false;
        var history_reasoning_duration = "";

        foreach (var part in message.parts) {
            switch (part.kind) {
                case PartKind.TEXT:
                    if (part.text != "") {
                        text_buffer.append (part.text);
                        text_seen = true;
                    }
                    break;
                case PartKind.REASONING:
                    if (part.text != "") {
                        history_reasoning.append (part.text);
                        history_reasoning_seen = true;
                    }
                    if (part.duration_label != "") {
                        history_reasoning_duration = part.duration_label;
                    }
                    break;
                case PartKind.TOOL:
                    add_history_tool (part);
                    break;
                case PartKind.FILE:
                    if (part.file != null) {
                        add_file (part.file);
                    }
                    break;
                case PartKind.ERROR:
                    if (part.text != "") {
                        add_history_error (part.text);
                    }
                    break;
                default:
                    break;
            }
        }

        content.append (meta_label);
        /* Preserve the model's part order: text-first turns read
         * text-first instead of always tools-first. Files trail. */
        int first_text = -1;
        int first_tool = -1;
        for (int i = 0; i < message.parts.size; i++) {
            var kind = message.parts[i].kind;
            if (kind == PartKind.TEXT && first_text < 0) {
                first_text = i;
            }
            if (kind == PartKind.TOOL && first_tool < 0) {
                first_tool = i;
            }
        }
        if (first_text >= 0 && (first_tool < 0 || first_text < first_tool)) {
            content.append (text_box);
            content.append (tool_box);
        } else {
            content.append (tool_box);
            content.append (text_box);
        }
        content.append (files_box);

        /* Live status and thinking render above the bubble, never inside it. */
        append (live);
        append (reasoning);
        append (content);
        append (error_box);

        if (history_reasoning_seen) {
            reasoning.set_reasoning (history_reasoning.str);
            reasoning.finish_reasoning (history_reasoning_duration);
        }
        if (text_seen) {
            collapse_long_history ();
            render_text ();
            if (collapsed_full_text != null) {
                show_more_button = new Gtk.Button.with_label ("Show more…") {
                    halign = Gtk.Align.START
                };
                show_more_button.add_css_class (Granite.STYLE_CLASS_FLAT);
                show_more_button.clicked.connect (expand_history_text);
                content.append (show_more_button);
            }
        }
        content.visible = text_seen || tools_seen || files_seen || meta_label.visible;
    }

    /** Long history text is truncated at a line boundary (markup-safe:
     *  the converter closes dangling tags) so opening a session never
     *  pays Pango wrapping for kilobytes of old output. */
    private void collapse_long_history () {
        var full = text_buffer.str;
        if (full.length <= HISTORY_TEXT_LIMIT) {
            return;
        }
        var cut = full.last_index_of ("\n", HISTORY_TEXT_LIMIT);
        if (cut < HISTORY_TEXT_LIMIT / 2) {
            cut = HISTORY_TEXT_LIMIT;
        }
        collapsed_full_text = full;
        text_buffer = new StringBuilder ();
        text_buffer.append (full.substring (0, cut));
        text_buffer.append ("\n\n…");
    }

    private void expand_history_text () {
        if (collapsed_full_text == null) {
            return;
        }
        cancel_queued_render ();
        text_buffer = new StringBuilder ();
        text_buffer.append (collapsed_full_text);
        collapsed_full_text = null;
        render_text ();
        if (show_more_button != null) {
            content.remove (show_more_button);
            show_more_button = null;
        }
    }

    public void set_model (string model) {
        if (model == "") {
            return;
        }
        meta_label.label = @"Assistant · $model";
        meta_label.visible = true;
        content.visible = true;
    }

    public void append_text (string delta) {
        if (collapsed_full_text != null) {
            expand_history_text ();
        }
        if (!text_seen && tool_box.get_first_child () == null) {
            /* Text arrived before any tool: show it first. */
            content.reorder_child_after (tool_box, text_box);
        }
        text_buffer.append (delta);
        text_seen = true;
        content.visible = true;
        live_phase = "text";
        refresh_live_status ();
        queue_text_render ();
    }

    public void set_text (string text) {
        cancel_queued_render ();
        collapsed_full_text = null;
        if (show_more_button != null) {
            content.remove (show_more_button);
            show_more_button = null;
        }
        if (!text_seen && tool_box.get_first_child () == null) {
            content.reorder_child_after (tool_box, text_box);
        }
        text_buffer = new StringBuilder ();
        text_buffer.append (text);
        text_seen = true;
        content.visible = true;
        render_text ();
    }

    public void append_reasoning (string delta) {
        reasoning.append_reasoning (delta);
        live_phase = "reasoning";
        refresh_live_status ();
    }

    public void set_reasoning (string text) {
        reasoning.set_reasoning (text);
        live_phase = "reasoning";
        refresh_live_status ();
    }

    public void finish_reasoning (string duration_label = "") {
        reasoning.finish_reasoning (duration_label);
    }

    /** Turn over: the CLI spinner goes away (check stays), the
     * thinking spinner stops, and any tool card left running (abort)
     * is settled so no spinner is left standing anywhere. */
    public void finish_live () {
        /* A finished line reading "Writing the answer…" describes
         *  nothing the message above it does not already say, so that
         *  one is dropped; tool activity stays as the turn's summary. */
        live.set_done (live_phase != "text");
        reasoning.finish_reasoning ();
        foreach (var card in tool_cards.values) {
            if (card.current_status == ToolStatus.RUNNING) {
                card.set_status (ToolStatus.ERROR);
            }
        }
        /* The streaming pass may have shown a capped tail: settle the
         * whole text now so nothing stays truncated. */
        if (tail_shown || text_queued) {
            cancel_queued_render ();
            render_text ();
        }
    }

    /** Cancels any queued coalesced render: the coalescing timer holds
     *  a reference to this widget, so it must not keep working (or keep
     *  the bubble alive) after the view dropped it. */
    public override void dispose () {
        cancel_queued_render ();
        base.dispose ();
    }

    /** One-line "what is it doing now" from the latest live phase.
     *  Reasoning stays silent here: its block already streams with its
     *  own spinner, so this line only covers tool use and writing. */
    private void refresh_live_status () {
        switch (live_phase) {
            case "tool":
                if (live_last_tool != "") {
                    live.set_activity (live_last_tool);
                }
                break;
            case "text":
                live.set_activity ("Writing the answer…");
                break;
            case "reasoning":
                live.hide_status ();
                break;
            default:
                break;
        }
    }

    /* -- live tool cards --------------------------------------------- */

    public void tool_started (string call_id, string tool_name) {
        if (tool_cards.has_key (call_id)) {
            return;
        }
        var card = new ToolCard (tool_name);
        tool_cards[call_id] = card;
        tool_box.append (card);
        tool_box.visible = true;
        tools_seen = true;
        content.visible = true;
        live_tool_names[call_id] = ToolCard.display_name (tool_name);
        live_last_tool = live_tool_names[call_id] + "…";
        live_tools[call_id] = live_last_tool;
        if (!live_tool_order.contains (call_id)) {
            live_tool_order.add (call_id);
        }
        live_phase = "tool";
        refresh_live_status ();
    }

    public void tool_input (string call_id, string summary) {
        var card = tool_cards[call_id];
        if (card == null) {
            return;
        }
        card.set_input_summary (summary);
        if (live_tools.has_key (call_id) && summary.strip () != "") {
            var pretty = summary.strip ();
            if (pretty.length > 90) {
                pretty = pretty.substring (0, 90) + "…";
            }
            var pretty_name = live_tool_names.has_key (call_id) ? live_tool_names[call_id] : "Tool";
            live_last_tool = @"$pretty_name · $pretty";
            live_tools[call_id] = live_last_tool;
            live_phase = "tool";
            refresh_live_status ();
        }
    }

    public void tool_done (string call_id, string output, Gee.ArrayList<FileAttachment>? files, bool error = false) {
        var card = tool_cards[call_id];
        if (card == null) {
            return;
        }
        card.set_output (output, files);
        card.set_status (error ? ToolStatus.ERROR : ToolStatus.DONE);
        live_tools.unset (call_id);
        live_tool_names.unset (call_id);
        live_tool_order.remove (call_id);
        if (live_phase == "tool") {
            if (live_tool_order.size > 0) {
                /* The newest tool still running describes the turn. */
                var newest = live_tool_order[live_tool_order.size - 1];
                live_last_tool = live_tools.has_key (newest)
                    ? live_tools[newest] : live_last_tool;
            } else if (text_seen) {
                live_phase = "text";
            } else {
                live_phase = "reasoning";
            }
            refresh_live_status ();
        }
    }

    private void add_history_tool (MessagePart part) {
        var card = new ToolCard (part.tool_name);
        if (part.tool_id != "") {
            tool_cards[part.tool_id] = card;
        }
        if (part.tool_input_summary != "") {
            card.set_input_summary (part.tool_input_summary);
        }
        card.set_output (part.tool_output, part.tool_files);
        card.set_status (part.tool_status == "error" ? ToolStatus.ERROR : ToolStatus.DONE,
            part.tool_status == "error" ? part.tool_output : null);
        tool_box.append (card);
        tool_box.visible = true;
        tools_seen = true;
    }

    private void queue_text_render () {
        if (text_queued) {
            return;
        }
        text_queued = true;
        /* Coalesce rapid streaming deltas: ~30fps while the answer is
         * small, throttled once it grows, instead of re-parsing the
         * whole buffer on every event. */
        uint delay = text_buffer.len > FAST_LIMIT ? SLOW_DELAY_MS : 33;
        text_render_source = GLib.Timeout.add (delay, () => {
            text_render_source = 0;
            text_queued = false;
            live_render = true;
            render_text ();
            live_render = false;
            return false;
        });
    }

    /** Cancels a queued streaming render (a real render won the race). */
    private void cancel_queued_render () {
        if (text_render_source != 0) {
            GLib.Source.remove (text_render_source);
            text_render_source = 0;
        }
        text_queued = false;
    }

    private string last_rendered = "";
    private Gee.ArrayList<Markdown.Block> rendered_blocks;
    private Gee.ArrayList<Gtk.Widget> block_widgets;

    private void render_text () {
        var source = text_buffer.str;
        if (source == last_rendered) {
            text_box.visible = text_box.get_first_child () != null;
            return;
        }
        last_rendered = source;

        /* A long answer is one growing widget, and the Markdown pass is
         * O(len): parsing the entire buffer on every coalesced render
         * makes a stream quadratic in the answer's length. While the
         * answer is still streaming, convert only a bounded tail cut
         * at a paragraph boundary (the ellipsis mirrors the history
         * truncation above); the complete text renders once when the
         * turn ends. */
        if (live_render && source.length > LIVE_TAIL_LIMIT) {
            source = streaming_tail (source);
            tail_shown = true;
        } else {
            tail_shown = false;
        }

        /* Drop whitespace-only prose: it renders no widget. */
        var blocks = BlockView.parse (source);

        if (BlockView.same_shape (rendered_blocks, blocks, block_widgets.size)) {
            /* Same shape: update labels in place so text selection
             * and focus survive streaming re-renders. Blocks whose
             * text did not change are left untouched, so a streaming
             * turn only reformats the block that is still growing. */
            for (int i = 0; i < blocks.size; i++) {
                var old_block = rendered_blocks[i];
                var new_block = blocks[i];
                if (new_block.kind != Markdown.BlockKind.TABLE
                    && old_block.text == new_block.text) {
                    continue;
                }
                BlockView.update_widget (block_widgets[i], new_block);
            }
            rendered_blocks = blocks;
            return;
        }

        Gtk.Widget? child = text_box.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            text_box.remove (child);
            child = next;
        }
        rendered_blocks.clear ();
        block_widgets.clear ();

        foreach (var block in blocks) {
            var widget = BlockView.build (block);
            text_box.append (widget);
            rendered_blocks.add (block);
            block_widgets.add (widget);
        }
        text_box.visible = text_box.get_first_child () != null;
    }

    /* -- streaming render -------------------------------------------- */

    /** Bounded view of a long answer for the coalesced streaming pass:
     *  the last paragraphs only, cut at a paragraph boundary so no
     *  fence or table is sliced in half. */
    private string streaming_tail (string full) {
        var start = full.length - LIVE_TAIL_LIMIT;
        var cut = full.last_index_of ("\n\n", (int) start);
        if (cut < start - 1) {
            cut = full.last_index_of ("\n", (int) start);
        }
        if (cut > 0 && cut + 2 < full.length) {
            return "…\n\n" + full.substring (cut + 1);
        }
        return full;
    }


    public void add_file (FileAttachment file) {
        files_seen = true;
        content.visible = true;
        files_box.append (new AttachmentView (file));
        files_box.visible = true;
    }

    /** Persistent failure line for turns the server stored with
     *  finish "error": icon + provider message, always visible. */
    private void add_history_error (string text) {
        var icon = new Gtk.Image.from_icon_name ("dialog-error") {
            pixel_size = 14,
            valign = Gtk.Align.START,
            margin_top = 2
        };
        var label = new Gtk.Label (text) {
            xalign = 0,
            wrap = true,
            wrap_mode = Pango.WrapMode.WORD_CHAR,
            selectable = true,
            hexpand = true
        };
        label.add_css_class ("chat-error-label");
        error_box.append (icon);
        error_box.append (label);
        error_box.visible = true;
    }
}

}
