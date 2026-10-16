/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Vala-side declarations for the C shims in gtk-compat.c.
 *
 * GTK 4.22 declares several array parameters as const-qualified
 * (`const char * const *`) and a few widget parameters as their base
 * type; Vala 0.56 emits a plain `gchar **` / the derived type for
 * those, and GCC 14 rejects the mismatch with a warning that cannot
 * be switched off. Each function here forwards to the real GTK
 * function through the cast in gtk-compat.c, so the generated C
 * matches the prototype again.
 */

namespace OpenClient {

[CCode (cname = "openclient_alert_dialog_set_buttons")]
internal extern void set_alert_buttons (Gtk.AlertDialog dialog, string[] labels);

[CCode (cname = "openclient_application_set_accels_for_action")]
internal extern void set_action_accels (Gtk.Application app, string action, string[] accels);

[CCode (cname = "openclient_menu_button_set_popover")]
internal extern void set_menu_popover (Gtk.MenuButton button, Gtk.Widget popover);

[CCode (cname = "openclient_drop_down_new_from_strings")]
internal extern Gtk.Widget drop_down_new_from_strings (string[] strings);

[CCode (cname = "openclient_clipboard_read_mime")]
internal extern void clipboard_read_mime (Gdk.Clipboard clipboard,
    string mime_type,
    int io_priority,
    GLib.Cancellable? cancellable,
    ClipboardReadJob job);

[CCode (cname = "openclient_clipboard_read_finish")]
internal extern GLib.InputStream clipboard_read_finish_raw (Gdk.Clipboard clipboard,
    GLib.AsyncResult result, out string out_mime_type) throws GLib.Error;

[CCode (cname = "openclient_file_load_contents")]
internal extern bool file_load_contents_raw (GLib.File file,
    GLib.Cancellable? cancellable,
    out uint8[] contents,
    out string? etag) throws GLib.Error;

/** Forks `command serve --port <port>` with PR_SET_PDEATHSIG=SIGTERM set
 *  in the child, so the kernel kills the server when the app dies for
 *  any reason (quit, signal, SIGKILL, segfault). Returns the child pid,
 *  or -1 when fork failed. See gtk-compat.c. */
[CCode (cname = "openclient_spawn_server_die_with_parent")]
internal extern int spawn_server_die_with_parent (string command,
    string port,
    string password,
    string cwd,
    string log_path);

/** Wraps a decoded GdkPixbuf in a GdkTexture.
 *
 *  Gdk.Texture.for_pixbuf is deprecated since GTK 4.20 because GdkPixbuf
 *  itself is on its way out (GTK points at libglycin, a whole decoding
 *  library this app does not link). The app decodes and downscales with
 *  GdkPixbuf, so what is left to do is exactly what that function did
 *  internally: describe the pixbuf's memory as a GdkMemoryTexture.
 *  Verified pixel-identical to the deprecated call for 3- and 4-channel
 *  pixbufs (with and without alpha) of assorted sizes. */
internal Gdk.Texture pixbuf_texture (Gdk.Pixbuf pixbuf) {
    if (!pixbuf.get_has_alpha ()) {
        if (pixbuf.get_n_channels () == 4) {
            /* 4 channels without alpha: the padding byte would be read
             *  as transparency, so drop it into a 3-channel copy. */
            var opaque = new Gdk.Pixbuf (Gdk.Colorspace.RGB, false, 8,
                pixbuf.get_width (), pixbuf.get_height ());
            pixbuf.copy_area (0, 0, pixbuf.get_width (), pixbuf.get_height (),
                opaque, 0, 0);
            return new Gdk.MemoryTexture (opaque.get_width (), opaque.get_height (),
                Gdk.MemoryFormat.R8G8B8, opaque.read_pixel_bytes (),
                opaque.get_rowstride ());
        }
        return new Gdk.MemoryTexture (pixbuf.get_width (), pixbuf.get_height (),
            Gdk.MemoryFormat.R8G8B8, pixbuf.read_pixel_bytes (), pixbuf.get_rowstride ());
    }
    return new Gdk.MemoryTexture (pixbuf.get_width (), pixbuf.get_height (),
        Gdk.MemoryFormat.R8G8B8A8, pixbuf.read_pixel_bytes (), pixbuf.get_rowstride ());
}

/** Relay for the clipboard read: C signals "done" on this job when
 *  the read finished. Using an object instead of a callback keeps the
 *  coroutine's resume delegate from being copied (Vala cannot copy
 *  delegates). */
private sealed class ClipboardReadJob : GLib.Object {
    /** Emitted by the C shim when the read finished. */
    public signal void done (GLib.AsyncResult result);
}

}
