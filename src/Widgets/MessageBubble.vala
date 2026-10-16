/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * A single chat message. User turns are accent-tinted blocks pinned
 * right; assistant answers are flat full-width text (T3-style) with
 * rich tool cards and attachment blocks.
 *
 * Thinking lives OUTSIDE the bubble in a flat ReasoningBubble above
 * it, so thoughts never mix with the answer or the actions.
 *
 * Streaming renders are coalesced: deltas accumulate in the buffer
 * and the expensive Markdown pass runs at most once per main-loop
 * idle round, with a final full render on completion.
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
        bool is_user = message.role == MessageRole.USER;
        Object (
            message_id: message.id,
            orientation: Gtk.Orientation.VERTICAL,
            spacing: 6,
            halign: is_user ? Gtk.Align.END : Gtk.Align.FILL,
            hexpand: !is_user
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
            hexpand = !is_user
        };
        if (is_user) {
            content.add_css_class ("bubble");
            content.add_css_class ("user-bubble");
        } else {
            content.add_css_class ("assistant-bubble");
        }

        meta_label = new Gtk.Label (message.role == MessageRole.USER ? "You" : "Assistant") {
            xalign = message.role == MessageRole.USER ? 1 : 0,
            visible = false
        };
        meta_label.add_css_class ("message-meta");
        var stamp = message.created > 0
            ? new DateTime.from_unix_local (message.created / 1000).format ("%H:%M")
            : "";
        if (message.role == MessageRole.USER) {
            meta_label.label = stamp != "" ? @"You · $stamp" : "You";
            meta_label.visible = true;
        } else {
            var model = message.model;
            meta_label.label = model != "" ? @"Assistant · $model" : "Assistant";
            meta_label.visible = true;
        }

        live = new LiveStatus ();
        reasoning = new ReasoningBubble ();
        tool_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        tool_box.visible = false;

        /* One block per attachment: a chip that becomes the picture
         *  when it decodes, with the file's name underneath either
         *  way. Never an unlabelled box, never an empty space. */
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

        /* Preserve the model's part order: text-first turns read
         *  text-first instead of always tools-first. Files trail. */
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
        content.append (meta_label);
        if (first_text >= 0 && (first_tool < 0 || first_text < first_tool)) {
            content.append (text_box);
            content.append (tool_box);
        } else {
            content.append (tool_box);
            content.append (text_box);
        }
        content.append (files_box);
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

    /* -- rendering --------------------------------------------- */

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

        if (live_render && source.length > LIVE_TAIL_LIMIT) {
            source = streaming_tail (source);
            tail_shown = true;
        } else {
            tail_shown = false;
        }

        var blocks = new Gee.ArrayList<Markdown.Block> ();
        foreach (var block in Markdown.to_blocks (source)) {
            if (block.kind == Markdown.BlockKind.PROSE && block.text.strip () == "") {
                continue;
            }
            blocks.add (block);
        }

        if (same_blocks (rendered_blocks, blocks)) {
            for (int i = 0; i < blocks.size; i++) {
                var old_block = rendered_blocks[i];
                var new_block = blocks[i];
                if (new_block.kind != Markdown.BlockKind.TABLE
                    && old_block.text == new_block.text) {
                    continue;
                }
                update_block_widget (block_widgets[i], new_block);
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
            Gtk.Widget widget;
            switch (block.kind) {
                case Markdown.BlockKind.TABLE:
                    if (block.table != null) {
                        widget = build_table (block.table);
                    } else {
                        widget = make_markup_label ("");
                    }
                    break;
                case Markdown.BlockKind.QUOTE:
                    widget = make_markup_label (Markdown.to_pango (block.text.strip ()));
                    widget.add_css_class ("md-quote");
                    break;
                case Markdown.BlockKind.CODE:
                    widget = build_code (block);
                    break;
                case Markdown.BlockKind.SEPARATOR:
                    widget = new Gtk.Separator (Gtk.Orientation.HORIZONTAL);
                    break;
                default:
                    widget = make_markup_label (Markdown.to_pango (block.text.strip ()));
                    break;
            }
            text_box.append (widget);
            rendered_blocks.add (block);
            block_widgets.add (widget);
        }
        text_box.visible = text_box.get_first_child () != null;
    }

    /* -- streaming render -------------------------------------- */

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

    private bool same_blocks (Gee.ArrayList<Markdown.Block> old_blocks,
        Gee.ArrayList<Markdown.Block> new_blocks) {
        if (old_blocks.size != new_blocks.size || block_widgets.size != old_blocks.size) {
            return false;
        }
        for (int i = 0; i < new_blocks.size; i++) {
            var a = old_blocks[i];
            var b = new_blocks[i];
            if (a.kind != b.kind) {
                return false;
            }
            if (b.kind == Markdown.BlockKind.TABLE) {
                if (a.table == null || b.table == null) {
                    return false;
                }
                if (a.table.columns != b.table.columns
                    || a.table.rows.size != b.table.rows.size) {
                    return false;
                }
            }
        }
        return true;
    }

    private Gtk.Label make_markup_label (string markup) {
        var label = new Gtk.Label ("") {
            xalign = 0,
            wrap = true,
            wrap_mode = Pango.WrapMode.WORD_CHAR,
            selectable = true,
            max_width_chars = 90
        };
        label.set_markup (markup);
        Markdown.wire_links (label);
        return label;
    }

    private void update_block_widget (Gtk.Widget widget, Markdown.Block block) {
        if (block.kind == Markdown.BlockKind.TABLE && block.table != null && widget is Gtk.Grid) {
            var grid = (Gtk.Grid) widget;
            var table = block.table;
            for (int c = 0; c < table.columns; c++) {
                var head = grid.get_child_at (c, 0);
                if (head is Gtk.Label) {
                    ((Gtk.Label) head).set_markup (Markdown.inline_format (table.header_cell (c)));
                }
                for (int r = 0; r < table.rows.size; r++) {
                    var cell = grid.get_child_at (c, r + 1);
                    if (cell is Gtk.Label) {
                        ((Gtk.Label) cell).set_markup (Markdown.inline_format (table.cell (r, c)));
                    }
                }
            }
            return;
        }
        if (block.kind == Markdown.BlockKind.CODE && widget is Gtk.Box) {
            var box = (Gtk.Box) widget;
            for (var c = box.get_first_child (); c != null; c = c.get_next_sibling ()) {
                if (c.has_css_class ("md-code-lang") && c is Gtk.Label) {
                    ((Gtk.Label) c).label = block.lang.strip ();
                } else if (c.has_css_class ("md-code-body") && c is Gtk.Label) {
                    ((Gtk.Label) c).set_markup ("<tt>" + GLib.Markup.escape_text (block.text) + "</tt>");
                }
            }
            return;
        }
        if (block.kind == Markdown.BlockKind.QUOTE && widget is Gtk.Label) {
            ((Gtk.Label) widget).set_markup (Markdown.to_pango (block.text.strip ()));
        } else if (block.kind == Markdown.BlockKind.PROSE && widget is Gtk.Label) {
            ((Gtk.Label) widget).set_markup (Markdown.to_pango (block.text.strip ()));
        }
    }

    private Gtk.Label make_table_cell (string raw, int align, bool header) {
        var label = new Gtk.Label ("") {
            xalign = align == 1 ? 0.5f : (align == 2 ? 1.0f : 0.0f),
            halign = Gtk.Align.FILL,
            wrap = true,
            wrap_mode = Pango.WrapMode.WORD_CHAR,
            selectable = true,
            max_width_chars = 40
        };
        label.set_markup (Markdown.inline_format (raw));
        Markdown.wire_links (label);
        label.add_css_class ("md-table-cell");
        if (header) {
            label.add_css_class ("md-table-header");
        }
        return label;
    }

    private Gtk.Box build_code (Markdown.Block block) {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
        var lang = block.lang.strip ();
        if (lang != "") {
            var lang_label = new Gtk.Label (lang) {
                xalign = 0
            };
            lang_label.add_css_class ("md-code-lang");
            box.append (lang_label);
        }
        var body = new Gtk.Label ("") {
            xalign = 0,
            wrap = true,
            wrap_mode = Pango.WrapMode.WORD_CHAR,
            selectable = true
        };
        body.add_css_class ("tool-output");
        body.add_css_class (Granite.CssClass.MONOSPACE);
        body.add_css_class ("md-code-body");
        body.set_markup ("<tt>" + GLib.Markup.escape_text (block.text) + "</tt>");
        box.append (body);
        return box;
    }

    private Gtk.Grid build_table (Markdown.TableData table) {
        var grid = new Gtk.Grid () {
            column_spacing = 0,
            row_spacing = 0,
            halign = Gtk.Align.START
        };
        grid.add_css_class ("md-table");

        var cols = table.columns;
        for (int c = 0; c < cols; c++) {
            grid.attach (make_table_cell (table.header_cell (c), table.align_for (c), true), c, 0, 1, 1);
        }
        for (int r = 0; r < table.rows.size; r++) {
            for (int c = 0; c < cols; c++) {
                grid.attach (make_table_cell (table.cell (r, c), table.align_for (c), false), c, r + 1, 1, 1);
            }
        }
        return grid;
    }

    /* -- attachments ------------------------------------------- */

    public void add_file (FileAttachment file) {
        files_seen = true;
        content.visible = true;

        var block = new Gtk.Box (Gtk.Orientation.VERTICAL, 4) {
            halign = Gtk.Align.START
        };
        block.append (file_chip (file));

        Gtk.Label? caption = null;
        if (file.is_image) {
            caption = new Gtk.Label (file.display_name) {
                xalign = 0,
                visible = false
            };
            caption.add_css_class (Granite.CssClass.DIM);
            caption.add_css_class ("caption");
            caption.add_css_class ("attachment-caption");
            block.append (caption);
        }

        files_box.append (block);
        files_box.visible = true;

        if (!file.is_image) {
            return;
        }
        debug ("attachment %s: decoding", file.display_name);
        file.load_pixbuf_async.begin (PREVIEW_PX, (obj, res) => {
            var pixbuf = file.load_pixbuf_async.end (res);
            if (pixbuf == null) {
                debug ("attachment %s: kept as a chip (no pixbuf)", file.display_name);
                return;
            }
            var picture = new Gtk.Picture.for_paintable (pixbuf_texture (pixbuf)) {
                halign = Gtk.Align.START,
                width_request = int.min (PREVIEW_PX, pixbuf.width),
                tooltip_text = file.display_name
            };
            picture.add_css_class ("attachment-image");
            var chip = block.get_first_child ();
            if (chip != null) {
                block.remove (chip);
            }
            block.prepend (picture);
            if (caption != null) {
                caption.visible = true;
            }
            files_box.visible = true;
            debug ("attachment %s: swapped in %dx%d", file.display_name, pixbuf.width, pixbuf.height);
        });
    }

    private Gtk.Widget file_chip (FileAttachment file) {
        var chip = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        chip.add_css_class ("attachment-chip");
        var icon = new Gtk.Image.from_icon_name (file.is_image ? "image-x-generic" : "text-x-generic") {
            pixel_size = 16
        };
        var label = new Gtk.Label (file.display_name) {
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.MIDDLE,
            max_width_chars = 28
        };
        chip.append (icon);
        chip.append (label);
        chip.tooltip_text = file.uri;
        return chip;
    }

    /** Widest an attachment preview is drawn (and decoded) at. */
    private const int PREVIEW_PX = 320;

    /* -- live tools -------------------------------------------- */

    public void set_model (string model) {
        meta_label.label = @"Assistant · $model";
    }

    public void set_reasoning (string text) {
        reasoning.set_reasoning (text);
    }

    public void finish_reasoning (string duration_label) {
        reasoning.finish_reasoning (duration_label);
    }

    public void append_text (string delta) {
        text_buffer.append (delta);
        text_seen = true;
        schedule_render (true);
    }

    public void append_reasoning (string delta) {
        reasoning.append_reasoning (delta);
    }

    public void set_text (string text) {
        text_buffer = new StringBuilder ();
        text_buffer.append (text);
        text_seen = true;
        tail_shown = false;
        last_rendered = "";
        render_text ();
        schedule_render (false);
    }

    public void tool_started (string call_id, string tool_name) {
        tools_seen = true;
        content.visible = true;
        var card = new ToolCard (tool_name);
        tool_cards[call_id] = card;
        tool_box.append (card);
        live_tools[call_id] = "";
        live_tool_names[call_id] = tool_name;
        live_tool_order.add (call_id);
        update_live ();
    }

    public void tool_input (string call_id, string summary) {
        if (tool_cards.has_key (call_id)) {
            tool_cards[call_id].set_input_summary (summary);
        }
        live_tools[call_id] = summary;
        update_live ();
    }

    public void tool_done (string call_id, string output,
        Gee.ArrayList<FileAttachment>? files, bool error = false) {
        tools_seen = true;
        content.visible = true;
        if (tool_cards.has_key (call_id)) {
            var card = tool_cards[call_id];
            card.set_output (output, files);
            card.set_status (error ? ToolStatus.ERROR : ToolStatus.DONE);
        } else {
            var card = new ToolCard (live_tool_names.has_key (call_id)
                ? live_tool_names[call_id] : "tool");
            card.set_output (output, files);
            card.set_status (error ? ToolStatus.ERROR : ToolStatus.DONE);
            tool_cards[call_id] = card;
            tool_box.append (card);
        }
        if (files != null) {
            foreach (var file in files) {
                add_file (file);
            }
        }
        live_tool_order.remove (call_id);
        update_live ();
    }

    public void finish_live () {
        foreach (var card in tool_cards.values) {
            card.set_status (ToolStatus.DONE);
        }
        live.hide_status ();
    }

    private void update_live () {
        if (live_tool_order.size == 0) {
            live.hide_status ();
            return;
        }
        var last = live_tool_order[live_tool_order.size - 1];
        live.set_activity (live_tool_names[last]);
        live.visible = true;
    }

    private void schedule_render (bool live) {
        if (text_render_source != 0) {
            return;
        }
        live_render = live;
        uint delay = live && text_buffer.len > FAST_LIMIT ? SLOW_DELAY_MS : 0;
        text_render_source = GLib.Timeout.add (delay, () => {
            text_render_source = 0;
            render_text ();
            return GLib.Source.REMOVE;
        });
    }

    /* -- history ----------------------------------------------- */

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
        text_buffer = new StringBuilder ();
        text_buffer.append (collapsed_full_text);
        collapsed_full_text = null;
        last_rendered = "";
        tail_shown = false;
        render_text ();
        if (show_more_button != null && show_more_button.get_parent () != null) {
            content.remove (show_more_button);
        }
        show_more_button = null;
    }

    /* -- tools ------------------------------------------------- */

    private void add_history_tool (MessagePart part) {
        tools_seen = true;
        content.visible = true;
        var card = new ToolCard (part.tool_name);
        card.set_input_summary (part.tool_input_summary);
        card.set_output (part.tool_output);
        card.set_status (part.tool_status == "error" ? ToolStatus.ERROR : ToolStatus.DONE);
        tool_cards[part.tool_id] = card;
        tool_box.append (card);
    }

    private void add_history_error (string text) {
        var icon = new Gtk.Image.from_icon_name ("dialog-error") {
            pixel_size = 14,
            valign = Gtk.Align.START,
            margin_top = 2
        };
        var label = new Gtk.Label (text) {
            xalign = 0
        };
        label.add_css_class ("chat-error-label");
        error_box.append (icon);
        error_box.append (label);
        error_box.visible = true;
        content.visible = true;
    }
}

}
