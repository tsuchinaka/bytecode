/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * One attachment in a chat bubble: a chip that becomes the picture
 * once it decodes, with the file's name under it either way. A
 * decodable image swaps the chip for the picture and keeps the name,
 * so an attachment is never an unlabelled box, and never an empty
 * space when a decode fails.
 */

namespace OpenClient {

public class AttachmentView : Gtk.Box {
    /** Widest a preview is drawn (and decoded) at. */
    public const int PREVIEW_PX = 320;

    private Gtk.Label? caption = null;

    public AttachmentView (FileAttachment file) {
        Object (
            orientation: Gtk.Orientation.VERTICAL,
            spacing: 4,
            halign: Gtk.Align.START
        );
        append (file_chip (file));

        if (file.is_image) {
            caption = new Gtk.Label (file.display_name) {
                xalign = 0,
                visible = false
            };
            caption.add_css_class (Granite.CssClass.DIM);
            caption.add_css_class ("caption");
            caption.add_css_class ("attachment-caption");
            append (caption);
        }

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
            /* Swap the chip out of this same block, so several
             *  attachments hold the order they were sent in. */
            var chip = get_first_child ();
            if (chip != null) {
                remove (chip);
            }
            prepend (picture);
            if (caption != null) {
                caption.visible = true;
            }
            debug ("attachment %s: swapped in %dx%d", file.display_name, pixbuf.width, pixbuf.height);
        });
    }

    private static Gtk.Widget file_chip (FileAttachment file) {
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
}

}
