/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

namespace OpenClient {

public class Application : Gtk.Application {
    public Config config;
    public Store store;

    public Application () {
        Object (
            application_id: "io.github.haruki.openclient",
            flags: ApplicationFlags.DEFAULT_FLAGS
        );
    }

    protected override void activate () {
        var display = Gdk.Display.get_default ();
        if (display != null) {
            var css = new Gtk.CssProvider ();
            css.load_from_resource ("/io/github/haruki/openclient/style.css");
            Gtk.StyleContext.add_provider_for_display (
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

        var window = new MainWindow (this);
        window.present ();
    }

    /** Applies the theme override from Settings → Appearance:
     *  follow the system scheme, or force light / dark. */
    public void apply_theme_mode () {
        var gtk_settings = Gtk.Settings.get_default ();
        var granite_settings = Granite.Settings.get_default ();
        if (gtk_settings == null || granite_settings == null) {
            return;
        }
        switch (config.theme_mode) {
            case "light":
                gtk_settings.gtk_application_prefer_dark_theme = false;
                break;
            case "dark":
                gtk_settings.gtk_application_prefer_dark_theme = true;
                break;
            default:
                gtk_settings.gtk_application_prefer_dark_theme =
                    granite_settings.prefers_color_scheme == Granite.Settings.ColorScheme.DARK;
                break;
        }
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
