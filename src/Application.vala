/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace OpenClient {

/* The app stylesheet is installed for the whole display. Vala marks all
 * of Gtk.StyleContext deprecated since 4.10 because the per-widget API
 * "add_css_class" is the recommended route, which made this call warn;
 * the display-level C function itself is not deprecated and there is no
 * other way to install an application-wide provider. */
[CCode (cname = "gtk_style_context_add_provider_for_display")]
internal extern void add_style_provider_for_display (
    Gdk.Display display, Gtk.StyleProvider provider, uint priority);

public class Application : Gtk.Application {
    public Config config;
    public Store store;
    /** Owns the `opencode serve` process the app runs for itself. */
    public ServerProcess server;
    /** The single window. Kept so a second launch (a click on a
     *  notification, the desktop entry, `--new-session`) reuses it
     *  instead of building another one. */
    private MainWindow? window = null;

    public Application () {
        Object (
            application_id: "io.github.haruki.openclient",
            /* The command line is handled here so the "New Session"
             * desktop action lands in the running instance. */
            flags: ApplicationFlags.DEFAULT_FLAGS | ApplicationFlags.HANDLES_COMMAND_LINE
        );
    }

    /** One-time setup, before the first activate: stylesheet, theme,
     *  config, server, store and the app-wide actions. */
    protected override void startup () {
        base.startup ();

        var display = Gdk.Display.get_default ();
        if (display != null) {
            var css = new Gtk.CssProvider ();
            css.load_from_resource ("/io/github/haruki/openclient/style.css");
            add_style_provider_for_display (
                display,
                css,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            );

            /* Provider model icons (bundled in the gresource). */
            Gtk.IconTheme.get_for_display (display).add_resource_path (
                "/io/github/haruki/openclient/icons"
            );
        }

        config = Config.load ();

        /* The app runs its own `opencode serve`; see ServerProcess. */
        server = new ServerProcess (config);

        /* Respect the user's color scheme preference and adapt live when
         * it changes, rather than keeping an app-private toggle. */
        var granite_settings = Granite.Settings.get_default ();
        var gtk_settings = Gtk.Settings.get_default ();
        if (gtk_settings != null && granite_settings != null) {
            /* elementary ships its stylesheet as a GTK theme; make sure
             * we use it (and its Granite color variables) rather than
             * falling back to Adwaita. */
            var theme = gtk_settings.gtk_theme_name;
            if (theme == null || !theme.has_prefix ("io.elementary.stylesheet")) {
                var iface = new GLib.Settings ("org.gnome.desktop.interface");
                var session_theme = iface.get_string ("gtk-theme");
                if (session_theme.has_prefix ("io.elementary.stylesheet")) {
                    gtk_settings.gtk_theme_name = session_theme;
                }
            }

            apply_theme_mode ();
            granite_settings.notify["prefers-color-scheme"].connect (() => apply_theme_mode ());
            config.notify["theme-mode"].connect (() => apply_theme_mode ());
        }

        store = new Store (config);

        /* Notification actions: answering a permission request straight
         * from its bubble ("app.allow-permission::request-id"). */
        var allow = new GLib.SimpleAction ("allow-permission", VariantType.STRING);
        allow.activate.connect ((target) => reply_notification_permission (target, "once"));
        add_action (allow);
        var reject = new GLib.SimpleAction ("reject-permission", VariantType.STRING);
        reject.activate.connect ((target) => reply_notification_permission (target, "reject"));
        add_action (reject);

        /* Clicking a notification's body focuses the session it is
         *  about, in the window that is already open. */
        var focus = new GLib.SimpleAction ("focus-session", VariantType.STRING);
        focus.activate.connect ((target) => {
            if (target == null) {
                return;
            }
            var session_id = target.get_string ();
            present_window ();
            if (session_id != "" && store != null) {
                store.open_session.begin (session_id);
            }
        });
        add_action (focus);
    }

    /** Shows the window, creating it on first use. Never builds a
     *  second one: a relaunch or a notification click lands here. */
    private void present_window () {
        if (window == null) {
            window = new MainWindow (this);
        }
        window.present ();
    }

    protected override void activate () {
        present_window ();
    }

    /** Command line, forwarded here from a second process by D-Bus:
     *  the running instance handles it instead of a new window being
     *  opened. */
    protected override int command_line (GLib.ApplicationCommandLine command_line) {
        present_window ();

        var new_session = false;
        foreach (var argument in command_line.get_arguments ()) {
            if (argument == "--new-session") {
                new_session = true;
            }
        }
        if (new_session && window != null) {
            window.open_new_session ();
        }

        command_line.set_exit_status (0);
        return 0;
    }

    /** Brings the connection up: the app's own server first (managed
     *  mode), then the REST client and event stream. Every reconnect
     *  path in the UI goes through here. */
    public async bool ensure_connected () {
        if (config.manage_server) {
            config.ensure_server_password ();
            config.save ();
            if (!yield server.ensure_running ()) {
                store.connection_failed (server.detail);
                return false;
            }
        } else if (!config.has_connection) {
            return false;
        }
        yield store.connect_and_load ();
        return store.client != null;
    }

    /** Closing the window is not the only way out: a logout, a `kill`
     *  or an interrupted session sends a signal, and the app server must
     *  not be left behind. These handlers stop it and quit normally. */
    public void watch_signals () {
        foreach (var signum in new int[] { Posix.Signal.TERM, Posix.Signal.INT, Posix.Signal.HUP }) {
            GLib.Unix.signal_add (signum, () => {
                stop_owned_server ();
                quit ();
                return GLib.Source.REMOVE;
            });
        }
    }

    /** Stops the server the app started, so leaving does not leave an
     *  orphan behind. Idempotent. */
    public void stop_owned_server () {
        if (config != null && server != null) {
            server.shut_down ();
        }
    }

    /** Last chance to clean up: runs for a normal quit (window closed,
     *  Ctrl+Q, `gapplication quit`) and again after a signal. */
    protected override void shutdown () {
        if (config != null && config.manage_server) {
            stop_owned_server ();
        }
        base.shutdown ();
    }

    /** Applies the theme override from Settings → Appearance:
     *  follow the system scheme, or force light / dark. */
    public void apply_theme_mode () {
        var gtk_settings = Gtk.Settings.get_default ();
        var granite_settings = Granite.Settings.get_default ();
        if (gtk_settings == null || granite_settings == null) {
            return;
        }
        var dark = false;
        switch (config.theme_mode) {
            case "light":
                dark = false;
                break;
            case "dark":
                dark = true;
                break;
            default:
                dark = granite_settings.prefers_color_scheme
                    == Granite.Settings.ColorScheme.DARK;
                break;
        }
        set_prefer_dark_theme (gtk_settings, dark);
    }

    /** Selects the theme's dark variant.
     *
     *  This is Gtk.Settings:gtk-application-prefer-dark-theme, which GTK
     *  deprecated in 4.20 in favour of the CSS "prefers-color-scheme"
     *  query. That replacement cannot be used here: the elementary
     *  stylesheet ships separate gtk.css / gtk-dark.css files and no
     *  prefers-color-scheme media queries (verified against
     *  io.elementary.stylesheet on elementary OS 9), so this setting is
     *  the only thing that actually switches the theme to its dark
     *  variant. Set by property name, because the typed accessor is the
     *  deprecated one; the lookup below keeps a future removal loud
     *  instead of silently leaving the app in one scheme. */
    private static void set_prefer_dark_theme (Gtk.Settings settings, bool dark) {
        if (settings.get_class ().find_property ("gtk-application-prefer-dark-theme") == null) {
            warning ("Gtk.Settings no longer has gtk-application-prefer-dark-theme;"
                + " the Light/Dark override cannot be applied on this GTK");
            return;
        }
        settings.set_property ("gtk-application-prefer-dark-theme", dark);
    }

    private void reply_notification_permission (Variant? target, string decision) {
        if (target == null || store == null) {
            return;
        }
        var request_id = target.get_string ();
        /* Defensive: some daemons forward the raw detailed-name text
         * (quotes included) instead of the parsed string. */
        if (request_id.has_prefix ("'") && request_id.has_suffix ("'") && request_id.length >= 2) {
            request_id = request_id.substring (1, request_id.length - 2);
        }
        var request = store.pending_permissions[request_id];
        if (request == null) {
            return;
        }
        store.reply_permission.begin (request.session_id, request_id, decision);
        withdraw_notification (@"perm-$(request.session_id)");
    }

    public static int main (string[] args) {
        return new Application ().run (args);
    }
}

}
