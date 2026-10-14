/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Minimal Markdown -> Pango markup converter.
 *
 * Supports: fenced code blocks (with language), inline code,
 * **bold**, *italic*, ~~strike~~, [links](https://…), bare URLs,
 * headings, bullet/task/ordered lists, blockquotes, horizontal
 * rules and GFM tables. Tables render two ways: to_pango() keeps
 * an aligned-monospace fallback (used for reasoning bodies),
 * while to_blocks() exposes structured content so chat bubbles
 * can build real widgets (grids, quote blocks, code blocks).
 * Everything is escaped first, so the output is always valid
 * Pango markup. Single `_` is left alone so snake_case survives.
 */

namespace OpenClient {

public class Markdown : GLib.Object {

    /** Structured GFM table: header labels, per-column alignment
     *  (0 = left, 1 = center, 2 = right) and body rows. */
    public class TableData : GLib.Object {
        public Gee.ArrayList<string> header;
        public Gee.ArrayList<int> aligns;
        public Gee.ArrayList<Gee.ArrayList<string>> rows;

        public TableData () {
            header = new Gee.ArrayList<string> ();
            aligns = new Gee.ArrayList<int> ();
            rows = new Gee.ArrayList<Gee.ArrayList<string>> ();
        }

        public int columns {
            get {
                var cols = header.size;
                foreach (var row in rows) {
                    cols = int.max (cols, row.size);
                }
                return cols;
            }
        }

        public string cell (int row, int col) {
            if (row < 0 || row >= rows.size) {
                return "";
            }
            var cells = rows[row];
            return col < cells.size ? cells[col] : "";
        }

        public string header_cell (int col) {
            return col < header.size ? header[col] : "";
        }

        public int align_for (int col) {
            return col < aligns.size ? aligns[col] : 0;
        }
    }

    /** One renderable chunk: prose, a structured table, a quote,
     *  a fenced code block or a horizontal rule. */
    public enum BlockKind {
        PROSE,
        TABLE,
        QUOTE,
        CODE,
        SEPARATOR
    }

    public class Block : GLib.Object {
        public BlockKind kind = BlockKind.PROSE;
        public string text = "";
        public string lang = "";
        public TableData? table = null;

        public bool is_table {
            get {
                return kind == BlockKind.TABLE;
            }
        }
    }

    /** Splits markdown into prose chunks, structured tables, quotes,
     *  code blocks and separators. Prose chunks keep their raw text
     *  (fences excluded) and render through to_pango(). */
    public static Gee.ArrayList<Block> to_blocks (string input) {
        var blocks = new Gee.ArrayList<Block> ();
        var lines = input.split ("\n");
        var chunk = new StringBuilder ();
        string? code_lang = null;
        var code = new StringBuilder ();

        for (int i = 0; i < lines.length; i++) {
            var line = lines[i];

            if (line.has_prefix ("```")) {
                if (code_lang == null) {
                    if (chunk.len > 0) {
                        blocks.add (new Block () { text = chunk.str });
                        chunk = new StringBuilder ();
                    }
                    var spec = line.substring (3).strip ();
                    code_lang = spec.contains (" ") ? spec.substring (0, spec.index_of (" ")) : spec;
                    code = new StringBuilder ();
                } else {
                    blocks.add (new_code_block (code.str, code_lang));
                    code_lang = null;
                }
                continue;
            }

            if (code_lang != null) {
                code.append (line);
                code.append_c ('\n');
                continue;
            }

            var lstripped = line.strip ();

            if (is_separator (lstripped)) {
                if (chunk.len > 0) {
                    blocks.add (new Block () { text = chunk.str });
                    chunk = new StringBuilder ();
                }
                blocks.add (new Block () { kind = BlockKind.SEPARATOR });
                continue;
            }

            if (is_quote_line (lstripped)) {
                if (chunk.len > 0) {
                    blocks.add (new Block () { text = chunk.str });
                    chunk = new StringBuilder ();
                }
                var quote = new StringBuilder ();
                while (i < lines.length && is_quote_line (lines[i].strip ())) {
                    quote.append (quote_inner (lines[i].strip ()));
                    quote.append_c ('\n');
                    i++;
                }
                i--;
                var qtext = quote.str;
                if (qtext.has_suffix ("\n")) {
                    qtext = qtext.substring (0, qtext.length - 1);
                }
                blocks.add (new Block () { kind = BlockKind.QUOTE, text = qtext });
                continue;
            }

            if (is_table_row (line)
                && i + 1 < lines.length
                && is_table_delimiter (lines[i + 1])) {
                if (chunk.len > 0) {
                    blocks.add (new Block () { text = chunk.str });
                    chunk = new StringBuilder ();
                }
                var table = new TableData ();
                table.header.add_all (split_row (line));
                foreach (var delim in split_row (lines[i + 1])) {
                    table.aligns.add (col_align (delim));
                }
                i += 2;
                while (i < lines.length && is_table_row (lines[i])) {
                    table.rows.add (split_row (lines[i]));
                    i++;
                }
                i--;
                var block = new Block () { kind = BlockKind.TABLE };
                block.table = table;
                blocks.add (block);
                continue;
            }

            chunk.append (line);
            chunk.append_c ('\n');
        }

        if (code_lang != null) {
            blocks.add (new_code_block (code.str, code_lang));
        }
        if (chunk.len > 0) {
            blocks.add (new Block () { text = chunk.str });
        }
        return blocks;
    }

    private static Block new_code_block (string raw, string lang) {
        var text = raw;
        if (text.has_suffix ("\n")) {
            text = text.substring (0, text.length - 1);
        }
        return new Block () { kind = BlockKind.CODE, text = text, lang = lang };
    }

    private static bool is_separator (string line) {
        if (line.length < 3) {
            return false;
        }
        char c = line[0];
        if (c != '-' && c != '*' && c != '_') {
            return false;
        }
        for (int i = 1; i < line.length; i++) {
            if (line[i] != c) {
                return false;
            }
        }
        return true;
    }

    private static bool is_quote_line (string stripped) {
        return stripped.has_prefix (">");
    }

    private static string quote_inner (string stripped) {
        var inner = stripped.substring (1);
        if (inner.has_prefix (" ")) {
            inner = inner.substring (1);
        }
        return inner;
    }

    public static string to_pango (string input) {
        return format_lines (input.split ("\n"));
    }

    /** Line-oriented formatter over pre-split lines (avoids
     *  re-splitting when the caller already walks lines). */
    private static string format_lines (string[] lines) {
        var out = new StringBuilder ();
        var in_code = false;

        for (int i = 0; i < lines.length; i++) {
            var line = lines[i];

            if (line.has_prefix ("```")) {
                if (in_code) {
                    out.append ("</tt>");
                    in_code = false;
                } else {
                    if (i > 0) {
                        out.append ("\n");
                    }
                    out.append ("<tt>");
                    in_code = true;
                }
                continue;
            }

            if (in_code) {
                out.append (GLib.Markup.escape_text (line));
                if (i < lines.length - 1) {
                    out.append ("\n");
                }
                continue;
            }

            /* Fast path: plain prose with no markup metacharacters
             * skips the inline pipeline entirely (the common case). */
            if (is_plain_line (line)) {
                out.append (GLib.Markup.escape_text (line));
                if (i < lines.length - 1) {
                    out.append ("\n");
                }
                continue;
            }

            /* GFM table: header row followed by a delimiter row. */
            if (is_table_row (line)
                && i + 1 < lines.length
                && is_table_delimiter (lines[i + 1])) {
                var header = split_row (line);
                var delims = split_row (lines[i + 1]);
                i += 2;
                var body = new Gee.ArrayList<Gee.ArrayList<string>> ();
                while (i < lines.length && is_table_row (lines[i])) {
                    body.add (split_row (lines[i]));
                    i++;
                }
                i--;
                out.append (render_table (header, delims, body));
                if (i < lines.length - 1) {
                    out.append ("\n");
                }
                continue;
            }

            var lstripped = line.strip ();

            if (is_separator (lstripped)) {
                out.append ("────────────────");
                if (i < lines.length - 1) {
                    out.append ("\n");
                }
                continue;
            }

            if (is_quote_line (lstripped)) {
                out.append ("❚ " + inline_format (quote_inner (lstripped)));
                if (i < lines.length - 1) {
                    out.append ("\n");
                }
                continue;
            }

            var indent_len = line.length - lstripped.length;
            var indent = indent_len > 0 ? line.substring (0, indent_len) : "";

            int level = 0;
            while (level < lstripped.length && lstripped[level] == '#') {
                level++;
            }
            if (level > 0 && level < lstripped.length && lstripped[level] == ' ') {
                var inner = inline_format (lstripped.substring (level + 1));
                if (level == 1) {
                    out.append ("<span size=\"x-large\"><b>" + inner + "</b></span>");
                } else if (level == 2) {
                    out.append ("<span size=\"large\"><b>" + inner + "</b></span>");
                } else {
                    out.append ("<b>" + inner + "</b>");
                }
                if (i < lines.length - 1) {
                    out.append ("\n");
                }
                continue;
            }

            if (lstripped.has_prefix ("- [ ] ") || lstripped.has_prefix ("* [ ] ")) {
                out.append (indent + "☐ " + inline_format (lstripped.substring (6)));
            } else if (lstripped.has_prefix ("- [x] ") || lstripped.has_prefix ("- [X] ")
                || lstripped.has_prefix ("* [x] ") || lstripped.has_prefix ("* [X] ")) {
                out.append (indent + "☑ " + inline_format (lstripped.substring (6)));
            } else if (lstripped.has_prefix ("- ") || lstripped.has_prefix ("* ")) {
                out.append (indent + "• " + inline_format (lstripped.substring (2)));
            } else {
                out.append (inline_format (line));
            }
            if (i < lines.length - 1) {
                out.append ("\n");
            }
        }

        if (in_code) {
            out.append ("</tt>");
        }

        return out.str;
    }

    /** True when a line carries no inline markup, so escaping is the
     *  whole job. Checked with one byte scan (no allocations).
     *
     *  Conservative by design: `#` (headings), `>` (quotes) and
     *  `|` (tables) also force the markup path, because they can
     *  restructure a line even mid-paragraph. Leading whitespace is
     *  significant too (indented blocks keep it verbatim), as are
     *  blank lines (they separate paragraphs in the join). */
    private static bool is_plain_line (string line) {
        if (line.strip () == "") {
            return false;
        }
        if (line.length > 0 && (line[0] == ' ' || line[0] == '\t')) {
            return false;
        }
        for (int i = 0; i < line.length; i++) {
            var c = line[i];
            if (c == '*' || c == '`' || c == '_' || c == '~' || c == '['
                || c == '<' || c == '&' || c == '#' || c == '>' || c == '|'
                || (c == '-' && (i == 0 || line[i - 1] == ' ' || line[i - 1] == '\t'))
                || (c == 'h' && has_url_prefix (line, i))) {
                return false;
            }
        }
        return true;
    }

    /** Fixed-width prefix compare at an offset, without scanning the
     *  rest of the string (index_of() here was the quadratic term). */
    private static bool starts_with_at (string s, int i, string prefix) {
        if (i + prefix.length > s.length) {
            return false;
        }
        for (int k = 0; k < prefix.length; k++) {
            if (s[i + k] != prefix[k]) {
                return false;
            }
        }
        return true;
    }

    private static bool has_url_prefix (string line, int i) {
        return starts_with_at (line, i, "http://") || starts_with_at (line, i, "https://");
    }

    public static string inline_format (string line) {
        /* 1. Extract `code` spans first so markers inside code are
         *    never parsed (keeps the historic odd/even semantics). */
        var codes = new Gee.ArrayList<string> ();
        var parts = line.split ("`");
        var merged = new StringBuilder ();
        for (int i = 0; i < parts.length; i++) {
            if (i % 2 == 1) {
                merged.append (placeholder ("C", codes.size));
                codes.add (parts[i]);
            } else {
                merged.append (parts[i]);
            }
        }

        /* 2. Extract links, autolinks and bare URLs. */
        var labels = new Gee.ArrayList<string> ();
        var urls = new Gee.ArrayList<string> ();
        var linked = extract_links (merged.str, labels, urls);

        /* 3 + 4. Escape, then emphasis (placeholders hold no
         *    markup-significant characters). */
        var em = emphasize (GLib.Markup.escape_text (linked));

        /* 5. Restore code spans and links. */
        return restore_inline (em, codes, labels, urls);
    }

    private const string PH_OPEN = "\uE000";
    private const string PH_CLOSE = "\uE001";

    private static string placeholder (string kind, int idx) {
        return "%s%s%d%s".printf (PH_OPEN, kind, idx, PH_CLOSE);
    }

    private static bool at_placeholder_edge (string text, int i, bool open) {
        if (i + 2 >= text.length) {
            return false;
        }
        if (text[i] != (char) 0xEE || text[i + 1] != (char) 0x80) {
            return false;
        }
        char third = text[i + 2];
        return open ? third == (char) 0x80 : third == (char) 0x81;
    }

    private static bool is_space_char (char c) {
        return c == ' ' || c == '\t' || c == '\n' || c == '\r';
    }

    private static bool is_web_url (string url) {
        return url.has_prefix ("http://") || url.has_prefix ("https://");
    }

    /** Pulls [label](url), <url> and bare URLs out of the text,
     *  leaving placeholders. Only http(s) targets linkify. */
    private static string extract_links (string text, Gee.ArrayList<string> labels,
        Gee.ArrayList<string> urls) {
        var out = new StringBuilder ();
        int i = 0;           /* next candidate position */
        int plain_start = 0; /* start of the not-yet-emitted literal run */
        /* Cached next positions for each candidate character; advanced
         * only when consumed so the whole pass stays O(n) instead of
         * rescanning for '[' / '<' at every 'h'. */
        int next_bracket = (int) text.index_of_char ('[', 0);
        int next_lt = (int) text.index_of_char ('<', 0);
        int next_h = (int) text.index_of_char ('h', 0);
        while (true) {
            int next = -1;
            if (next_bracket >= 0) {
                next = next_bracket;
            }
            if (next_lt >= 0 && (next < 0 || next_lt < next)) {
                next = next_lt;
            }
            if (next_h >= 0 && (next < 0 || next_h < next)) {
                next = next_h;
            }
            if (next < 0) {
                break;
            }
            i = next;

            /* [label](url "title") */
            if (text[i] == '[') {
                int close = text.index_of ("]", i + 1);
                if (close > i + 1 && close + 1 < text.length && text[close + 1] == '(') {
                    int p = close + 2;
                    while (p < text.length && (text[p] == ' ' || text[p] == '\t')) {
                        p++;
                    }
                    int depth = 0;
                    int q = p;
                    while (q < text.length) {
                        if (text[q] == '(') {
                            depth++;
                        } else if (text[q] == ')') {
                            if (depth == 0) {
                                break;
                            }
                            depth--;
                        } else if ((text[q] == ' ' || text[q] == '\t') && depth == 0) {
                            break;
                        }
                        q++;
                    }
                    var url = text.substring (p, q - p);
                    int r = q;
                    while (r < text.length && (text[r] == ' ' || text[r] == '\t')) {
                        r++;
                    }
                    if (r < text.length && text[r] == '"') {
                        int tend = text.index_of ("\"", r + 1);
                        if (tend > 0) {
                            r = tend + 1;
                            while (r < text.length && (text[r] == ' ' || text[r] == '\t')) {
                                r++;
                            }
                        }
                    }
                    if (r < text.length && text[r] == ')' && is_web_url (url)) {
                        out.append (text.substring (plain_start, i - plain_start));
                        out.append (placeholder ("L", labels.size));
                        labels.add (text.substring (i + 1, close - (i + 1)));
                        urls.add (url);
                        i = r + 1;
                        plain_start = i;
                        refresh_candidates (text, i, ref next_bracket, ref next_lt, ref next_h);
                        continue;
                    }
                }
            }

            /* <https://…> autolink */
            if (text[i] == '<') {
                int close = text.index_of (">", i + 1);
                if (close > i + 1) {
                    var inner = text.substring (i + 1, close - (i + 1));
                    if (!inner.contains (" ") && !inner.contains ("\t") && is_web_url (inner)) {
                        out.append (text.substring (plain_start, i - plain_start));
                        out.append (placeholder ("L", labels.size));
                        labels.add (inner);
                        urls.add (inner);
                        i = close + 1;
                        plain_start = i;
                        refresh_candidates (text, i, ref next_bracket, ref next_lt, ref next_h);
                        continue;
                    }
                }
            }

            /* bare https://… URL. Guarded by the leading 'h' and a
             * fixed-width compare: a full index_of() scan at every
             * character made this loop quadratic on long lines. */
            if (text[i] == 'h'
                && (starts_with_at (text, i, "http://") || starts_with_at (text, i, "https://"))) {
                int q = i;
                while (q < text.length && !is_space_char (text[q])
                    && text[q] != '<' && text[q] != '>' && text[q] != '"' && text[q] != '`') {
                    q++;
                }
                var url = text.substring (i, q - i);
                while (url.length > 0) {
                    char last = url[url.length - 1];
                    if (last == '.' || last == ',' || last == ';' || last == ':'
                        || last == '!' || last == '?') {
                        url = url.substring (0, url.length - 1);
                    } else {
                        break;
                    }
                }
                int opens = 0;
                int closes = 0;
                for (int k = 0; k < url.length; k++) {
                    if (url[k] == '(') {
                        opens++;
                    } else if (url[k] == ')') {
                        closes++;
                    }
                }
                while (closes > opens && url.has_suffix (")")) {
                    url = url.substring (0, url.length - 1);
                    closes--;
                }
                if (url.length > 0) {
                    out.append (text.substring (plain_start, i - plain_start));
                    out.append (placeholder ("L", labels.size));
                    labels.add (url);
                    urls.add (url);
                    i += url.length;
                    plain_start = i;
                    refresh_candidates (text, i, ref next_bracket, ref next_lt, ref next_h);
                    continue;
                }
            }

            i++;
            refresh_candidates (text, i, ref next_bracket, ref next_lt, ref next_h);
        }
        out.append (text.substring (plain_start));
        return out.str;
    }

    /** Advances the cached candidate positions past `i`. */
    private static void refresh_candidates (string text, int i,
        ref int next_bracket, ref int next_lt, ref int next_h) {
        if (next_bracket >= 0 && next_bracket < i) {
            next_bracket = (int) text.index_of_char ('[', i);
        }
        if (next_lt >= 0 && next_lt < i) {
            next_lt = (int) text.index_of_char ('<', i);
        }
        if (next_h >= 0 && next_h < i) {
            next_h = (int) text.index_of_char ('h', i);
        }
    }

    /** Emphasis on escaped text: **bold**, *italic*, ~~strike~~,
     *  ***bold italic***. Markers pair up (opener needs text after it,
     *  closer needs text before it); unpaired markers stay literal.
     *  Single `_` is deliberately left alone so snake_case survives. */
    private static string emphasize (string text) {
        /* Triple first so it does not leave crossed <b><i>…</b></i>
         * tags (which Pango rejects) for the later passes. */
        var t = pair_replace (text, "***", "<b><i>", "</i></b>", false);
        t = pair_replace (t, "**", "<b>", "</b>", false);
        t = pair_replace (t, "~~", "<s>", "</s>", false);
        t = pair_replace (t, "*", "<i>", "</i>", true);
        return t;
    }

    private static bool marker_at (string text, int i, string marker, bool skip_doubles) {
        int mlen = marker.length;
        if (!starts_with_at (text, i, marker)) {
            return false;
        }
        if (skip_doubles) {
            if (i + mlen < text.length && text[i + mlen] == marker[0]) {
                return false;
            }
            if (i > 0 && text[i - 1] == marker[0]) {
                return false;
            }
        }
        return true;
    }

    private static string pair_replace (string text, string marker, string open_tag,
        string close_tag, bool skip_doubles) {
        int mlen = marker.length;
        var out = new StringBuilder ();
        int i = 0;           /* next position to look for a marker from */
        int plain_start = 0; /* start of the not-yet-emitted literal run */
        while (true) {
            /* Jump marker to marker with a C-level scan; walking the
             * string one character at a time was the hot loop. */
            int m = text.index_of (marker, i);
            if (m < 0) {
                break;
            }
            if (marker_at (text, m, marker, skip_doubles)
                && m + mlen < text.length && !is_space_char (text[m + mlen])) {
                int found = -1;
                int j = text.index_of (marker, m + mlen);
                while (j >= 0) {
                    if (marker_at (text, j, marker, skip_doubles)
                        && j > 0 && !is_space_char (text[j - 1])) {
                        found = j;
                        break;
                    }
                    j = text.index_of (marker, j + 1);
                }
                if (found >= 0) {
                    out.append (text.substring (plain_start, m - plain_start));
                    out.append (open_tag);
                    out.append (text.substring (m + mlen, found - (m + mlen)));
                    out.append (close_tag);
                    i = found + mlen;
                    plain_start = i;
                    continue;
                }
                /* No valid closer after this opener: none can exist
                 * for any later opener either, so the rest is literal. */
                break;
            }
            i = m + 1;
        }
        out.append (text.substring (plain_start));
        return out.str;
    }

    /** Link labels get emphasis but no nested link parsing; code
     *  spans inside labels are restored here. */
    private static string format_label (string raw, Gee.ArrayList<string> codes) {
        var em = emphasize (GLib.Markup.escape_text (raw));
        return restore_inline (em, codes,
            new Gee.ArrayList<string> (), new Gee.ArrayList<string> ());
    }

    private static string restore_inline (string text, Gee.ArrayList<string> codes,
        Gee.ArrayList<string> labels, Gee.ArrayList<string> urls) {
        var out = new StringBuilder ();
        int i = 0;           /* next candidate position */
        int plain_start = 0; /* start of the not-yet-emitted literal run */
        while (i < text.length) {
            int e = text.index_of (PH_OPEN, i);
            if (e < 0) {
                break;
            }
            i = e;
            if (at_placeholder_edge (text, i, true)) {
                int j = i + 3;
                while (j < text.length && !at_placeholder_edge (text, j, false)) {
                    j++;
                }
                if (j < text.length) {
                    var tag = text.substring (i + 3, j - (i + 3));
                    var kind = tag.substring (0, 1);
                    var idx = int.parse (tag.substring (1));
                    if (kind == "C" && idx >= 0 && idx < codes.size) {
                        out.append (text.substring (plain_start, i - plain_start));
                        out.append ("<tt>");
                        out.append (GLib.Markup.escape_text (codes[idx]));
                        out.append ("</tt>");
                        i = j + 3;
                        plain_start = i;
                        continue;
                    }
                    if (kind == "L" && idx >= 0 && idx < labels.size && idx < urls.size) {
                        out.append (text.substring (plain_start, i - plain_start));
                        out.append ("<a href=\"");
                        out.append (GLib.Markup.escape_text (urls[idx]));
                        out.append ("\">");
                        out.append (format_label (labels[idx], codes));
                        out.append ("</a>");
                        i = j + 3;
                        plain_start = i;
                        continue;
                    }
                }
            }
            i++;
        }
        out.append (text.substring (plain_start));
        return out.str;
    }

    /** Wires <a href> clicks on a label to the system browser.
     *  Non-http(s) targets are swallowed, never launched. */
    public static void wire_links (Gtk.Label label) {
        label.activate_link.connect ((uri) => {
            if (!is_web_url (uri)) {
                return true;
            }
            var launcher = new Gtk.UriLauncher (uri);
            var root = label.get_root ();
            Gtk.Window? parent = null;
            if (root is Gtk.Window) {
                parent = (Gtk.Window) root;
            }
            launcher.launch.begin (parent, null,
                (obj, res) => {
                    try {
                        launcher.launch.end (res);
                    } catch (Error e) {
                        warning ("Could not open link: %s", e.message);
                    }
                });
            return true;
        });
    }

    /* -- tables ----------------------------------------------------- */

    private static bool is_table_row (string line) {
        return line.strip ().contains ("|");
    }

    private static bool is_table_delimiter (string line) {
        var t = line.strip ();
        if (!t.contains ("|") || !t.contains ("-")) {
            return false;
        }
        for (int i = 0; i < t.length; i++) {
            var c = t[i];
            if (c != '|' && c != '-' && c != ':' && c != ' ' && c != '\t') {
                return false;
            }
        }
        return true;
    }

    private static Gee.ArrayList<string> split_row (string line) {
        var cells = new Gee.ArrayList<string> ();
        var t = line.strip ();
        if (t.has_prefix ("|")) {
            t = t.substring (1);
        }
        if (t.has_suffix ("|")) {
            t = t.substring (0, t.length - 1);
        }
        foreach (var part in t.split ("|")) {
            cells.add (part.strip ());
        }
        return cells;
    }

    /** Rough visible width: markdown markers don't take space. */
    private static int cell_width (string cell) {
        return cell.replace ("**", "").replace ("`", "").char_count ();
    }

    private static string spaces (int n) {
        var sb = new StringBuilder ();
        for (int i = 0; i < n; i++) {
            sb.append_c (' ');
        }
        return sb.str;
    }

    /** 0 = left, 1 = center, 2 = right (from the delimiter row). */
    private static int col_align (string delim) {
        var d = delim.strip ();
        bool left = d.has_prefix (":");
        bool right = d.has_suffix (":");
        if (left && right) {
            return 1;
        }
        if (right) {
            return 2;
        }
        return 0;
    }

    private static string render_table_row (Gee.ArrayList<string> cells, int[] widths, int[] aligns) {
        var out = new StringBuilder ();
        out.append ("| ");
        for (int i = 0; i < widths.length; i++) {
            if (i > 0) {
                out.append (" | ");
            }
            var raw = i < cells.size ? cells[i] : "";
            var pad = widths[i] - cell_width (raw);
            if (pad < 0) {
                pad = 0;
            }
            string before = "";
            string after = "";
            if (aligns[i] == 1) {
                before = spaces (pad / 2);
                after = spaces (pad - pad / 2);
            } else if (aligns[i] == 2) {
                before = spaces (pad);
            } else {
                after = spaces (pad);
            }
            out.append (before);
            out.append (inline_format (raw));
            out.append (after);
        }
        out.append (" |");
        return out.str;
    }

    private static string render_table (Gee.ArrayList<string> header, Gee.ArrayList<string> delims,
        Gee.ArrayList<Gee.ArrayList<string>> body) {
        var cols = int.max (header.size, delims.size);
        foreach (var row in body) {
            cols = int.max (cols, row.size);
        }

        var widths = new int[cols];
        var aligns = new int[cols];
        for (int i = 0; i < cols; i++) {
            widths[i] = 3;
            aligns[i] = i < delims.size ? col_align (delims[i]) : 0;
            if (i < header.size) {
                widths[i] = int.max (widths[i], cell_width (header[i]));
            }
        }
        foreach (var row in body) {
            for (int i = 0; i < cols && i < row.size; i++) {
                widths[i] = int.max (widths[i], cell_width (row[i]));
            }
        }

        var out = new StringBuilder ();
        out.append ("<tt>");
        out.append (render_table_row (header, widths, aligns));
        out.append ("\n|");
        for (int i = 0; i < cols; i++) {
            if (i > 0) {
                out.append ("|");
            }
            if (aligns[i] == 1) {
                out.append (":");
                for (int k = 0; k < widths[i]; k++) {
                    out.append ("-");
                }
                out.append (":");
            } else if (aligns[i] == 2) {
                for (int k = 0; k < widths[i] + 1; k++) {
                    out.append ("-");
                }
                out.append (":");
            } else {
                out.append ("-");
                for (int k = 0; k < widths[i]; k++) {
                    out.append ("-");
                }
            }
        }
        out.append ("|");
        foreach (var row in body) {
            out.append ("\n");
            out.append (render_table_row (row, widths, aligns));
        }
        out.append ("</tt>");
        return out.str;
    }
}

}
