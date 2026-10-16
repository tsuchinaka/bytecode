/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Vala-side convenience over the clipboard shims.
 */

namespace OpenClient {

/** Reads one clipboard entry as a stream.
 *
 *  Gdk.Clipboard.read_async's Vala binding passes the mime list as a
 *  plain array where GTK 4.22 wants a const one, so the request goes
 *  through the shim (gtk-compat.c) and is exposed here with just the
 *  mime type the callers actually ask for. The result is signalled to a
 *  job object, which then resumes the calling coroutine. */
internal async GLib.InputStream? clipboard_read_stream (Gdk.Clipboard clipboard,
    string mime_type) throws GLib.Error {
    GLib.InputStream? stream = null;
    string mime_out = mime_type;
    GLib.Error? failure = null;

    var resume = new IdleResume (clipboard_read_stream.callback);
    var job = new ClipboardReadJob ();
    job.done.connect ((result) => {
        try {
            stream = clipboard_read_finish_raw (clipboard, result, out mime_out);
        } catch (Error e) {
            failure = e;
        }
        resume.resume_now ();
    });

    clipboard_read_mime (clipboard, mime_type, GLib.Priority.DEFAULT, null, job);
    yield;

    if (failure != null) {
        throw failure;
    }
    return stream;
}

}
