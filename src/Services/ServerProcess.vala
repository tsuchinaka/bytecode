/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Owns the `opencode serve` process this app runs.
 *
 * The app does not ask the user to start a server and paste its
 * password: it runs its own on a dedicated port with a passcode it
 * generated, so the endpoint is stable across runs and no other client
 * shares it. Spawning is idempotent — a server left behind by an
 * earlier run (crash, kill, predating die-with-parent) answers to the
 * same passcode and is simply adopted; the app still terminates it on
 * the way out, because it is the app's server. When the port is taken
 * by something that is not ours, the next free port is used and
 * remembered.
 *
 * Crash safety has two layers: servers spawned by this build carry
 * PR_SET_PDEATHSIG=SIGTERM, so the kernel kills them even when the app
 * dies without running shutdown (segfault, SIGKILL) — and any stale
 * server is adopted and stopped on the next run regardless.
 */

namespace OpenClient {

public enum ServerState {
    STOPPED,
    STARTING,
    RUNNING,
    FAILED
}

public class ServerProcess : GLib.Object {
    public signal void state_changed ();

    public ServerState state { get; private set; default = ServerState.STOPPED; }
    /** Human-readable reason for the current state (paths, errors). */
    public string detail { get; private set; default = ""; }
    /** The pid forked in this run, if any (tied to the app via
     *  PR_SET_PDEATHSIG, so it dies with us even on a crash). */
    private int child_pid = 0;
    /** PID of the server in use, adopted or spawned (from /api/info). */
    private int server_pid = 0;
    public string log_path { get; private set; default = ""; }

    private Config config;
    /** How many ports to try before giving up. */
    private const uint PORT_SCAN = 20;
    /** How long to wait for a spawned server to answer. */
    private const int READY_ATTEMPTS = 60;
    private const uint READY_INTERVAL_MS = 250;

    public ServerProcess (Config config) {
        this.config = config;
        log_path = GLib.Path.build_filename (Config.state_dir (), "serve.log");
    }

    /** Resolves the server command: an explicit path, or a name found
     *  on PATH, then the usual per-user install locations. */
    public static string? find_command (string configured) {
        var command = configured.strip ();
        if (command == "") {
            command = "opencode";
        }
        if (GLib.Path.is_absolute (command)) {
            return GLib.FileUtils.test (command, GLib.FileTest.IS_EXECUTABLE)
                ? command : null;
        }
        var on_path = GLib.Environment.find_program_in_path (command);
        if (on_path != null) {
            return on_path;
        }
        foreach (var candidate in new string[] {
            GLib.Path.build_filename (GLib.Environment.get_home_dir (), ".bun", "bin", command),
            "/usr/local/bin/" + command,
            "/usr/bin/" + command
        }) {
            if (GLib.FileUtils.test (candidate, GLib.FileTest.IS_EXECUTABLE)) {
                return candidate;
            }
        }
        return null;
    }

    /** True when the app's own server answers on its port. */
    public async bool probe () {
        return (yield probe_port (config.server_port)) == 200;
    }

    /** GET /api/info on @port: 200 when it is our server, another
     *  status when something else answers, 0 when nothing does. */
    private async int probe_port (uint port) {
        var session = new Soup.Session () {
            timeout = 2,
            idle_timeout = 2
        };
        var message = new Soup.Message ("GET", @"http://127.0.0.1:$port/api/info");
        message.request_headers.append ("Authorization",
            "Basic " + Base64.encode (("opencode:" + config.server_password).data));
        try {
            yield session.send_and_read_async (message, GLib.Priority.DEFAULT, null);
            return (int) message.status_code;
        } catch (Error e) {
            /* Nothing listening, or nothing answered in time. */
            return 0;
        }
    }

    /** Starts (or adopts) the app's server. Returns false with `detail`
     *  set when no usable server could be reached. */
    public async bool ensure_running () {
        config.ensure_server_password ();
        var command = find_command (config.server_command);
        if (command == null) {
            update_state (ServerState.FAILED,
                @"`$(config.server_command)` not found — set the server command in Settings → Connection");
            return false;
        }

        /* Already up (our own, from this or an earlier run)? */
        var status = yield probe_port (config.server_port);
        if (status == 200) {
            yield adopt ();
            return true;
        }

        /* Taken by something else: move to the next free port. */
        if (status != 0) {
            var free = yield find_free_port (config.server_port + 1);
            if (free == 0) {
                update_state (ServerState.FAILED,
                    @"Port $(config.server_port) is in use by another server and no alternative was free");
                return false;
            }
            config.server_port = free;
            config.save ();
        } else if (yield port_taken (config.server_port)) {
            var free = yield find_free_port (config.server_port + 1);
            if (free == 0) {
                update_state (ServerState.FAILED,
                    @"Port $(config.server_port) is in use and no alternative was free");
                return false;
            }
            config.server_port = free;
            config.save ();
        }

        return yield spawn (command);
    }

    /** Stops a server that is ours and starts a fresh one, so config or
     *  passcode changes take effect. */
    public async bool restart () {
        yield stop_owned ();
        return yield ensure_running ();
    }

    /** Ends the server this app is responsible for, synchronously: it
     *  runs from the application's shutdown hook, so it must not await.
     *  Signals to exit, waits briefly for the port to be released, then
     *  insists. Spawned servers normally die with the app already
     *  (PR_SET_PDEATHSIG); this path also covers adopted ones and the
     *  race where the kernel has not reaped ours yet. */
    public void shut_down () {
        var pid = child_pid > 0 ? child_pid : server_pid;
        /* Only a forked child can be reaped with waitpid; an adopted
         *  server is not ours (ECHILD), so kill(0) is the liveness
         *  check there. A zombie still answers kill(0), so ours must
         *  be polled with waitpid — which reaps the moment it exits. */
        var ours = child_pid > 0;
        if (pid > 0) {
            Posix.kill ((Posix.pid_t) pid, Posix.Signal.TERM);
            /* Up to a second to settle: the server writes its session
             *  database and closes the port. */
            for (int i = 0; i < 40; i++) {
                if (ours) {
                    if (reaped (pid)) {
                        pid = 0;
                        break;
                    }
                } else if (Posix.kill ((Posix.pid_t) pid, 0) != 0) {
                    pid = 0;
                    break;
                }
                GLib.Thread.usleep (25 * 1000);
            }
            if (pid > 0 && Posix.kill ((Posix.pid_t) pid, 0) == 0) {
                Posix.kill ((Posix.pid_t) pid, Posix.Signal.KILL);
            }
        }
        if (child_pid > 0) {
            /* Reap it so it cannot linger as a zombie. */
            reap (child_pid);
            child_pid = 0;
        }
        server_pid = 0;
        update_state (ServerState.STOPPED, "");
    }

    /** Reaps a forked child without blocking (best effort: after SIGKILL
     *  the child is gone or zombied, both of which waitpid releases). */
    private static void reap (int pid) {
        if (pid <= 0) {
            return;
        }
        int status;
        Posix.waitpid ((Posix.pid_t) pid, out status, Posix.WNOHANG);
    }

    /** True when a forked child has exited (reaping it). False while it
     *  is still running — or when it is not our child at all. */
    private static bool reaped (int pid) {
        if (pid <= 0) {
            return true;
        }
        int status;
        var result = Posix.waitpid ((Posix.pid_t) pid, out status, Posix.WNOHANG);
        if (result == pid) {
            return true;
        }
        return result < 0 && Posix.kill ((Posix.pid_t) pid, 0) != 0;
    }

    /** Stops whatever is on our port and answers to our passcode. */
    private async void stop_owned () {
        if (child_pid > 0) {
            terminate (child_pid, true);
            reap (child_pid);
            child_pid = 0;
        } else if (server_pid > 0) {
            terminate (server_pid);
        }
        server_pid = 0;
        /* Give it a moment to let go of the port. */
        for (int i = 0; i < 20; i++) {
            if (!yield port_taken (config.server_port)) {
                break;
            }
            yield delay (100);
        }
        if (state != ServerState.FAILED) {
            update_state (ServerState.STOPPED, "");
        }
    }

    /** SIGTERM, then SIGKILL if it is still around. Ours is polled
     *  with waitpid (a zombie still answers kill(0)); anything else
     *  with kill(0). */
    private static void terminate (int pid, bool ours = false) {
        if (pid <= 0) {
            return;
        }
        Posix.kill ((Posix.pid_t) pid, Posix.Signal.TERM);
        for (int i = 0; i < 20; i++) {
            if (ours) {
                if (reaped (pid)) {
                    return; /* gone */
                }
            } else if (Posix.kill ((Posix.pid_t) pid, 0) != 0) {
                return; /* gone */
            }
            GLib.Thread.usleep (50 * 1000);
        }
        Posix.kill ((Posix.pid_t) pid, Posix.Signal.KILL);
        if (ours) {
            reap (pid);
        }
    }

    /** Reads the adopted server's pid so it can be stopped later. */
    private async void adopt () {
        server_pid = yield fetch_pid ();
        update_state (ServerState.RUNNING, @"Adopted the server already on port $(config.server_port)");
    }

    private async int fetch_pid () {
        var session = new Soup.Session () { timeout = 3, idle_timeout = 3 };
        var message = new Soup.Message ("GET", @"http://127.0.0.1:$(config.server_port)/api/info");
        message.request_headers.append ("Authorization",
            "Basic " + Base64.encode (("opencode:" + config.server_password).data));
        try {
            var bytes = yield session.send_and_read_async (message, GLib.Priority.DEFAULT, null);
            var text = ((string) bytes.get_data ()).substring (0, (int) bytes.get_size ());
            var parser = new Json.Parser ();
            parser.load_from_data (text);
            var root = parser.get_root ();
            if (root != null && root.get_node_type () == Json.NodeType.OBJECT) {
                return (int) JsonUtil.int_member (root.get_object (), "pid", 0);
            }
        } catch (Error e) {
            debug ("Could not read server pid: %s", e.message);
        }
        return 0;
    }

    /** Runs `command serve --port <port>` with the passcode in the
     *  environment, then waits until it answers. The child carries
     *  PR_SET_PDEATHSIG=SIGTERM (see gtk-compat.c), so it dies with the
     *  app even on segfault/SIGKILL. */
    private async bool spawn (string command) {
        update_state (ServerState.STARTING, @"Starting `$command serve` on port $(config.server_port)…");

        GLib.DirUtils.create_with_parents (Config.state_dir (), 448); /* 0700 */
        var pid = spawn_server_die_with_parent (command,
            config.server_port.to_string (),
            config.server_password,
            GLib.Environment.get_home_dir (),
            log_path);
        if (pid <= 0) {
            update_state (ServerState.FAILED, @"Could not start `$command`: fork failed");
            return false;
        }
        child_pid = pid;
        for (int attempt = 0; attempt < READY_ATTEMPTS; attempt++) {
            if ((yield probe_port (config.server_port)) == 200) {
                server_pid = pid;
                update_state (ServerState.RUNNING,
                    @"Started on port $(config.server_port) (pid $server_pid)");
                return true;
            }
            if (reaped (pid)) {
                /* It gave up before answering: report why, from its log. */
                child_pid = 0;
                update_state (ServerState.FAILED,
                    @"The server exited during startup — $(log_tail ())");
                return false;
            }
            yield delay (READY_INTERVAL_MS);
        }

        /* Still not answering: stop what we started before reporting. */
        terminate (pid, true);
        reap (pid);
        child_pid = 0;
        update_state (ServerState.FAILED,
            @"The server did not answer on port $(config.server_port) within 15s — $(log_tail ())");
        return false;
    }

    /** Last line of the server log, for a failure message the user can
     *  act on without opening the file. */
    private string log_tail () {
        try {
            uint8[] contents;
            string? etag;
            /* Same vapi gap as the attachment loader: g_file_load_contents
             *  wants a char**, Vala emits uint8** (see gtk-compat.c). */
            file_load_contents_raw (GLib.File.new_for_path (log_path), null,
                out contents, out etag);
            var text = ((string) contents).substring (0, (int) contents.length).strip ();
            if (text == "") {
                return @"see $log_path";
            }
            var lines = text.split ("\n");
            var last = lines[lines.length - 1].strip ();
            return last != "" ? last : @"see $log_path";
        } catch (Error e) {
            return @"see $log_path";
        }
    }

    /** True when anything at all is listening on @port. */
    private async bool port_taken (uint port) {
        var client = new GLib.SocketClient ();
        try {
            var connection = yield client.connect_to_host_async ("127.0.0.1", (uint16) port, null);
            connection.close ();
            return true;
        } catch (Error e) {
            return false;
        }
    }

    /** First port at or above @from that nothing is listening on (0 when
     *  the scan is exhausted). */
    private async uint find_free_port (uint from) {
        for (uint port = from; port < from + PORT_SCAN && port <= 65535; port++) {
            if (!yield port_taken (port)) {
                return port;
            }
        }
        return 0;
    }

    private void update_state (ServerState next, string detail) {
        state = next;
        this.detail = detail;
        if (next == ServerState.FAILED) {
            warning ("Managed server: %s", detail);
        }
        state_changed ();
    }

    /** Waits without blocking the main loop. */
    private static async void delay (uint ms) {
        GLib.Timeout.add (ms, delay.callback);
        yield;
    }
}

}
