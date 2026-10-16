/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Main window: two-pane layout following the elementary OS panes
 * pattern: session sidebar on the start side, chat on the end
 * side, with a toast overlay for transient notices.
 */

namespace OpenClient {

public class MainWindow : Gtk.ApplicationWindow {
    private Application app;

    private Sidebar sidebar;
    private ChatView chat_view;
    private Composer composer;
    private NewSessionView new_session_view;

    private Gtk.Stack content_stack;
    private Gtk.Stack empty_stack;
    /** Chat vs settings pages of the end pane. */
    private Gtk.Stack end_stack;
    private SettingsView settings_view;
    private SessionPanel session_panel;
    private Gtk.ToggleButton panel_button;
    private Gtk.Label title_label;
    private Gtk.Label subtitle_label;
    private Gtk.Label error_label;
    private Gtk.Spinner loading_spinner;
    private Gtk.Label loading_label;
    private Gtk.Overlay overlay;
    private Granite.Toast toast;
    private uint render_source = 0;
    /** Coalesced inspector refresh (see refresh_panel). */
    private uint panel_source = 0;
    /** Last known status per session, to detect turn-end transitions. */
    private Gee.HashMap<string, string> last_status = new Gee.HashMap<string, string> ();
    /** True while the new-session hero is up: no existing session
     *  should look selected in the sidebar. */
    private bool composing_new_session = false;

    public MainWindow (Application app) {
        Object (
            application: app,
            title: "OpenCode",
            default_width: 1100,
            default_height: 760
        );
        this.app = app;

        setup_actions ();
        build_ui ();
        connect_store ();
        /* A logout or kill must take the app's server with it. */
        app.watch_signals ();
        start_connection.begin ();
    }


    private void build_ui () {
        /* Start pane: sidebar */
        var start_header = new Gtk.HeaderBar () {
            show_title_buttons = false,
            /* No title widget: otherwise the window title renders here
             * as stray centered text above the session list. */
            title_widget = new Gtk.Label ("") { visible = false }
        };
        start_header.add_css_class (Granite.STYLE_CLASS_FLAT);
        start_header.pack_start (new Gtk.WindowControls (Gtk.PackType.START));

        var new_session_button = new Gtk.Button.from_icon_name ("list-add") {
            tooltip_markup = Granite.markup_accel_tooltip (
                app.get_accels_for_action ("win.new-session"),
                "New Session"
            )
        };
        new_session_button.clicked.connect (() => {
            show_new_session ();
        });
        start_header.pack_end (new_session_button);

        sidebar = new Sidebar ();
        sidebar.session_selected.connect ((session_id) => {
            show_chat ();
            if (session_panel != null) {
                session_panel.clear_placeholder ();
            }
            app.store.open_session.begin (session_id);
        });
        sidebar.session_delete_requested.connect ((session_id) => {
            if (!app.config.confirm_delete) {
                app.store.delete_session.begin (session_id);
                return;
            }
            string title = session_id;
            foreach (var session in app.store.sessions) {
                if (session.id == session_id) {
                    title = session.title;
                    break;
                }
            }
            var dialog = new Gtk.AlertDialog (
                @"Delete “$title”?",
                "The conversation and its context will be permanently removed."
            );
            OpenClient.set_alert_buttons (dialog, new string[] { "Cancel", "Delete" });
            dialog.set_cancel_button (0);
            dialog.set_default_button (0);
            dialog.choose.begin (this, null, (obj, res) => {
                try {
                    if (dialog.choose.end (res) == 1) {
                        app.store.delete_session.begin (session_id);
                    }
                } catch (Error e) {
                }
            });
        });
        sidebar.sessions_delete_requested.connect ((session_ids) => {
            delete_sessions (session_ids);
        });
        sidebar.session_rename_requested.connect ((session_id) => {
            show_rename_dialog (session_id);
        });
        sidebar.session_diff_requested.connect ((session_id) => {
            show_diff_dialog (session_id);
        });
        sidebar.session_export_requested.connect ((session_id) => {
            export_session.begin (session_id);
        });
        sidebar.session_fork_requested.connect ((session_id) => {
            app.store.fork_session.begin (session_id);
        });
        sidebar.session_compact_requested.connect ((session_id) => {
            app.store.compact_session.begin (session_id);
        });
        sidebar.session_pin_requested.connect ((session_id, pinned) => {
            app.store.set_pinned (session_id, pinned);
        });
        sidebar.session_archive_requested.connect ((session_id, archived) => {
            app.store.set_archived (session_id, archived);
        });

        /* The whole start pane shares the theme sidebar background,
         *  header, list and action bar read as one column instead of
         *  the header floating on window background above it. */
        var start_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            width_request = 280
        };
        start_box.add_css_class (Granite.STYLE_CLASS_SIDEBAR);
        start_box.append (start_header);
        start_box.append (sidebar);

        /* End pane: chat */
        var end_header = new Gtk.HeaderBar () {
            show_title_buttons = false
        };
        end_header.add_css_class (Granite.STYLE_CLASS_FLAT);
        end_header.pack_end (new Gtk.WindowControls (Gtk.PackType.END));

        var menu_button = new Gtk.MenuButton () {
            icon_name = "open-menu",
            primary = true,
            tooltip_markup = Granite.markup_accel_tooltip ({ "F10" }, "Main Menu")
        };
        var menu = new GLib.Menu ();
        menu.append ("New Session", "win.new-session");
        menu.append ("Reload Models & Agents", "win.reload-catalog");
        menu.append ("Settings…", "win.settings");
        menu.append ("About", "win.about");
        menu_button.menu_model = menu;
        end_header.pack_start (menu_button);

        panel_button = new Gtk.ToggleButton () {
            icon_name = "sidebar-show-right-symbolic",
            tooltip_text = "Toggle session details",
            active = false
        };
        panel_button.add_css_class (Granite.STYLE_CLASS_FLAT);
        panel_button.toggled.connect (() => {
            session_panel.visible = panel_button.active;
            if (panel_button.active) {
                session_panel.update ();
            }
        });
        end_header.pack_end (panel_button);

        var title_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            valign = Gtk.Align.CENTER
        };
        title_label = new Gtk.Label ("OpenCode") {
            ellipsize = Pango.EllipsizeMode.END
        };
        title_label.add_css_class ("heading");
        subtitle_label = new Gtk.Label ("") {
            ellipsize = Pango.EllipsizeMode.END,
            visible = false
        };
        subtitle_label.add_css_class ("caption");
        subtitle_label.add_css_class (Granite.CssClass.DIM);
        title_box.append (title_label);
        title_box.append (subtitle_label);
        end_header.set_title_widget (title_box);

        chat_view = new ChatView ();
        composer = new Composer () {
            ctrl_enter_to_send = app.config.send_with_ctrl_enter
        };
        app.config.notify["send-with-ctrl-enter"].connect (() => {
            composer.ctrl_enter_to_send = app.config.send_with_ctrl_enter;
        });
        composer.send_requested.connect ((text, files) => {
            app.store.send_prompt.begin (text, files);
            composer.grab_focus_entry ();
        });
        composer.stop_requested.connect (() => app.store.stop_or_interrupt ());
        composer.permission_decision.connect ((request_id, decision) => {
            if (app.store.active_session_id == null) {
                return;
            }
            app.store.reply_permission.begin (app.store.active_session_id, request_id, decision);
        });
        composer.diff_requested.connect (() => {
            if (app.store.active_session_id != null) {
                show_diff_dialog (app.store.active_session_id);
            }
        });
        composer.command_requested.connect ((name, text) => {
            run_command (name, text);
        });
        composer.variant_chooser.variant_selected.connect ((variant) => {
            var session = app.store.active_session;
            if (session == null) {
                return;
            }
            app.store.set_model.begin (session.id, session.provider_id, session.model_id, variant);
        });
        composer.form_answered.connect ((form_id, answer) => {
            if (app.store.active_session_id == null) {
                return;
            }
            app.store.reply_form.begin (app.store.active_session_id, form_id, answer);
        });
        composer.form_cancelled.connect ((form_id) => {
            if (app.store.active_session_id == null) {
                return;
            }
            app.store.cancel_form.begin (
                app.store.active_session_id, form_id, "Dismissed from the client");
        });
        composer.permission_mode_changed.connect ((mode) => {
            if (app.store.active_session_id == null) {
                return;
            }
            app.store.set_permission_mode.begin (app.store.active_session_id, mode);
        });

        composer.model_chooser.model_selected.connect ((provider_id, model_id, variant) => {
            var store = app.store;
            if (store.active_session_id == null) {
                return;
            }
            /* Carry the current thinking level over when supported. */
            var session = store.active_session;
            var carried = "";
            if (session != null && session.variant != "") {
                var info = store.find_model (provider_id, model_id);
                if (info != null && info.variants.contains (session.variant)) {
                    carried = session.variant;
                }
            }
            store.set_model.begin (store.active_session_id, provider_id, model_id, carried);
        });
        composer.agent_chooser.agent_selected.connect ((agent_id) => {
            if (app.store.active_session_id == null) {
                return;
            }
            app.store.set_agent.begin (app.store.active_session_id, agent_id);
        });

        var chat_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        chat_box.append (chat_view);
        /* No hard rule between chat and composer: the input card
         * floats on its own shadow (see .composer-card), which reads
         * as depth instead of a cut. */
        chat_box.append (composer);

        /* Center stack: loading / offline / empty / chat */
        loading_spinner = new Gtk.Spinner () {
            spinning = true,
            halign = Gtk.Align.CENTER,
            valign = Gtk.Align.CENTER,
            width_request = 32,
            height_request = 32
        };
        loading_label = new Gtk.Label ("Connecting…") {
            halign = Gtk.Align.CENTER,
            wrap = true,
            justify = Gtk.Justification.CENTER,
            max_width_chars = 50
        };
        loading_label.add_css_class (Granite.CssClass.DIM);
        var loading_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12) {
            halign = Gtk.Align.CENTER,
            valign = Gtk.Align.CENTER
        };
        loading_box.append (loading_spinner);
        loading_box.append (loading_label);

        error_label = new Gtk.Label ("") {
            wrap = true,
            justify = Gtk.Justification.CENTER,
            max_width_chars = 50
        };
        error_label.add_css_class (Granite.CssClass.DIM);

        var offline_placeholder = new Granite.Placeholder ("Can't reach OpenCode") {
            description = "The app server did not answer."
        };
        offline_placeholder.icon = new ThemedIcon ("network-server");
        var retry_button = offline_placeholder.append_button (
            new ThemedIcon ("view-refresh"),
            "Try Again",
            "Retry the connection"
        );
        retry_button.clicked.connect (() => start_connection.begin ());
        var settings_button = offline_placeholder.append_button (
            new ThemedIcon ("preferences-system"),
            "Connection Settings",
            "Set host, port and password"
        );
        settings_button.clicked.connect (() => show_settings ());

        var offline_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12) {
            halign = Gtk.Align.CENTER,
            valign = Gtk.Align.CENTER
        };
        offline_box.append (offline_placeholder);
        offline_box.append (error_label);

        var empty_placeholder = new Granite.Placeholder ("No chat selected") {
            description = "Create a new session to start working with OpenCode."
        };
        empty_placeholder.icon = new ThemedIcon ("user-available");
        var create_button = empty_placeholder.append_button (
            new ThemedIcon ("list-add"),
            "New Session",
            "Start a fresh conversation"
        );
        create_button.clicked.connect (() => {
            show_new_session ();
        });

        empty_stack = new Gtk.Stack () {
            /* Chat ⇄ hero ⇄ empty states crossfade; page-level slides
             *  live on end_stack (chat ⇄ settings). */
            transition_type = Gtk.StackTransitionType.CROSSFADE,
            transition_duration = 180
        };
        empty_stack.add_named (empty_placeholder, "no-session");
        empty_stack.add_named (chat_box, "chat");
        new_session_view = new NewSessionView () {
            ctrl_enter_to_send = app.config.send_with_ctrl_enter
        };
        app.config.notify["send-with-ctrl-enter"].connect (() => {
            new_session_view.ctrl_enter_to_send = app.config.send_with_ctrl_enter;
        });
        new_session_view.create_requested.connect ((directory, text, files) => {
            new_session_view.clear_message ();
            /* The inspector keeps its placeholder until the new session
             * actually becomes active (see active_session_changed). */
            app.store.create_session_with_prompt.begin (
                directory, text,
                new_session_view.pending_provider_id,
                new_session_view.pending_model_id,
                new_session_view.pending_variant,
                new_session_view.pending_agent_id,
                files
            );
        });
        new_session_view.cancelled.connect (() => show_chat ());
        /* Remember picked folders for the recents popover (most
         * recent first, capped). */
        new_session_view.folder_selected.connect ((directory) => {
            var recents = new Gee.ArrayList<string> ();
            recents.add (directory);
            foreach (var existing in app.config.workspace_history) {
                if (existing != directory && existing.strip () != "") {
                    recents.add (existing);
                }
            }
            while (recents.size > 6) {
                recents.remove_at (recents.size - 1);
            }
            app.config.workspace_history = ListArrays.to_string_array (recents);
            app.config.save ();
            new_session_view.set_recent_folders (recents);
        });
        new_session_view.model_chooser.model_selected.connect ((provider_id, model_id, variant) => {
            new_session_view.note_model_selected (provider_id, model_id, variant);
            /* Reflect the pick on the button, or it looks dead. */
            new_session_view.model_chooser.set_current (provider_id, model_id);
            var info = app.store.find_model (provider_id, model_id);
            if (info != null) {
                new_session_view.variant_chooser.set_variants (info.variants, variant);
            } else {
                new_session_view.variant_chooser.set_variants (new Gee.ArrayList<string> (), "");
            }
        });
        new_session_view.variant_chooser.variant_selected.connect ((variant) => {
            new_session_view.note_variant_selected (variant);
        });
        new_session_view.agent_chooser.agent_selected.connect ((agent_id) => {
            new_session_view.note_agent_selected (agent_id);
            new_session_view.agent_chooser.set_current (agent_id);
        });
        empty_stack.add_named (new_session_view, "new");

        content_stack = new Gtk.Stack () {
            /* Loading ⇄ offline ⇄ content crossfade with the rest. */
            transition_type = Gtk.StackTransitionType.CROSSFADE,
            transition_duration = 180
        };
        content_stack.add_named (loading_box, "loading");
        content_stack.add_named (offline_box, "offline");
        content_stack.add_named (empty_stack, "content");
        content_stack.visible_child_name = "loading";

        var end_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        end_box.add_css_class (Granite.STYLE_CLASS_VIEW);

        /* Chat page: the usual header + content stack. */
        var chat_page = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        chat_page.append (end_header);
        chat_page.append (content_stack);

        /* Settings page: its own header (back + title + window
         * controls) with the in-window settings view below. */
        settings_view = new SettingsView (app.config, app.store, app.server);
        var settings_header = new Gtk.HeaderBar () {
            show_title_buttons = false
        };
        settings_header.add_css_class (Granite.STYLE_CLASS_FLAT);
        var back_button = new Gtk.Button.from_icon_name ("go-previous") {
            tooltip_text = "Back to chat"
        };
        back_button.clicked.connect (() => show_chat ());
        settings_header.pack_start (back_button);
        var settings_title = new Gtk.Label ("Settings");
        settings_title.add_css_class ("heading");
        settings_header.set_title_widget (settings_title);
        settings_header.pack_end (new Gtk.WindowControls (Gtk.PackType.END));
        var settings_page = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        settings_page.append (settings_header);
        settings_page.append (settings_view);
        var settings_escape = new Gtk.EventControllerKey ();
        settings_escape.key_pressed.connect ((keyval, keycode, state) => {
            if (keyval == Gdk.Key.Escape) {
                show_chat ();
                return true;
            }
            return false;
        });
        settings_page.add_controller (settings_escape);

        end_stack = new Gtk.Stack () {
            transition_type = Gtk.StackTransitionType.SLIDE_LEFT_RIGHT
        };
        end_stack.add_named (chat_page, "chat");
        end_stack.add_named (settings_page, "settings");
        end_box.append (end_stack);

        /* Session inspector pane (right), collapsible from the header. */
        session_panel = new SessionPanel (app.store);
        session_panel.visible = false;
        var right_paned = new Gtk.Paned (Gtk.Orientation.HORIZONTAL) {
            start_child = end_box,
            end_child = session_panel,
            resize_start_child = true,
            shrink_start_child = false,
            shrink_end_child = false,
            position = 780
        };

        var paned = new Gtk.Paned (Gtk.Orientation.HORIZONTAL) {
            start_child = start_box,
            end_child = right_paned,
            resize_start_child = false,
            shrink_start_child = false,
            shrink_end_child = false,
            position = 280
        };
        overlay = new Gtk.Overlay () {
            child = paned,
            /* In-window popovers are clipped to the window, so they can
             * never spill over other applications. */
            overflow = Gtk.Overflow.HIDDEN
        };
        toast = new Granite.Toast ("");
        toast.halign = Gtk.Align.CENTER;
        toast.valign = Gtk.Align.END;
        overlay.add_overlay (toast);

        titlebar = new Gtk.Grid () { visible = false };
        child = overlay;

        /* Window actions are registered in setup_actions () */
    }

    private void setup_actions () {
        var new_action = new GLib.SimpleAction ("new-session", null);
        new_action.activate.connect (() => {
            show_new_session ();
        });
        add_action (new_action);

        var settings_action = new GLib.SimpleAction ("settings", null);
        settings_action.activate.connect (() => show_settings ());
        add_action (settings_action);

        var reload_action = new GLib.SimpleAction ("reload-catalog", null);
        reload_action.activate.connect (() => {
            app.store.load_models.begin ();
            app.store.load_agents.begin ();
        });
        add_action (reload_action);

        var about_action = new GLib.SimpleAction ("about", null);
        about_action.activate.connect (show_about);
        add_action (about_action);

        /* Keyboard shortcuts live on actions so tooltips can surface
         * them through Granite.markup_accel_tooltip (). */
        OpenClient.set_action_accels (app, "win.new-session", new string[] { "<Control>n" });
        OpenClient.set_action_accels (app, "win.settings", new string[] { "<Control>comma" });
    }

    private void show_toast (string message) {
        toast.title = message;
        toast.send_notification ();
    }

    /** Rebuilds the conversation in small batches so that a long
     *  session never blocks the main loop: the window keeps painting
     *  and the first messages appear immediately. Scroll pinning and
     *  layout notifications are suspended until the last batch. */
    private void rebuild_chat () {
        if (render_source != 0) {
            GLib.Source.remove (render_source);
            render_source = 0;
            chat_view.cancel_bulk ();
        }

        chat_view.clear ();

        var pending = new Gee.ArrayList<Message> ();
        pending.add_all (app.store.active_messages);

        if (pending.size == 0) {
            chat_view.scroll_to_bottom (true);
            /* Nothing to stream in: callers waiting on the rebuild may
             *  finish now instead of on the next idle round. */
            chat_rebuilt ();
            return;
        }

        debug ("rebuild_chat: rendering %u messages incrementally", pending.size);

        chat_view.begin_bulk ();

        int index = 0;
        render_source = GLib.Idle.add (() => {
            var budget = 15;
            while (index < pending.size && budget > 0) {
                chat_view.add_message (pending[index]);
                index++;
                budget--;
            }
            if (index >= pending.size) {
                chat_view.end_bulk ();
                render_source = 0;
                chat_rebuilt ();
                return false;
            }
            return true;
        });
    }

    /** Signals that rebuild_chat() finished inserting every row.
     *  Anything that must land after the conversation (replaying an
     *  in-flight turn) runs here rather than polling for the idle
     *  source to disappear. */
    private signal void chat_rebuilt ();

    private void connect_store () {
        var store = app.store;

        chat_view.playful = app.config.playful_status;
        app.config.notify["playful-status"].connect (() => {
            chat_view.playful = app.config.playful_status;
        });

        store.connected.connect ((version) => {
            subtitle_label.label = @"connected · v$version";
            subtitle_label.visible = true;
            load_context_sources ();
            if (store.sessions.size > 0) {
                content_stack.visible_child_name = "content";
                store.open_session.begin (store.sessions[0].id);
            } else {
                content_stack.visible_child_name = "content";
                empty_stack.visible_child_name = "no-session";
            }
        });

        store.connection_failed.connect ((message) => {
            error_label.label = message;
            content_stack.visible_child_name = "offline";
        });

        store.notice.connect ((message) => {
            show_toast (message);
        });

        store.sessions_changed.connect (() => {
            sidebar.set_sessions (store.sessions);
            if (store.active_session_id != null && !composing_new_session) {
                sidebar.select (store.active_session_id);
            }
            /* Rows are (re)created by the diff: re-apply live indicators. */
            foreach (var session in store.sessions) {
                update_row_indicator (session.id);
            }
            update_title ();
            update_context_meter ();
            refresh_panel ();
        });

        store.session_title_changed.connect ((session_id) => {
            string title = "";
            foreach (var session in store.sessions) {
                if (session.id == session_id) {
                    title = session.title;
                    break;
                }
            }
            if (title != "") {
                sidebar.update_title (session_id, title);
            }
            if (session_id == store.active_session_id) {
                update_title ();
            }
        });

        store.active_session_changed.connect (() => {
            chat_view.clear ();
            composer.set_diff_stat (0, 0, 0);
            /* A real session is now open: leave new-session mode and
             * let the sidebar highlight it again. */
            composing_new_session = false;
            if (session_panel != null) {
                session_panel.clear_placeholder ();
            }
            if (store.active_session_id == null) {
                empty_stack.visible_child_name = "no-session";
            } else {
                empty_stack.visible_child_name = "chat";
                sidebar.select (store.active_session_id);
                composer.grab_focus_entry ();
            }
            composer.set_running (store.is_active_running);
            update_title ();
            update_choosers ();
            composer.set_permission_mode (store.active_session != null ? store.active_session.permission_mode : "ask");
            update_permission_banner ();
            update_form_dock ();
            update_context_meter ();
            refresh_panel ();
        });

        store.messages_loaded.connect (() => {
            if (store.active_session_id != null) {
                store.refresh_diff_stat.begin (store.active_session_id);
            }
            rebuild_chat ();
            refresh_panel ();
            /* Opened mid-turn (or the turn outlived the rebuild): the
             * footer goes back up with the line matching the turn's
             * state: working quips, or what it is waiting on. */
            restore_pending_footer ();
            /* Opened mid-turn part two: history lacks the partial
             * reply, the live cache has it. Replay once the incremental
             * rebuild settles so replayed bubbles land last instead of
             * buried mid-history (chat_rebuilt fires from the last
             * batch (no polling for the rebuild to finish). */
            var replay_id = store.active_session_id;
            if (replay_id != null) {
                ulong handler = 0;
                handler = chat_rebuilt.connect (() => {
                    this.disconnect (handler);
                    if (replay_id == app.store.active_session_id) {
                        replay_live (replay_id);
                    }
                });
            }
        });

        store.message_appended.connect ((message) => {
            chat_view.add_message (message);
            /* Covers back-to-back sends: the status signal dedups when
             * the session is already running, but every new user bubble
             * still deserves the pending placeholder. */
            if (message.role == MessageRole.USER && store.is_active_running) {
                chat_view.show_pending ();
            }
        });

        store.assistant_started.connect ((message_id, model) => {
            chat_view.note_model (message_id, model);
        });

        store.text_delta.connect ((message_id, delta) => {
            chat_view.append_text (message_id, delta);
        });

        store.text_done.connect ((message_id, text) => {
            chat_view.finish_text (message_id, text);
        });

        store.reasoning_delta.connect ((message_id, delta) => {
            chat_view.append_reasoning (message_id, delta);
        });

        store.reasoning_done.connect ((message_id, text) => {
            chat_view.finish_reasoning (message_id, text);
        });

        store.divider_changed.connect ((session_id, divider_id, icon_name, text, status) => {
            if (session_id != store.active_session_id) {
                return;
            }
            chat_view.set_divider (divider_id, icon_name, text, status);
        });

        store.divider_delta.connect ((session_id, divider_id, delta) => {
            if (session_id != store.active_session_id) {
                return;
            }
            chat_view.append_divider_summary (divider_id, delta);
        });

        store.commands_changed.connect (() => {
            composer.set_server_commands (store.commands);
        });

        store.tool_changed.connect ((message_id, call_id, phase) => {
            var tool = store.live_tool_for (call_id);
            if (tool == null) {
                return;
            }
            if (tool.name == "task") {
                refresh_panel ();
            }
            switch (phase) {
                case "started":
                    chat_view.tool_started (message_id, call_id, tool.name);
                    break;
                case "input":
                    chat_view.tool_input (message_id, call_id, tool.input_summary);
                    break;
                case "done":
                    chat_view.tool_done (message_id, call_id, tool.output_text, tool.files, tool.error);
                    break;
                default:
                    break;
            }
        });

        store.diffs_changed.connect ((session_id) => {
            if (session_id == store.active_session_id) {
                composer.set_diff_stat (store.diff_files, store.diff_additions, store.diff_deletions);
            }
        });

        store.status_changed.connect((session_id, status) => {
            update_row_indicator (session_id);
            var was = last_status.has_key (session_id) ? last_status[session_id] : "idle";
            last_status[session_id] = status;
            if (was == "running" && status == "idle") {
                notify_turn_finished (session_id);
            }
            if (session_id == store.active_session_id) {
                var running = status == "running";
                composer.set_running (running);
                if (running) {
                    /* Instant feedback: the user's bubble is already up
                     * (optimistic echo); the footer with its playful
                     * line covers the wait, and stays pinned at the
                     * bottom for the whole turn, not just until the
                     * first streamed content. */
                    chat_view.show_pending ();
                } else if (status == "waiting") {
                    /* Turn paused on a permission: the footer stays,
                     * but says what it is blocked on instead of the
                     * working quips. */
                    chat_view.set_pending_state (ChatView.PendingState.WAITING_PERMISSION);
                    update_title ();
                } else if (status == "question") {
                    chat_view.set_pending_state (ChatView.PendingState.WAITING_ANSWER);
                    update_title ();
                } else {
                    chat_view.finish_live ();
                    update_title ();
                }
            }
            /* Keep the inspector in step with turn transitions. */
            refresh_panel ();
        });

        store.activity_changed.connect ((session_id) => {
            update_row_indicator (session_id);
        });

        store.usage_updated.connect (() => {
            update_title ();
            update_context_meter ();
            refresh_panel ();
        });

        store.catalog_changed.connect (() => {
            composer.model_chooser.set_models (store.models);
            composer.agent_chooser.set_agents (store.agents);
            new_session_view.set_models (store.models);
            new_session_view.set_agents (store.agents);
            update_choosers ();
            update_context_meter ();
            refresh_panel ();
        });

        store.model_changed.connect ((session_id) => {
            update_choosers ();
            update_context_meter ();
            refresh_panel ();
        });

        store.agent_changed.connect ((session_id) => {
            update_choosers ();
            refresh_panel ();
        });

        store.permissions_changed.connect ((session_id) => {
            update_permission_banner ();
            if (session_id == store.active_session_id && store.active_session != null) {
                composer.set_permission_mode (store.active_session.permission_mode);
            }
            var request = store.pending_permission_for (session_id);
            if (request != null) {
                /* Blocking and easy to miss on a background tab: bubble
                 * it so it can be answered without opening the app. */
                if (app.config.notifications_enabled && app.config.notify_permissions
                    && (session_id != store.active_session_id || !is_active)) {
                    var notification = new GLib.Notification ("Permission requested");
                    notification.set_body (@"$(session_title (session_id)): $(request.describe ())");
                    notification.set_icon (new ThemedIcon ("dialog-warning"));
                    notification.add_button ("Allow once", @"app.allow-permission::'$(request.id)'");
                    notification.add_button ("Reject", @"app.reject-permission::'$(request.id)'");
                    app.send_notification (@"perm-$session_id", notification);
                }
            } else {
                app.withdraw_notification (@"perm-$session_id");
            }
        });

        store.forms_changed.connect ((session_id) => {
            update_form_dock ();
            var form = store.pending_form_for (session_id);
            if (session_id == store.active_session_id) {
                composer.set_running (store.is_active_running, form != null ? "Answer the question above" : null);
            }
            if (form != null) {
                if (app.config.notifications_enabled && app.config.notify_questions
                    && (session_id != store.active_session_id || !is_active)) {
                    var notification = new GLib.Notification ("Input needed");
                    notification.set_body (@"$(session_title (session_id)): $(form.title)");
                    notification.set_icon (new ThemedIcon ("dialog-question"));
                    app.send_notification (@"question-$session_id", notification);
                }
            } else {
                app.withdraw_notification (@"question-$session_id");
            }
        });
    }

    /** Restores the footer after a rebuild when the open session's
     *  turn is still alive: working quips while the model runs, the
     *  matching waiting line while it is blocked on the user. */
    private void restore_pending_footer () {
        var store = app.store;
        if (store.active_session_id == null) {
            return;
        }
        switch (store.status_for (store.active_session_id)) {
            case "running":
                chat_view.show_pending ();
                break;
            case "waiting":
                chat_view.set_pending_state (ChatView.PendingState.WAITING_PERMISSION);
                break;
            case "question":
                chat_view.set_pending_state (ChatView.PendingState.WAITING_ANSWER);
                break;
            default:
                break;
        }
    }

    /** Replays a background session's in-flight turn into the fresh
     *  view: history lacks the partial reply, the live cache kept it. */    private void replay_live (string session_id) {
        var plan = app.store.build_replay (session_id);
        if (plan.size == 0) {
            return;
        }
        foreach (var entry in plan) {
            var bubble = chat_view.ensure_bubble (entry.message_id);
            if (entry.reasoning != "") {
                bubble.set_reasoning (entry.reasoning);
            }
            if (entry.text != "") {
                bubble.set_text (entry.text);
            }
            foreach (var tool in entry.tools) {
                chat_view.tool_started (tool.message_id, tool.call_id, tool.name);
                if (tool.input_summary != "") {
                    chat_view.tool_input (tool.message_id, tool.call_id, tool.input_summary);
                }
            }
        }
        chat_view.scroll_to_bottom ();
    }

    /** Pushes a session's live status + activity into its sidebar row
     *  (spinner over the model avatar + activity tooltip). */
    private void update_row_indicator (string session_id) {
        var store = app.store;
        sidebar.set_indicator (session_id, store.status_for (session_id), store.activity_for (session_id));
    }

    /** Refreshes the right-hand inspector when it is on screen.
     *  Coalesced: a turn fires several events per second (usage, tool,
     *  activity, status) and each one would otherwise re-walk the whole
     *  conversation and rebuild every row. One refresh per idle round
     *  is enough, and superseded requests are dropped. */
    private void refresh_panel () {
        if (!session_panel.visible) {
            return;
        }
        if (panel_source != 0) {
            return;
        }
        panel_source = GLib.Idle.add (() => {
            panel_source = 0;
            if (session_panel.visible) {
                session_panel.update ();
            }
            return false;
        });
    }

    /** Loads the counts the panel shows as "context sources". */
    private void load_context_sources () {
        var client = app.store.client;
        if (client == null) {
            return;
        }
        client.request.begin ("GET", "/api/skill", null, (obj, res) => {
            try {
                var root = client.request.end (res);
                var count = 0;
                foreach (var item in JsonUtil.root_objects (root)) {
                    count++;
                }
                app.store.skills_count = count;
            } catch (Error e) {
            }
            refresh_panel ();
        });
        client.request.begin ("GET", "/api/mcp", null, (obj, res) => {
            try {
                var root = client.request.end (res);
                var count = 0;
                foreach (var item in JsonUtil.root_objects (root)) {
                    count++;
                }
                session_panel.set_mcp_count (count);
            } catch (Error e) {
            }
            refresh_panel ();
        });
    }

    private string session_title (string session_id) {
        foreach (var session in app.store.sessions) {
            if (session.id == session_id) {
                return session.title;
            }
        }
        return "";
    }

    /** Desktop bubble when a turn ends somewhere the user is not
     *  looking (background session, or unfocused window). Watching
     *  users already get dividers and banners, so they are spared. */
    private void notify_turn_finished (string session_id) {
        if (!app.config.notifications_enabled || !app.config.notify_turns) {
            return;
        }
        if (session_id == app.store.active_session_id && is_active) {
            return;
        }
        var failed = app.store.outcome_for (session_id) == "failed";
        var notification = new GLib.Notification (failed ? "Turn failed" : "Turn finished");
        var title = session_title (session_id);
        notification.set_body (title != "" ? @"Ready in $title" : "The model finished its turn");
        notification.set_icon (new ThemedIcon (failed ? "dialog-error" : "process-completed"));
        app.send_notification (@"turn-$session_id", notification);
    }

    private void update_title () {
        /* Composing a new session: the header stays empty until the
         *  session actually starts (open_session clears the flag and
         *  refreshes the title). Otherwise the previous session's
         *  title would linger over the hero. */
        if (composing_new_session) {
            title_label.label = "";
            subtitle_label.label = "";
            subtitle_label.visible = false;
            composer.set_status_text ("");
            return;
        }
        var session = app.store.active_session;
        if (session == null) {
            title_label.label = "OpenCode";
            subtitle_label.label = "";
            subtitle_label.visible = false;
            composer.set_status_text ("");
            return;
        }

        title_label.label = session.title;

        var parts = new Gee.ArrayList<string> ();
        if (session.directory_name != "") {
            parts.add (session.directory_name);
        }
        if (session.agent != "") {
            parts.add (session.agent);
        }
        var joined = ListArrays.join (" · ", parts);
        subtitle_label.label = joined;
        subtitle_label.visible = joined != "";

        var status = new StringBuilder ();
        if (session.cost > 0) {
            status.append ("$%.4f".printf (session.cost));
        }
        if (session.input_tokens > 0) {
            if (status.len > 0) {
                status.append (" · ");
            }
            status.append (@"◊ $(Store.format_tokens (session.input_tokens)) in");
            if (session.output_tokens > 0) {
                status.append (@" / $(Store.format_tokens (session.output_tokens)) out");
            }
        }
        composer.set_status_text (status.str);
    }

    private void update_context_meter () {
        var store = app.store;
        if (store.active_session_id == null) {
            composer.set_context (-1.0, "");
            return;
        }
        /* One call resolves the session and the model once for both the
         *  bar and the label (they used to repeat the same lookups). */
        double fraction;
        string label;
        store.context_info (store.active_session_id, out fraction, out label);
        composer.set_context (fraction, label);
    }

    private void update_choosers () {
        var store = app.store;
        var session = store.active_session;
        if (session == null) {
            composer.model_chooser.sensitive = false;
            composer.agent_chooser.sensitive = false;
            composer.variant_chooser.visible = false;
            return;
        }
        composer.model_chooser.sensitive = true;
        composer.agent_chooser.sensitive = true;
        composer.model_chooser.set_current (session.provider_id, session.model_id);
        composer.agent_chooser.set_current (session.agent);

        var info = store.find_model (session.provider_id, session.model_id);
        if (info != null) {
            composer.variant_chooser.set_variants (info.variants, session.variant);
        } else {
            composer.variant_chooser.set_variants (new Gee.ArrayList<string> (), "");
        }
    }

    private void run_command (string name, string text) {
        var store = app.store;
        switch (name) {
            case "compact":
                if (store.active_session_id != null) {
                    store.compact_session.begin (store.active_session_id);
                }
                break;
            case "new":
                show_new_session ();
                break;
            case "diff":
                if (store.active_session_id != null) {
                    show_diff_dialog (store.active_session_id);
                }
                break;
            default:
                store.run_server_command.begin (name, text);
                break;
        }
    }

    private void update_permission_banner () {
        var store = app.store;
        if (store.active_session_id == null) {
            composer.hide_permission ();
            return;
        }
        var request = store.pending_permission_for (store.active_session_id);
        if (request != null) {
            composer.show_permission (request.id, request.describe ());
        } else {
            composer.hide_permission ();
        }
    }

    private void update_form_dock () {
        var store = app.store;
        if (store.active_session_id == null) {
            composer.hide_form ();
            return;
        }
        var form = store.pending_form_for (store.active_session_id);
        if (form != null) {
            composer.show_form (form);
        } else {
            composer.hide_form ();
        }
    }

    private async void start_connection () {
        if (!app.config.has_connection) {
            /* No server to talk to and no manual credentials: land on
             * Settings → Connection, the single place for both. */
            show_settings ();
            return;
        }

        content_stack.visible_child_name = "loading";
        set_loading_label (app.config.manage_server
            ? @"Starting the app server on port $(app.config.server_port)…"
            : "Connecting…");
        if (!yield app.ensure_connected ()) {
            content_stack.visible_child_name = "offline";
        }
    }

    /** The loading page's one line of text, so a slow server start is
     *  not mistaken for a hung app. */
    private void set_loading_label (string text) {
        if (loading_label != null) {
            loading_label.label = text;
        }
    }

    /** Opens the in-window settings page (T3-style) and reloads its
     *  server-side lists. The chat underneath is untouched. */
    /** Exports a session to a JSON file chosen through the save
     *  portal (sandbox-safe). */
    private async void export_session (string session_id) {
        string title = session_id;
        foreach (var session in app.store.sessions) {
            if (session.id == session_id) {
                title = session.title;
                break;
            }
        }
        var text = yield app.store.export_session_text (session_id);
        if (text == "") {
            app.store.notice ("Could not export session");
            return;
        }
        var safe = title.strip () != "" ? title.strip () : session_id;
        /* Keep the suggested filename filesystem-friendly. */
        string filename;
        try {
            filename = new GLib.Regex ("[^A-Za-z0-9._-]+", 0, 0).replace (safe, -1, 0, "-") + ".json";
        } catch (GLib.RegexError e) {
            filename = session_id + ".json";
        }
        if (yield Portals.save_file (@"Export $title", filename, text)) {
            app.store.notice ("Session exported");
        }
    }

    /** Confirms (once, for the whole batch) and deletes several
     *  sessions, then leaves selection mode. */
    private void delete_sessions (Gee.ArrayList<string> session_ids) {
        if (session_ids.size == 0) {
            return;
        }
        debug ("Bulk delete dialog for %d session(s)", session_ids.size);
        if (!app.config.confirm_delete) {
            app.store.delete_sessions.begin (session_ids);
            sidebar.end_selection ();
            return;
        }
        var dialog = new Gtk.AlertDialog (
            session_ids.size == 1
                ? "Delete this session?"
                : @"Delete $(session_ids.size) sessions?",
            "The conversations and their context will be permanently removed."
        );
        OpenClient.set_alert_buttons (dialog, new string[] { "Cancel", "Delete" });
        dialog.set_cancel_button (0);
        dialog.set_default_button (0);
        dialog.choose.begin (this, null, (obj, res) => {
            try {
                var response = dialog.choose.end (res);
                debug ("Bulk delete dialog response: %d", response);
                if (response == 1) {
                    app.store.delete_sessions.begin (session_ids);
                    sidebar.end_selection ();
                }
            } catch (Error e) {
            }
        });
    }

    private void show_settings () {
        end_stack.visible_child_name = "settings";
        settings_view.refresh ();
    }

    /** Returns to the chat page, restoring composer focus. */
    private void show_chat () {
        composing_new_session = false;
        if (session_panel != null) {
            session_panel.clear_placeholder ();
        }
        /* Leaving the new-session hero: highlight the open session
         * again (show_new_session re-clears it right after). */
        if (app.store.active_session_id != null) {
            sidebar.select (app.store.active_session_id);
        }
        if (end_stack.visible_child_name == "chat") {
            return;
        }
        end_stack.visible_child_name = "chat";
        if (app.store.active_session_id != null
            && empty_stack.visible_child_name == "chat") {
            composer.grab_focus_entry ();
        }
    }

    /** Opens the new-session page (model, folder + first message).
     *  Needs a connection; otherwise it detours to Settings. */
    private void show_new_session () {
        if (app.store.client == null) {
            app.store.notice ("Not connected. Check Settings.");
            show_settings ();
            return;
        }
        show_chat ();
        content_stack.visible_child_name = "content";
        empty_stack.visible_child_name = "new";
        /* No session exists yet: clear the sidebar highlight so no
         * existing session looks active, and keep the inspector empty
         * until the conversation actually starts. */
        composing_new_session = true;
        sidebar.deselect ();
        update_title ();
        session_panel.set_placeholder ("Session details will appear once the conversation starts.");
        var store = app.store;
        new_session_view.set_models (store.models);
        new_session_view.set_agents (store.agents);
        /* Continuity default: whatever the most recent session uses.
         * Displayed = applied, so there is never a silent mismatch. */
        if (store.sessions.size > 0) {
            var latest = store.sessions[0];
            new_session_view.set_default_selection (
                latest.provider_id, latest.model_id, latest.variant, latest.agent);
            var info = store.find_model (latest.provider_id, latest.model_id);
            if (info != null) {
                new_session_view.variant_chooser.set_variants (info.variants, latest.variant);
            }
        } else {
            new_session_view.set_default_selection ("", "", "", "");
        }
        new_session_view.reset (app.config.workspace_directory.strip ());
        var recents = new Gee.ArrayList<string> ();
        foreach (var existing in app.config.workspace_history) {
            if (existing.strip () != "") {
                recents.add (existing);
            }
        }
        new_session_view.set_recent_folders (recents);
    }

    private void show_rename_dialog (string session_id) {
        Session? target = null;
        foreach (var session in app.store.sessions) {
            if (session.id == session_id) {
                target = session;
                break;
            }
        }
        if (target == null) {
            return;
        }

        var dialog = new Gtk.Window () {
            transient_for = this,
            modal = true,
            resizable = false,
            title = "Rename Session",
            default_width = 400
        };
        var header = new Gtk.HeaderBar ();
        dialog.set_titlebar (header);

        var rename_button = new Gtk.Button.with_label ("Rename");
        rename_button.add_css_class ("suggested-action");
        header.pack_end (rename_button);

        var entry = new Gtk.Entry () {
            text = target.title,
            margin_top = 12,
            margin_bottom = 12,
            margin_start = 12,
            margin_end = 12,
            activates_default = true
        };
        dialog.child = entry;
        dialog.default_widget = rename_button;

        rename_button.clicked.connect (() => {
            app.store.rename_session.begin (session_id, entry.text);
            dialog.close ();
        });

        dialog.present ();
        entry.grab_focus ();
        entry.select_region (0, -1);
    }

    private void show_diff_dialog (string session_id) {
        Session? target = null;
        foreach (var session in app.store.sessions) {
            if (session.id == session_id) {
                target = session;
                break;
            }
        }
        if (target == null || app.store.client == null) {
            return;
        }

        var dialog = new DiffDialog (this, target.title);
        dialog.present ();

        var client = app.store.client;
        client.get_diff.begin (session_id, (obj, res) => {
            try {
                dialog.set_diffs (client.get_diff.end (res));
            } catch (Error e) {
                warning ("Diff failed: %s", e.message);
                show_toast (@"Could not load changes: $(e.message)");
                dialog.close ();
            }
        });
    }

    private void show_about () {
        Gtk.show_about_dialog (
            this,
            "program-name", "OpenCode Client",
            "version", "0.2.0",
            "comments", "A native OpenCode client for elementary OS",
            "license-type", Gtk.License.GPL_3_0,
            null
        );
    }
}

}
