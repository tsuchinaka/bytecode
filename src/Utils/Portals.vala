/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * File handling through XDG desktop portals
 * (org.freedesktop.portal FileChooser / OpenURI) instead of direct
 * GtkFileChooser dialogs: the same code works sandboxed (Flatpak)
 * and unsandboxed, and "open" actions delegate to the user's
 * default applications.
 *
 * parent_window is deliberately empty on every call: exporting a
 * Wayland surface handle for dialog transiency needs xdg-foreign
 * plumbing; the portal centers an unparented dialog instead.
 */

namespace OpenClient {

public class Portals : GLib.Object {
    private const string BUS_NAME = "org.freedesktop.portal.Desktop";
    private const string OBJECT_PATH = "/org/freedesktop/portal/desktop";
    private const string FILE_CHOOSER = "org.freedesktop.portal.FileChooser";
    private const string OPEN_URI = "org.freedesktop.portal.OpenURI";
    private const string REQUEST = "org.freedesktop.portal.Request";

    /** Folder picker (portal FileChooser with directory=true). Returns
     *  the native path, or null when cancelled or unavailable. */
    public static async string? pick_folder (string title, string current_folder = "") {
        var options = new VariantBuilder (VariantType.VARDICT);
        options.add ("{sv}", "accept_label", new Variant.string ("_Select"));
        options.add ("{sv}", "directory", new Variant.boolean (true));
        if (current_folder != "") {
            options.add ("{sv}", "current_folder", new Variant.bytestring (current_folder));
        }
        var uris = yield choose_files (title, options.end ());
        if (uris == null || uris.length == 0) {
            return null;
        }
        return GLib.File.new_for_uri (uris[0]).get_path ();
    }

    /** Multi image picker with an image/* filter. Returns the chosen
     *  files, or null when cancelled or unavailable. */
    public static async Gee.ArrayList<GLib.File>? pick_images (string title = "Attach images") {
        var filters = new VariantBuilder (new VariantType ("a(sa(us))"));
        filters.open (new VariantType ("(sa(us))"));
        filters.add ("s", "Images");
        var kinds = new VariantBuilder (new VariantType ("a(us)"));
        /* Filter type 1 = MIME type. */
        kinds.add ("(us)", (uint32) 1, "image/*");
        filters.add_value (kinds.end ());
        filters.close ();

        var options = new VariantBuilder (VariantType.VARDICT);
        options.add ("{sv}", "accept_label", new Variant.string ("_Attach"));
        options.add ("{sv}", "multiple", new Variant.boolean (true));
        options.add ("{sv}", "filters", filters.end ());
        var uris = yield choose_files (title, options.end ());
        if (uris == null) {
            return null;
        }
        var files = new Gee.ArrayList<GLib.File> ();
        foreach (var uri in uris) {
            files.add (GLib.File.new_for_uri (uri));
        }
        return files;
    }

    /** Opens a file with its default application (portal OpenURI). */
    public static async bool open_file (string path) {
        return yield open_fd ("OpenFile", path, false);
    }

    /** Reveals a folder in the file manager (portal OpenDirectory). */
    public static async bool reveal_in_files (string path) {
        return yield open_fd ("OpenDirectory", path, true);
    }

    /* -- plumbing ---------------------------------------------------- */

    private static async string[]? choose_files (string title, Variant options) {
        GLib.DBusConnection conn;
        try {
            conn = GLib.Bus.get_sync (GLib.BusType.SESSION);
        } catch (Error e) {
            warning ("No session bus for portal: %s", e.message);
            return null;
        }
        string handle;
        try {
            /* Container args (a{sv}) go through a builder: the
             * printf-style Variant() constructor cannot take them. */
            var call = new VariantBuilder (new VariantType ("(ssa{sv})"));
            call.add ("s", "");
            call.add ("s", title);
            call.add_value (options);
            var reply = yield conn.call (
                BUS_NAME, OBJECT_PATH, FILE_CHOOSER, "OpenFile",
                call.end (),
                new VariantType ("(o)"),
                GLib.DBusCallFlags.NONE, -1, null
            );
            handle = reply.get_child_value (0).get_string ();
        } catch (Error e) {
            warning ("Portal file chooser failed: %s", e.message);
            return null;
        }
        uint code;
        Variant? results;
        yield wait_for_response (conn, handle, out code, out results);
        if (code != 0 || results == null) {
            return null;
        }
        var uris = results.lookup_value ("uris", VariantType.STRING_ARRAY);
        if (uris == null) {
            return null;
        }
        return uris.get_strv ();
    }

    private static async bool open_fd (string method, string path, bool directory) {
        var flags = Posix.O_RDONLY | Posix.O_CLOEXEC | (directory ? Posix.O_DIRECTORY : 0);
        var fd = Posix.open (path, flags);
        if (fd < 0) {
            warning ("Cannot open %s for portal: %s", path, Posix.strerror (Posix.errno));
            return false;
        }
        GLib.DBusConnection conn;
        try {
            conn = GLib.Bus.get_sync (GLib.BusType.SESSION);
        } catch (Error e) {
            warning ("No session bus for portal: %s", e.message);
            Posix.close (fd);
            return false;
        }
        var args = new VariantBuilder (new VariantType ("(sha{sv})"));
        args.add ("s", "");
        args.add_value (new Variant.handle (0));
        args.add_value (new VariantBuilder (VariantType.VARDICT).end ());
        string handle;
        try {
            var fd_list = new GLib.UnixFDList.from_array ({ fd });
            var reply = yield conn.call_with_unix_fd_list (
                BUS_NAME, OBJECT_PATH, OPEN_URI, method,
                args.end (),
                new VariantType ("(o)"),
                GLib.DBusCallFlags.NONE, -1, fd_list, null
            );
            handle = reply.get_child_value (0).get_string ();
        } catch (Error e) {
            warning ("Portal open failed: %s", e.message);
            Posix.close (fd);
            return false;
        }
        /* The portal dup'd our fd; safe to close our copy now. */
        Posix.close (fd);
        uint code;
        Variant? results;
        yield wait_for_response (conn, handle, out code, out results);
        return code == 0;
    }

    /** Awaits the Request.Response signal for a portal call. */
    private static async void wait_for_response (GLib.DBusConnection conn, string handle,
        out uint code, out Variant? results) {
        uint got_code = 2;
        Variant? got_results = null;
        var sub = conn.signal_subscribe (
            BUS_NAME, REQUEST, "Response", handle, null,
            GLib.DBusSignalFlags.NONE,
            (c, sender, path, iface, name, parameters) => {
                got_code = parameters.get_child_value (0).get_uint32 ();
                got_results = parameters.get_child_value (1);
                wait_for_response.callback ();
            }
        );
        yield;
        conn.signal_unsubscribe (sub);
        code = got_code;
        results = got_results;
    }
}

}
