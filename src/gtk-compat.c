/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * C shims for a handful of GTK/GDK/GLib entry points whose C prototypes
 * Vala 0.56 cannot express: they take a const-qualified array
 * (`const char * const *`) or a base-class widget, while Vala emits a
 * plain `gchar **` / the derived type. GCC 14+ rejects that mismatch
 * with a warning that neither -Wno- nor a pragma can switch off, so
 * those calls are made through these wrappers with an explicit cast.
 *
 * One exception: openclient_spawn_server_die_with_parent owns a small
 * fork/exec (prctl PR_SET_PDEATHSIG must run in the child between fork
 * and exec, which neither Vala nor GSubprocessLauncher can express).
 * Everything else is cast-and-forward: add an entry only for a new
 * vapi gap, and document the prototype it works around.
 *
 * See GtkCompat.vala for the Vala-side declarations.
 */

#include <gtk/gtk.h>
#include <gio/gio.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/wait.h>
#ifdef __linux__
#include <sys/prctl.h>
#ifndef PR_SET_PDEATHSIG
#define PR_SET_PDEATHSIG 1
#endif
#endif

/* GTK: gtk_alert_dialog_set_buttons (GtkAlertDialog *, const gchar * const *)
 * Vala passes its string arrays with an explicit length and WITHOUT a
 * NULL terminator; GTK reads a NULL-terminated list. Forwarding the raw
 * pointer reads past the end (garbage buttons, wrong response indices:
 * this broke every delete confirm). Copy with a terminator first.
 * The `n_*` parameters are Vala's array lengths. */
G_MODULE_EXPORT void
openclient_alert_dialog_set_buttons (GtkAlertDialog *dialog, char **buttons, int n_buttons)
{
	const gchar **terminated = g_alloca (sizeof (gchar *) * (n_buttons + 1));
	for (int i = 0; i < n_buttons; i++)
		terminated[i] = buttons[i];
	terminated[n_buttons] = NULL;
	gtk_alert_dialog_set_buttons (dialog, (const gchar * const *) terminated);
}

/* GTK: gtk_application_set_accels_for_action (GtkApplication *, const gchar *, const gchar * const *) */
G_MODULE_EXPORT void
openclient_application_set_accels_for_action (GtkApplication *app,
                                             const gchar *action,
                                             char **accels, int n_accels)
{
	const gchar **terminated = g_alloca (sizeof (gchar *) * (n_accels + 1));
	for (int i = 0; i < n_accels; i++)
		terminated[i] = accels[i];
	terminated[n_accels] = NULL;
	gtk_application_set_accels_for_action (app, action, (const gchar * const *) terminated);
}

/* GTK: gtk_menu_button_set_popover (GtkMenuButton *, GtkWidget *) */
G_MODULE_EXPORT void
openclient_menu_button_set_popover (GtkMenuButton *button, GtkWidget *popover)
{
	gtk_menu_button_set_popover (button, popover);
}

/* GTK: gtk_drop_down_new_from_strings (const gchar * const *) -> GtkWidget *
 * The widget comes back floating; sink it here because Vala treats an
 * extern's return as a transfer-full reference it owns. Same
 * NULL-termination copy as the dialog buttons above. */
G_MODULE_EXPORT GtkWidget *
openclient_drop_down_new_from_strings (char **strings, int n_strings)
{
	const gchar **terminated = g_alloca (sizeof (gchar *) * (n_strings + 1));
	for (int i = 0; i < n_strings; i++)
		terminated[i] = strings[i];
	terminated[n_strings] = NULL;
	return GTK_WIDGET (g_object_ref_sink (
		gtk_drop_down_new_from_strings ((const gchar * const *) terminated)));
}

/* KDResult relay: the Vala job object carries a "done" signal. */
static void
openclient_clipboard_read_done (GObject *source_object, GAsyncResult *res, gpointer user_data)
{
	g_signal_emit_by_name (user_data, "done", res);
}

/* GDK: gdk_clipboard_read_async (..., const gchar **mime_types, ...).
 * The mime list is built here so no array crosses into Vala. */
G_MODULE_EXPORT void
openclient_clipboard_read_mime (GdkClipboard *clipboard,
                                const gchar *mime_type,
                                gint io_priority,
                                GCancellable *cancellable,
                                gpointer job)
{
	const gchar *mime_types[2] = { mime_type, NULL };
	gdk_clipboard_read_async (clipboard, mime_types, io_priority, cancellable,
	                         openclient_clipboard_read_done, job);
}

/* GDK: gdk_clipboard_read_finish (..., const gchar **out_mime_type, ...) */
G_MODULE_EXPORT GInputStream *
openclient_clipboard_read_finish (GdkClipboard *clipboard,
                                  GAsyncResult *result,
                                  char **out_mime_type,
                                  GError **error)
{
	return gdk_clipboard_read_finish (clipboard, result, (const gchar **) out_mime_type, error);
}

/* GIO: g_file_load_contents (..., gchar **contents, ...) */
G_MODULE_EXPORT gboolean
openclient_file_load_contents (GFile *file,
                               GCancellable *cancellable,
                               char **contents,
                               gsize *length,
                               char **etag_out,
                               GError **error)
{
	return g_file_load_contents (file, cancellable, contents, length, etag_out, error);
}

/* Process: fork + exec `command serve --port <port>` with the passcode in
 * the environment and stdout/stderr appended to the log file.
 *
 * Unlike GSubprocessLauncher (which has no child-setup hook), the child
 * sets PR_SET_PDEATHSIG to SIGTERM between fork and exec, so the kernel
 * kills the server even when the app dies without running its shutdown
 * path (segfault, SIGKILL, power-cut-adjacent crashes). A stale server
 * from before this change has no such tie and is still adopted and
 * stopped on the next run (see ServerProcess).
 *
 * Returns the child pid, or -1 when fork failed. An exec failure exits
 * 127 in the child, which the caller detects as an early exit. */
G_MODULE_EXPORT pid_t
openclient_spawn_server_die_with_parent (const char *command,
                                         const char *port_str,
                                         const char *password,
                                         const char *cwd,
                                         const char *log_path)
{
	pid_t parent = getpid ();
	int log_fd = -1;
	if (log_path != NULL && log_path[0] != '\0')
		log_fd = open (log_path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
	/* Without a log file the server still runs; keep going. */
	pid_t pid = fork ();
	if (pid < 0)
	{
		if (log_fd >= 0)
			close (log_fd);
		return -1;
	}
	if (pid == 0)
	{
#ifdef __linux__
		prctl (PR_SET_PDEATHSIG, SIGTERM);
#endif
		/* Fork→prctl race: the parent died before the tie was set. */
		if (getppid () != parent)
			_exit (127);
		if (log_fd >= 0)
		{
			dup2 (log_fd, STDOUT_FILENO);
			dup2 (log_fd, STDERR_FILENO);
			if (log_fd > STDERR_FILENO)
				close (log_fd);
		}
		int null_fd = open ("/dev/null", O_RDONLY | O_CLOEXEC);
		if (null_fd >= 0)
		{
			dup2 (null_fd, STDIN_FILENO);
			if (null_fd > STDERR_FILENO)
				close (null_fd);
		}
		if (cwd != NULL && cwd[0] != '\0')
		{
			if (chdir (cwd) != 0)
				_exit (127);
		}
		if (password != NULL)
			setenv ("OPENCODE_PASSWORD", password, 1);
		execlp (command, command, "serve", "--port", port_str, (char *) NULL);
		_exit (127);
	}
	if (log_fd >= 0)
		close (log_fd);
	return pid;
}
