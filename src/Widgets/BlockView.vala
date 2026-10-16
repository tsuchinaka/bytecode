/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Builds chat text widgets from Markdown blocks. One place owns the
 * mapping from block to widget, so user and assistant bubbles render
 * the same Markdown the same way: prose and quotes as markup labels,
 * code as a labelled block, tables as grids, rules as separators.
 *
 * Widgets built here carry css classes ("md-code-lang",
 * "md-code-body") that update_widget uses to refresh them in place,
 * so streaming re-renders keep text selection and focus instead of
 * rebuilding the tree.
 */

namespace OpenClient {

public class BlockView : GLib.Object {
    /** Parsed blocks with whitespace-only prose dropped: it renders
     *  no widget. */
    public static Gee.ArrayList<Markdown.Block> parse (string source) {
        var blocks = new Gee.ArrayList<Markdown.Block> ();
        foreach (var block in Markdown.to_blocks (source)) {
            if (block.kind == Markdown.BlockKind.PROSE && block.text.strip () == "") {
                continue;
            }
            blocks.add (block);
        }
        return blocks;
    }

    public static Gtk.Widget build (Markdown.Block block) {
        switch (block.kind) {
            case Markdown.BlockKind.TABLE:
                if (block.table != null) {
                    return build_table (block.table);
                }
                return make_markup_label ("");
            case Markdown.BlockKind.QUOTE:
                var quote = make_markup_label (Markdown.to_pango (block.text.strip ()));
                quote.add_css_class ("md-quote");
                return quote;
            case Markdown.BlockKind.CODE:
                return build_code (block);
            case Markdown.BlockKind.SEPARATOR:
                return new Gtk.Separator (Gtk.Orientation.HORIZONTAL);
            default:
                return make_markup_label (Markdown.to_pango (block.text.strip ()));
        }
    }

    /** Refreshes a widget built by build() for a changed block.
     *  Blocks whose text did not change are left untouched by the
     *  caller, so a streaming turn only reformats the block that is
     *  still growing. */
    public static void update_widget (Gtk.Widget widget, Markdown.Block block) {
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

    /** Same widget shape: same count, same kinds, same table dims.
     *  widget_count is the live widget list's length, so a caller
     *  whose widgets drifted from its blocks rebuilds instead of
     *  updating the wrong rows. */
    public static bool same_shape (Gee.ArrayList<Markdown.Block> old_blocks,
        Gee.ArrayList<Markdown.Block> new_blocks, int widget_count) {
        if (old_blocks.size != new_blocks.size || widget_count != old_blocks.size) {
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

    public static Gtk.Label make_markup_label (string markup) {
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

    private static Gtk.Label make_table_cell (string raw, int align, bool header) {
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

    private static Gtk.Box build_code (Markdown.Block block) {
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

    private static Gtk.Grid build_table (Markdown.TableData table) {
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
}

}
