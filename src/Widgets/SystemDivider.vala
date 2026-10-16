/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * A system event in the conversation. Most are a centered rule broken
 * in the middle by a status indicator and a label, e.g.
 *
 *   ─────────────  ⠿ Compacting context…  ─────────────
 *
 * (compaction, model/agent switches, retries). When the event carried
 * a compaction summary, the rule is replaced by a folded card: header
 * (indicator, title, size, chevron) over the summary rendered as real
 * Markdown, with a one line preview while folded. The card is part of
 * the conversation rather than a raw dump hanging off the rule, and
 * only the rule dims, so the summary stays readable.
 */

namespace OpenClient {

/**
 * Spinner-or-icon indicator used by both the rule and the summary
 * card. A widget can only have one parent, so each gets its own.
 * Gtk.Stack is final in GTK 4.22, so it is wrapped by a box rather
 * than subclassed.
 */
internal class SystemIndicator : Gtk.Box {
    private Gtk.Stack stack;
    private BrailleSpinner spinner;
    private Gtk.Image icon;

    public SystemIndicator () {
        Object (
            orientation: Gtk.Orientation.HORIZONTAL,
            valign: Gtk.Align.CENTER
        );

        spinner = new BrailleSpinner ();
        icon = new Gtk.Image.from_icon_name ("dialog-information") {
            pixel_size = 14,
            valign = Gtk.Align.CENTER
        };
        stack = new Gtk.Stack () {
            transition_type = Gtk.StackTransitionType.CROSSFADE
        };
        stack.add_named (spinner, "running");
        stack.add_named (icon, "static");
        stack.visible_child_name = "static";
        append (stack);
    }

    public void set_icon (string icon_name) {
        if (icon_name != "") {
            icon.icon_name = icon_name;
        }
    }

    public void set_running (bool running) {
        if (running) {
            spinner.start ();
            stack.visible_child_name = "running";
        } else {
            spinner.stop ();
            stack.visible_child_name = "static";
        }
    }
}

public class SystemDivider : Gtk.Box {
    public string divider_id { get; construct; }

    private Gtk.CenterBox rule_row;
    private Gtk.Label title_label;
    private SystemIndicator rule_indicator;

    private Gtk.Box card;
    private Gtk.Label card_title;
    private Gtk.Label card_meta;
    private Gtk.Image chevron;
    private Gtk.Button header_button;
    private Gtk.Label preview_label;
    private Gtk.Revealer body_revealer;
    private Gtk.Label body_label;
    private SystemIndicator card_indicator;

    private StringBuilder summary_buffer = new StringBuilder ();
    /** True once the event has a summary: the card replaces the rule. */
    private bool has_summary = false;
    private bool body_expanded = false;
    /** One coalesced summary render is pending, so a streaming
     *  compaction does not re-run the Markdown pass per delta. */
    private bool summary_render_queued = false;
    private string current_status = "done";

    public SystemDivider (string divider_id, string icon_name, string text, string status) {
        Object (
            divider_id: divider_id,
            orientation: Gtk.Orientation.VERTICAL,
            spacing: 4,
            halign: Gtk.Align.FILL,
            hexpand: true
        );
        add_css_class ("system-divider");

        build_rule (text);
        build_card ();
        set_status (icon_name, text, status);
    }

    private void build_rule (string text) {
        rule_row = new Gtk.CenterBox ();
        rule_row.add_css_class ("system-divider-rule");

        var start_sep = new Gtk.Separator (Gtk.Orientation.HORIZONTAL) {
            hexpand = true,
            valign = Gtk.Align.CENTER,
            margin_end = 10
        };
        var end_sep = new Gtk.Separator (Gtk.Orientation.HORIZONTAL) {
            hexpand = true,
            valign = Gtk.Align.CENTER,
            margin_start = 10
        };

        var content = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            valign = Gtk.Align.CENTER
        };
        rule_indicator = new SystemIndicator ();

        title_label = new Gtk.Label (text) {
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 70
        };
        title_label.add_css_class ("system-divider-label");

        content.append (rule_indicator);
        content.append (title_label);

        rule_row.start_widget = start_sep;
        rule_row.center_widget = content;
        rule_row.end_widget = end_sep;
        append (rule_row);
    }

    /** Header button over a revealer holding the Markdown body. */
    private void build_card () {
        card = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        card.add_css_class ("summary-card");
        card.visible = false;

        var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
            margin_top = 8,
            margin_bottom = 8,
            margin_start = 12,
            margin_end = 12
        };

        card_indicator = new SystemIndicator ();

        card_title = new Gtk.Label ("") {
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.END
        };
        card_title.add_css_class ("summary-title");

        card_meta = new Gtk.Label ("") {
            xalign = 0,
            hexpand = true
        };
        card_meta.add_css_class ("summary-meta");

        chevron = new Gtk.Image.from_icon_name ("pan-end-symbolic") {
            valign = Gtk.Align.CENTER
        };

        header.append (card_indicator);
        header.append (card_title);
        header.append (card_meta);
        header.append (chevron);

        header_button = new Gtk.Button () {
            child = header
        };
        header_button.add_css_class ("flat");
        header_button.add_css_class ("summary-header");
        header_button.clicked.connect (() => {
            set_expanded (!body_expanded);
        });
        card.append (header_button);

        preview_label = new Gtk.Label ("") {
            xalign = 0,
            wrap = true,
            wrap_mode = Pango.WrapMode.WORD_CHAR,
            lines = 2,
            ellipsize = Pango.EllipsizeMode.END,
            visible = false,
            margin_start = 12,
            margin_end = 12,
            margin_bottom = 10
        };
        preview_label.add_css_class ("summary-preview");
        card.append (preview_label);

        body_label = new Gtk.Label ("") {
            xalign = 0,
            wrap = true,
            wrap_mode = Pango.WrapMode.WORD_CHAR,
            selectable = true
        };
        body_label.add_css_class ("summary-body");
        Markdown.wire_links (body_label);

        /* The summary takes the height it needs: it is the context the
         *  model was left with, and reading it should not mean
         *  scrolling inside a box of its own. */
        var scroller = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            vscrollbar_policy = Gtk.PolicyType.NEVER,
            propagate_natural_height = true,
            child = body_label
        };
        scroller.add_css_class ("summary-body-scroller");

        body_revealer = new Gtk.Revealer () {
            child = scroller,
            transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN,
            reveal_child = false
        };
        card.append (body_revealer);
        append (card);
    }

    public void set_status (string icon_name, string text, string status) {
        current_status = status;
        if (text != "") {
            title_label.label = text;
            card_title.label = text;
        }
        rule_indicator.set_icon (icon_name);
        card_indicator.set_icon (icon_name);
        var running = status == "running";
        rule_indicator.set_running (running);
        card_indicator.set_running (running);
        if (has_summary) {
            update_meta ();
        }
    }

    /** Streams compaction output. The card opens on the first chunk so
     *  the summary can be read as it is written. */
    public void append_summary (string delta) {
        summary_buffer.append (delta);
        if (!has_summary) {
            show_card (true);
        }
        queue_summary_render ();
    }

    /** A summary from history or a finished turn: the card takes over
     *  from the rule. */
    public void set_summary (string text) {
        summary_buffer = new StringBuilder ();
        summary_buffer.append (text);
        show_card (text.strip () != "");
        if (!has_summary) {
            return;
        }
        render_summary ();
        fold_if_settled ();
    }

    public void collapse_on_done () {
        fold_if_settled ();
    }

    /** A clean finish folds the card. A failure leaves it open, because
     *  the summary is then the error text and hiding it helps nobody. */
    private void fold_if_settled () {
        if (current_status == "done" && has_summary) {
            set_expanded (false);
        }
    }

    /** A summary makes the card the event's body: the rule goes away,
     *  so a compaction reads as one block instead of a rule with a
     *  dump strapped under it. */
    private void show_card (bool visible) {
        has_summary = visible;
        card.visible = visible;
        rule_row.visible = !visible;
        set_expanded (visible);
    }

    private void set_expanded (bool expanded) {
        body_expanded = expanded;
        body_revealer.reveal_child = expanded;
        chevron.icon_name = expanded ? "pan-down-symbolic" : "pan-end-symbolic";
        preview_label.visible = has_summary && !expanded && preview_label.label != "";
        header_button.tooltip_text = expanded ? "Hide summary" : "Show summary";
    }

    private void queue_summary_render () {
        if (summary_render_queued) {
            return;
        }
        summary_render_queued = true;
        GLib.Idle.add (() => {
            summary_render_queued = false;
            render_summary ();
            return false;
        });
    }

    private void render_summary () {
        var text = summary_buffer.str;
        body_label.set_markup (Markdown.to_pango (text));
        preview_label.label = preview_text (text);
        preview_label.visible = !body_expanded && preview_label.label != "";
        update_meta ();
    }

    private void update_meta () {
        if (!has_summary) {
            card_meta.label = "";
            return;
        }
        if (current_status == "running") {
            card_meta.label = "Writing summary…";
            return;
        }
        /* Word count reads as "how much was compacted" where a byte
         *  size only reads as a file property. */
        var words = word_count (summary_buffer.str);
        card_meta.label = words == 1 ? "1 word" : "%d words".printf (words);
    }

    private static int word_count (string text) {
        int words = 0;
        bool in_word = false;
        for (int i = 0; i < text.length; i++) {
            char c = text[i];
            if (c == ' ' || c == '\n' || c == '\t' || c == '\r') {
                in_word = false;
            } else if (!in_word) {
                in_word = true;
                words++;
            }
        }
        return words;
    }

    /** First readable line of the summary, markers stripped: headings
     *  and blank lines are skipped so the folded card says what the
     *  summary is about instead of showing "## Objective". */
    private static string preview_text (string text) {
        const string[] BULLETS = { "- ", "* ", "+ " };
        foreach (var raw in text.split ("\n")) {
            var line = raw.strip ();
            if (line == "" || is_heading (line)) {
                continue;
            }
            if (line.has_prefix (">")) {
                line = line.substring (1).strip ();
            }
            foreach (var bullet in BULLETS) {
                if (line.has_prefix (bullet)) {
                    line = line.substring (bullet.length).strip ();
                    break;
                }
            }
            line = line.replace ("**", "").replace ("`", "").replace ("~~", "").replace ("*", "");
            if (line == "") {
                continue;
            }
            return line.length > 160 ? line.substring (0, 160) + "…" : line;
        }
        return "";
    }

    private static bool is_heading (string stripped) {
        int level = 0;
        while (level < stripped.length && stripped[level] == '#') {
            level++;
        }
        return level > 0 && level <= 6 && level < stripped.length && stripped[level] == ' ';
    }
}

}
