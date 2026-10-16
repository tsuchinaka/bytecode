/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The user's own turn: an accent-tinted block pinned right, with the
 * "You · time" line, the text rendered as Markdown, and one
 * AttachmentView per file underneath. User turns never stream, so
 * the text renders once, in full.
 */

namespace OpenClient {

public class UserBubble : Gtk.Box {
    public string message_id { get; construct; }

    private Gtk.Box text_box;
    private Gtk.Box files_box;
    private Gtk.Box content;
    private bool files_seen = false;

    public UserBubble (Message message) {
        Object (
            message_id: message.id,
            orientation: Gtk.Orientation.VERTICAL,
            spacing: 6,
            halign: Gtk.Align.END,
            hexpand: false
        );
        if (message.created > 0) {
            var time = new DateTime.from_unix_local (message.created / 1000);
            tooltip_text = time.format ("%Y-%m-%d %H:%M");
        }

        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        content.add_css_class ("bubble");
        content.add_css_class ("user-bubble");
        this.content = content;

        var stamp = message.created > 0
            ? new DateTime.from_unix_local (message.created / 1000).format ("%H:%M")
            : "";
        var meta_label = new Gtk.Label (stamp != "" ? @"You · $stamp" : "You") {
            xalign = 1
        };
        meta_label.add_css_class ("message-meta");
        content.append (meta_label);

        var text = new StringBuilder ();
        files_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8) {
            halign = Gtk.Align.START,
            visible = false
        };
        foreach (var part in message.parts) {
            switch (part.kind) {
                case PartKind.TEXT:
                    if (part.text != "") {
                        if (text.len > 0) {
                            text.append ("\n\n");
                        }
                        text.append (part.text);
                    }
                    break;
                case PartKind.FILE:
                    if (part.file != null) {
                        add_file (part.file);
                    }
                    break;
                default:
                    break;
            }
        }

        text_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6) {
            visible = false
        };
        foreach (var block in BlockView.parse (text.str)) {
            text_box.append (BlockView.build (block));
        }
        text_box.visible = text_box.get_first_child () != null;
        content.append (text_box);

        files_box.visible = files_seen;
        content.append (files_box);
        append (content);
        content.visible = text_box.visible || files_seen;
    }

    public void add_file (FileAttachment file) {
        files_seen = true;
        files_box.append (new AttachmentView (file));
        files_box.visible = true;
        content.visible = true;
    }
}

}
