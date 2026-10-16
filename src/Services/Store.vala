/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Application state: the connected client, the session list, the
 * active conversation and live turn status. Wires SSE events into
 * view-friendly signals with primitive parameters only.
 */

namespace OpenClient {

public class PermissionRequest : GLib.Object {
    public string id { get; set; default = ""; }
    public string session_id { get; set; default = ""; }
    public string action { get; set; default = ""; }
    public string resources { get; set; default = ""; }

    public string describe () {
        var what = action != "" ? action : "action";
        var on = resources != "" ? resources : "*";
        return @"$what · $on";
    }
}

public class LiveTool : GLib.Object {
    public string call_id { get; set; default = ""; }
    public string message_id { get; set; default = ""; }
    public string session_id { get; set; default = ""; }
    public string name { get; set; default = ""; }
    public string input_summary { get; set; default = ""; }
    /** Path this tool is writing or editing, when it touches a file.
     *  Lets the UI mark a file as being changed right now. */
    public string file_path { get; set; default = ""; }
    public string output_text { get; set; default = ""; }
    public Gee.ArrayList<FileAttachment> files;
    public bool error { get; set; default = false; }
    public bool done { get; set; default = false; }

    public LiveTool () {
        files = new Gee.ArrayList<FileAttachment> ();
    }
}

public class Store : GLib.Object {
    /** How many finished tools to keep per session in live_tools. */
    private const int MAX_LIVE_TOOLS_PER_SESSION = 40;

    public signal void sessions_changed ();
    public signal void active_session_changed ();
    public signal void messages_loaded ();
    public signal void message_appended (Message message);
    public signal void assistant_started (string message_id, string model);
    public signal void text_delta (string message_id, string delta);
    public signal void text_done (string message_id, string text);
    public signal void reasoning_delta (string message_id, string delta);
    public signal void reasoning_done (string message_id, string text);
    public signal void status_changed (string session_id, string status);
    public signal void usage_updated ();
    public signal void connected (string version);
    public signal void connection_failed (string message);
    public signal void model_changed (string session_id);
    public signal void agent_changed (string session_id);
    public signal void permissions_changed (string session_id);
    public signal void catalog_changed ();
    public signal void forms_changed (string session_id);
    public signal void tool_changed (string message_id, string call_id, string phase);
    public signal void diffs_changed (string session_id);
    public signal void divider_changed (string session_id, string divider_id, string icon_name, string text, string status);
    public signal void divider_delta (string session_id, string divider_id, string delta);
    public signal void commands_changed ();
    public signal void notice (string message);
    /** An MCP server changed capabilities or connectivity. The MCP
     *  settings page reloads when it is visible. */
    public signal void mcp_changed ();
    public signal void session_title_changed (string session_id);
    /** A session's live activity label changed (what the model is
     *  doing right now). Drives the sidebar indicator + tooltip. */
    public signal void activity_changed (string session_id);

    public Config config;
    public Client? client = null;
    public EventStream? stream = null;
    /** Read-only tap on the background service for terminal-driven
     *  turns (see ServiceWatcher). Null until first connect. */
    public ServiceWatcher? service_watcher = null;

    public Gee.ArrayList<Session> sessions;
    public Gee.ArrayList<Message> active_messages;
    public Gee.ArrayList<ModelInfo> models;
    public Gee.ArrayList<AgentInfo> agents;
    public Gee.HashMap<string, string> statuses;
    public Gee.HashMap<string, PermissionRequest> pending_permissions;
    public Gee.HashMap<string, FormInfo> pending_forms;
    public Gee.HashMap<string, LiveTool> live_tools;
    public Gee.ArrayList<CommandInfo> commands;
    private Gee.HashMap<string, string> active_compaction;
    private Gee.HashMap<string, string> active_retry;
    /** Live activity label per session ("Running · Bash", "Waiting for
     *  permission", …). Empty/absent means nothing to show. */
    private Gee.HashMap<string, string> activities;
    /** Last turn outcome per session ("succeeded", "failed", …). */
    private Gee.HashMap<string, string> last_outcome;
    /** Provider error text from a failed step, shown once when the
     *  execution settles (see session.step.failed). */
    private Gee.HashMap<string, string> pending_error;
    /** id → Session. Sessions are looked up by id from every SSE event
     *  and every window update; keeping a hash index beside the list
     *  turns those O(S) scans into O(1) lookups (the list stays the
     *  authority for ordering/display). */
    private Gee.HashMap<string, Session> sessions_by_id;
    /** id → ModelInfo, same reasoning as sessions_by_id. */
    private Gee.HashMap<string, ModelInfo> models_by_id;
    /** call_id → session indexes of the live tools, so activity labels
     *  and prune sweeps touch only the calling session's tools instead
     *  of scanning every live tool in the app. */
    private Gee.HashMap<string, Gee.ArrayList<string>> live_tools_by_session;
    /** message ids currently in the active conversation, for the
     *  duplicate-guard scan in on_inbox_enqueued. */
    private Gee.HashSet<string> active_message_ids;
    /** Live turn buffers, keyed by session then message id. Deltas
     *  accumulate here for EVERY session (not just the open one) so
     *  switching away mid-turn and back replays the partial reply
     *  instead of showing a stale history. Pruned when the turn ends. */
    private Gee.HashMap<string, Gee.HashMap<string, LiveBuffer>> live_text;
    private Gee.HashMap<string, Gee.HashMap<string, LiveBuffer>> live_reasoning;
    /** Live message ids per session, in first-seen order (for replay). */
    private Gee.HashMap<string, Gee.ArrayList<string>> live_order;
    /** Membership companion to live_order (O(1) duplicate check on the
     *  per-delta path instead of a scan of the id list). */
    private Gee.HashMap<string, Gee.HashSet<string>> live_ids_seen;
    public int diff_files { get; private set; default = 0; }
    public int diff_additions { get; private set; default = 0; }
    public int diff_deletions { get; private set; default = 0; }
    public string diff_session_id { get; private set; default = ""; }
    /** The active session's changed files, one entry per path, in the
     *  order the server reported them. */
    public Gee.ArrayList<FileDiff> diff_list;
    /** Coalesced diff refresh (see schedule_diff_refresh). */
    private uint diff_refresh_source = 0;
    private string diff_refresh_pending = "";
    public int64 context_used_tokens { get; private set; default = -1; }
    public string context_used_session { get; private set; default = ""; }
    private bool refreshing_context = false;
    private int64 context_fetched_at = 0;
    private uint context_fetch_source = 0;
    /** A forced refresh requested while one was already in flight; the
     *  in-flight call restarts it when it finishes (compaction ends
     *  mid-fetch and must not be dropped). */
    private string context_refresh_pending = "";
    /** Count of this client's own prompt() calls awaiting their
     *  session.inbox.enqueued echo, per session. The SSE stream also
     *  delivers the client's own prompts (not just other clients'), so
     *  without this the GUI would bubble its own optimistic echo twice.
     *  Consumed by on_inbox_enqueued in event order. */
    private Gee.HashMap<string, int> self_echo;
    /** Debounced timer coalescing a burst of session.* events (e.g. the
     *  CLI creating several sessions at once) into a single list fetch. */
    private uint reload_source = 0;
    /** True while a session-list download is in flight, plus a
     *  "do it again" flag for events that arrived meanwhile. */
    private bool reloading = false;
    private bool reload_pending = false;
    /** True once the event stream's first connect has been consumed;
     *  later connects are reconnects that need a resync. */
    private bool stream_reconnected = false;
    public string? active_session_id = null;

    public Store (Config config) {
        this.config = config;
        sessions = new Gee.ArrayList<Session> ();
        active_messages = new Gee.ArrayList<Message> ();
        models = new Gee.ArrayList<ModelInfo> ();
        agents = new Gee.ArrayList<AgentInfo> ();
        statuses = new Gee.HashMap<string, string> ();
        pending_permissions = new Gee.HashMap<string, PermissionRequest> ();
        pending_forms = new Gee.HashMap<string, FormInfo> ();
        live_tools = new Gee.HashMap<string, LiveTool> ();
        commands = new Gee.ArrayList<CommandInfo> ();
        active_compaction = new Gee.HashMap<string, string> ();
        active_retry = new Gee.HashMap<string, string> ();
        activities = new Gee.HashMap<string, string> ();
        last_outcome = new Gee.HashMap<string, string> ();
        pending_error = new Gee.HashMap<string, string> ();
        live_text = new Gee.HashMap<string, Gee.HashMap<string, LiveBuffer>> ();
        live_reasoning = new Gee.HashMap<string, Gee.HashMap<string, LiveBuffer>> ();
        live_order = new Gee.HashMap<string, Gee.ArrayList<string>> ();
        live_ids_seen = new Gee.HashMap<string, Gee.HashSet<string>> ();
        self_echo = new Gee.HashMap<string, int> ();
        sessions_by_id = new Gee.HashMap<string, Session> ();
        models_by_id = new Gee.HashMap<string, ModelInfo> ();
        live_tools_by_session = new Gee.HashMap<string, Gee.ArrayList<string>> ();
        active_message_ids = new Gee.HashSet<string> ();
        diff_list = new Gee.ArrayList<FileDiff> ();
    }

    /** Session lookup by id: O(1) instead of a linear scan. Returns
     *  null for an unknown or cleared id. */
    public Session? session_for (string session_id) {
        return sessions_by_id.has_key (session_id) ? sessions_by_id[session_id] : null;
    }

    /** Clears the active conversation and its id index together. */
    private void clear_active_messages () {
        active_messages.clear ();
        active_message_ids.clear ();
    }

    /** Appends a message to the active conversation and its id index. */
    private void add_active_message (Message message) {
        active_messages.add (message);
        active_message_ids.add (message.id);
    }

    /** Rebuilds the id → Session index from `sessions`. */
    private void reindex_sessions () {
        sessions_by_id.clear ();
        foreach (var session in sessions) {
            sessions_by_id[session.id] = session;
        }
    }

    public Session? active_session {
        owned get {
            return active_session_id == null ? null : session_for (active_session_id);
        }
    }

    public bool is_active_running {
        get {
            if (active_session_id == null) {
                return false;
            }
            return status_for (active_session_id) == "running";
        }
    }

    public async void connect_and_load () {
        var new_client = new Client (config.effective_host, config.effective_port,
            config.effective_password);
        var version = yield new_client.version ();

        if (version == null) {
            connection_failed (@"Could not connect to $(new_client.base_url)");
            return;
        }

        client = new_client;

        if (stream != null) {
            stream.stop ();
        }
        stream = new EventStream (client.base_url, client.auth_header);
        stream.event_handler = on_event;
        stream_reconnected = false;
        stream.connected.connect (() => {
            /* First connect is handled explicitly below; every later
             * connect means we dropped and came back: the events that
             * were in flight while we were off the stream are gone, so
             * resync the session list and the open conversation. */
            if (!stream_reconnected) {
                stream_reconnected = true;
                return;
            }
            schedule_reload ();
            resync_active.begin ();
        });
        stream.start ();

        /* Terminal CLIs work on the background service, a different
         *  server sharing our session database: tap its events so
         *  their turns move our indicators too. */
        if (service_watcher == null) {
            service_watcher = new ServiceWatcher (config, this);
        }
        service_watcher.watch ();

        connected (version);

        try {
            yield reload_sessions ();
        } catch (Error e) {
            warning ("Failed to load sessions: %s", e.message);
        }

        if (active_session_id == null && sessions.size > 0) {
            yield open_session (sessions[0].id);
        }

        load_models.begin ();
        load_agents.begin ();
        load_commands.begin ();
    }

    public async void load_models () {
        if (client == null) {
            return;
        }
        try {
            var list = yield client.list_models ();
            models.clear ();
            models.add_all (dedupe_models (list));
            reindex_models ();
            catalog_changed ();
        } catch (Error e) {
            warning ("Failed to load models: %s", e.message);
        }
    }

    /** Rebuilds the id → ModelInfo index (first occurrence wins, which
     *  matches dedupe_models' ordering). */
    private void reindex_models () {
        models_by_id.clear ();
        foreach (var model in models) {
            if (!models_by_id.has_key (model.id)) {
                models_by_id[model.id] = model;
            }
        }
    }

    /** Collapses duplicate catalog entries so the picker shows each
     *  model once: the server lists the same model id under several
     *  providers (direct + gateway). First occurrence wins. */
    public static Gee.ArrayList<ModelInfo> dedupe_models (Gee.ArrayList<ModelInfo> input) {
        var unique = new Gee.ArrayList<ModelInfo> ();
        var seen = new Gee.HashSet<string> ();
        foreach (var model in input) {
            if (seen.add (model.id)) {
                unique.add (model);
            }
        }
        return unique;
    }

    public async void load_commands () {
        if (client == null) {
            return;
        }
        try {
            var list = yield client.list_commands ();
            commands.clear ();
            commands.add_all (list);
            commands_changed ();
        } catch (Error e) {
            warning ("Failed to load commands: %s", e.message);
        }
    }

    public async void run_server_command (string name, string text) {
        if (client == null || active_session_id == null) {
            return;
        }
        var session_id = active_session_id;
        var echo = text.strip () != "" ? @"/$name $(text.strip ())" : @"/$name";
        /* Server commands also land as inbox echoes on the stream. */
        self_echo[session_id] = (self_echo.has_key (session_id) ? self_echo[session_id] : 0) + 1;
        var optimistic = Message.user_message (@"local_$(GLib.get_monotonic_time ())", echo);
        if (active_session_id == session_id) {
            add_active_message (optimistic);
            message_appended (optimistic);
        }
        set_status (session_id, "running");
        try {
            yield client.execute_command (session_id, name, text);
        } catch (Error e) {
            var n = self_echo.has_key (session_id) ? self_echo[session_id] : 0;
            self_echo[session_id] = n > 0 ? n - 1 : 0;
            warning ("Command /%s failed: %s", name, e.message);
            notice (@"Command /$name failed: $(e.message)");
            if (session_id == active_session_id) {
                divider_changed (session_id,
                    @"cmd-failed-$(GLib.get_monotonic_time ())",
                    "dialog-error", @"Command /$name failed: $(e.message)", "error");
            }
        }
    }

    public async void load_agents () {
        if (client == null) {
            return;
        }
        try {
            var list = yield client.list_agents ();
            agents.clear ();
            var seen = new Gee.HashSet<string> ();
            foreach (var agent in list) {
                if (seen.add (agent.id)) {
                    agents.add (agent);
                }
            }
            catalog_changed ();
        } catch (Error e) {
            warning ("Failed to load agents: %s", e.message);
        }
    }

    /** Looks a model up by id. `models` is already deduplicated by id
     *  (a session may reference the half that lost, so matching is by
     *  id alone; provider_id stays for the call sites). */
    public ModelInfo? find_model (string provider_id, string model_id) {
        return models_by_id.has_key (model_id) ? models_by_id[model_id] : null;
    }

    public PermissionRequest? pending_permission_for (string session_id) {
        foreach (var request in pending_permissions.values) {
            if (request.session_id == session_id) {
                return request;
            }
        }
        return null;
    }

    public async void set_model (string session_id, string provider_id, string model_id, string variant) {
        if (client == null) {
            return;
        }
        try {
            yield client.set_model (session_id, provider_id, model_id, variant);
        } catch (Error e) {
            warning ("Failed to switch model: %s", e.message);
            return;
        }

        var session = session_for (session_id);
        if (session != null) {
            session.provider_id = provider_id;
            session.model_id = model_id;
            session.variant = variant;
            session.model = @"$provider_id/$model_id";
            if (variant != "") {
                session.model = @"$(session.model)#$variant";
            }
        }
        model_changed (session_id);
        sessions_changed ();
    }

    public async void set_agent (string session_id, string agent_id) {
        if (client == null) {
            return;
        }
        try {
            yield client.set_agent (session_id, agent_id);
        } catch (Error e) {
            warning ("Failed to switch agent: %s", e.message);
            return;
        }

        var session = session_for (session_id);
        if (session != null) {
            session.agent = agent_id;
        }
        agent_changed (session_id);
        sessions_changed ();
    }

    public async void set_permission_mode (string session_id, string mode) {
        if (client == null) {
            return;
        }

        var arr = new Json.Array ();
        if (mode == "readonly") {
            var deny = new Json.Object ();
            deny.set_string_member ("action", "*");
            deny.set_string_member ("resource", "*");
            deny.set_string_member ("effect", "deny");
            arr.add_object_element (deny);

            var read = new Json.Object ();
            read.set_string_member ("action", "read");
            read.set_string_member ("resource", "*");
            read.set_string_member ("effect", "allow");
            arr.add_object_element (read);

            var question = new Json.Object ();
            question.set_string_member ("action", "question");
            question.set_string_member ("resource", "*");
            question.set_string_member ("effect", "allow");
            arr.add_object_element (question);
        } else if (mode == "ask") {
            var ask = new Json.Object ();
            ask.set_string_member ("action", "*");
            ask.set_string_member ("resource", "*");
            ask.set_string_member ("effect", "ask");
            arr.add_object_element (ask);
        } else {
            var allow = new Json.Object ();
            allow.set_string_member ("action", "*");
            allow.set_string_member ("resource", "*");
            allow.set_string_member ("effect", "allow");
            arr.add_object_element (allow);
        }

        var node = new Json.Node (Json.NodeType.ARRAY);
        node.set_array (arr);

        try {
            yield client.set_permissions (session_id, node);
        } catch (Error e) {
            warning ("Failed to set permission mode: %s", e.message);
            notice (@"Could not change permission mode: $(e.message)");
            return;
        }

        var session = session_for (session_id);
        if (session != null) {
            session.permission_mode = mode;
        }
        permissions_changed (session_id);
        sessions_changed ();
    }

    public async void reply_permission (string session_id, string request_id, string decision) {
        if (client == null) {
            return;
        }
        try {
            yield client.reply_permission (session_id, request_id, decision);
        } catch (Error e) {
            warning ("Failed to reply to permission: %s", e.message);
            notice (@"Could not reply to permission: $(e.message)");
        }

        pending_permissions.unset (request_id);
        permissions_changed (session_id);
    }

    public async void rename_session (string session_id, string title) {
        if (client == null || title.strip () == "") {
            return;
        }
        try {
            yield client.rename_session (session_id, title.strip ());
        } catch (Error e) {
            warning ("Failed to rename session: %s", e.message);
            notice (@"Could not rename session: $(e.message)");
            return;
        }

        var session = session_for (session_id);
        if (session != null) {
            session.title = title.strip ();
        }
        sessions_changed ();
    }

    /** Reapplies the client-side pin/archive flags to fresh server
     *  objects (reloads rebuild the whole list) and prunes ids the
     *  server no longer knows, persisting when anything changed. */
    public void apply_session_flags () {
        var pinned = new Gee.HashSet<string> ();
        ListArrays.add_array (pinned, config.pinned_sessions);
        var archived = new Gee.HashSet<string> ();
        ListArrays.add_array (archived, config.archived_sessions);
        var known = new Gee.HashSet<string> ();
        foreach (var session in sessions) {
            known.add (session.id);
            session.pinned = pinned.contains (session.id);
            session.archived = archived.contains (session.id);
        }
        var kept_pinned = new Gee.ArrayList<string> ();
        foreach (var id in pinned) {
            if (known.contains (id)) {
                kept_pinned.add (id);
            }
        }
        var kept_archived = new Gee.ArrayList<string> ();
        foreach (var id in archived) {
            if (known.contains (id)) {
                kept_archived.add (id);
            }
        }
        if (kept_pinned.size != pinned.size || kept_archived.size != archived.size) {
            config.pinned_sessions = ListArrays.to_string_array (kept_pinned);
            config.archived_sessions = ListArrays.to_string_array (kept_archived);
            config.save ();
        }
    }

    /** Syncs one flag id-set back to config + disk. */
    private void persist_session_flags (Gee.HashSet<string> ids, bool pinned_side) {
        var ordered = new Gee.ArrayList<string> ();
        /* Keep server order so the file stays readable. */
        foreach (var session in sessions) {
            if (ids.contains (session.id)) {
                ordered.add (session.id);
            }
        }
        foreach (var id in ids) {
            if (!ordered.contains (id)) {
                ordered.add (id);
            }
        }
        if (pinned_side) {
            config.pinned_sessions = ListArrays.to_string_array (ordered);
        } else {
            config.archived_sessions = ListArrays.to_string_array (ordered);
        }
        config.save ();
    }

    public void set_pinned (string session_id, bool pinned_flag) {
        var session = session_for (session_id);
        if (session != null) {
            session.pinned = pinned_flag;
        }
        var ids = new Gee.HashSet<string> ();
        ListArrays.add_array (ids, config.pinned_sessions);
        if (pinned_flag) {
            ids.add (session_id);
        } else {
            ids.remove (session_id);
        }
        persist_session_flags (ids, true);
        sessions_changed ();
    }

    public void set_archived (string session_id, bool archived_flag) {
        var session = session_for (session_id);
        if (session != null) {
            session.archived = archived_flag;
        }
        var ids = new Gee.HashSet<string> ();
        ListArrays.add_array (ids, config.archived_sessions);
        if (archived_flag) {
            ids.add (session_id);
        } else {
            ids.remove (session_id);
        }
        persist_session_flags (ids, false);
        sessions_changed ();
    }

    public async void fork_session (string session_id) {
        if (client == null) {
            return;
        }
        try {
            var fork = yield client.fork_session (session_id);
            if (fork != null) {
                sessions.insert (0, fork);
                sessions_by_id[fork.id] = fork;
                sessions_changed ();
                yield open_session (fork.id);
            } else {
                yield reload_sessions ();
            }
        } catch (Error e) {
            warning ("Failed to fork session: %s", e.message);
            notice (@"Could not fork session: $(e.message)");
        }
    }

    public async void compact_session (string session_id) {
        if (client == null) {
            return;
        }
        try {
            yield client.compact_session (session_id);
            notice ("Context compaction started");
        } catch (Error e) {
            warning ("Failed to compact session: %s", e.message);
            notice (@"Could not compact context: $(e.message)");
        }
    }

    public async void reply_form (string session_id, string form_id, Json.Node answer) {
        if (client == null) {
            return;
        }
        try {
            yield client.reply_form (session_id, form_id, answer);
        } catch (Error e) {
            warning ("Failed to reply to form: %s", e.message);
            notice (@"Could not send answer: $(e.message)");
            return;
        }

        pending_forms.unset (form_id);
        forms_changed (session_id);
    }

    public async void cancel_form (string session_id, string form_id, string message = "") {
        if (client == null) {
            return;
        }
        try {
            yield client.cancel_form (session_id, form_id, message);
        } catch (Error e) {
            warning ("Failed to cancel form: %s", e.message);
            notice (@"Could not dismiss question: $(e.message)");
            return;
        }
        pending_forms.unset (form_id);
        forms_changed (session_id);
    }

    public LiveTool? live_tool_for (string call_id) {
        return live_tools.has_key (call_id) ? live_tools[call_id] : null;
    }

    public async void refresh_diff_stat (string session_id) {
        if (client == null) {
            return;
        }
        try {
            var fetched = yield client.get_diff (session_id);
            /* One entry per path: the server aggregates a file's hunks
             *  already, and this keeps the list free of duplicates when
             *  it does not (renames, repeated writes). */
            var by_path = new Gee.HashMap<string, FileDiff> ();
            var order = new Gee.ArrayList<string> ();
            foreach (var diff in fetched) {
                if (!by_path.has_key (diff.path)) {
                    order.add (diff.path);
                }
                by_path[diff.path] = diff;
            }
            diff_list.clear ();
            var additions = 0;
            var deletions = 0;
            foreach (var path in order) {
                var diff = by_path[path];
                diff_list.add (diff);
                additions += diff.additions;
                deletions += diff.deletions;
            }
            diff_session_id = session_id;
            diff_files = diff_list.size;
            diff_additions = additions;
            diff_deletions = deletions;
            diffs_changed (session_id);
        } catch (Error e) {
            debug ("Diff stat failed: %s", e.message);
        }
    }

    /** Coalesces diff refreshes: a turn settles several file-writing
     *  tools, and each one used to mean its own round trip. */
    public void schedule_diff_refresh (string session_id) {
        if (client == null || session_id == "" || session_id != active_session_id) {
            return;
        }
        diff_refresh_pending = session_id;
        if (diff_refresh_source != 0) {
            return;
        }
        diff_refresh_source = GLib.Timeout.add (300, () => {
            diff_refresh_source = 0;
            var pending = diff_refresh_pending;
            diff_refresh_pending = "";
            if (pending != "") {
                refresh_diff_stat.begin (pending);
            }
            return false;
        });
    }

    /** Paths a file-mutating tool is working on right now, so the UI
     *  can show a file as being changed before the diff catches up. */
    public Gee.ArrayList<string> editing_paths_for (string session_id) {
        var paths = new Gee.ArrayList<string> ();
        foreach (var tool in live_tools.values) {
            if (tool.done || tool.session_id != session_id || tool.file_path == "") {
                continue;
            }
            if (!paths.contains (tool.file_path)) {
                paths.add (tool.file_path);
            }
        }
        return paths;
    }

    /** True for the tools that write a file. */
    public static bool is_file_mutation (string tool) {
        return tool == "write" || tool == "edit" || tool == "patch" || tool == "multiedit";
    }

    /** Path a file-mutating tool targets, or "" when it does not touch
     *  one. */
    public static string tool_file_path (string tool, Json.Object? input) {
        if (input == null || !is_file_mutation (tool)) {
            return "";
        }
        foreach (var key in new string[] { "filePath", "path", "file", "uri" }) {
            var value = JsonUtil.string_member (input, key);
            if (value != null && value.strip () != "") {
                return value.strip ();
            }
        }
        return "";
    }

    public async void refresh_context_usage (string session_id, bool force = false) {
        if (client == null) {
            return;
        }
        if (refreshing_context) {
            /* A fetch is already running; remember a forced request so
             * the fresh value is fetched right after it lands. */
            if (force) {
                context_refresh_pending = session_id;
            }
            return;
        }
        /* The context payload is megabytes of full message text; don't
         * refetch for a recently measured session unless forced (e.g.
         * right after compaction shrinks the window). */
        var now = GLib.get_monotonic_time ();
        if (!force && session_id == context_used_session && now - context_fetched_at < 60 * 1000 * 1000) {
            return;
        }
        refreshing_context = true;
        var used = yield client.context_used (session_id);
        refreshing_context = false;
        if (used >= 0 && session_id == active_session_id) {
            context_used_tokens = used;
            context_used_session = session_id;
            context_fetched_at = GLib.get_monotonic_time ();
            usage_updated ();
        }
        if (context_refresh_pending != "") {
            var pending = context_refresh_pending;
            context_refresh_pending = "";
            refresh_context_usage.begin (pending, true);
        }
    }

    /** Schedules a context refresh after first paint so the megabyte
     *  download never competes with message rendering. Superseded
     *  schedules are cancelled. */
    public void refresh_context_usage_soon (string session_id) {
        if (context_fetch_source != 0) {
            GLib.Source.remove (context_fetch_source);
            context_fetch_source = 0;
        }
        context_fetch_source = GLib.Timeout.add (600, () => {
            context_fetch_source = 0;
            if (session_id == active_session_id) {
                refresh_context_usage.begin (session_id);
            }
            return false;
        });
    }

    /** Fraction of the model's context window used (0..1), or -1 when unknown.
     *  The service computes the value and the label together so a single
     *  update resolves the session and the model once. */
    public bool context_info (string session_id, out double fraction, out string label) {
        fraction = -1.0;
        label = "";
        var session = session_for (session_id);
        if (session == null) {
            return false;
        }
        var info = find_model (session.provider_id, session.model_id);
        if (info == null || info.context_limit <= 0) {
            return false;
        }
        if (context_used_session != session_id || context_used_tokens < 0) {
            return false;
        }
        fraction = double.min (1.0, (double) context_used_tokens / (double) info.context_limit);
        label = @"$(format_tokens (context_used_tokens)) / $(format_tokens (info.context_limit))";
        return true;
    }

    public double context_fraction (string session_id) {
        double fraction;
        string label;
        context_info (session_id, out fraction, out label);
        return fraction;
    }

    public string context_label (string session_id) {
        double fraction;
        string label;
        context_info (session_id, out fraction, out label);
        return label;
    }

    public static string format_tokens (int64 tokens) {
        if (tokens >= 1000000) {
            return "%.1fM".printf (tokens / 1000000.0);
        }
        if (tokens >= 1000) {
            return "%.1fk".printf (tokens / 1000.0);
        }
        return tokens.to_string ();
    }

    public async void reload_sessions () throws RequestError {
        if (client == null) {
            return;
        }
        var list = yield client.list_sessions ();
        sessions.clear ();
        sessions.add_all (list);
        reindex_sessions ();

        /* keep only statuses for known sessions. One id set serves every
         * sweep below: building it once makes the whole block O(S + K)
         * instead of O(K × S). */
        var known = new Gee.HashSet<string> ();
        foreach (var session in sessions) {
            known.add (session.id);
        }
        var stale = new Gee.ArrayList<string> ();
        foreach (var key in statuses.keys) {
            if (!known.contains (key)) {
                stale.add (key);
            }
        }
        foreach (var key in stale) {
            statuses.unset (key);
        }
        var stale_activity = new Gee.ArrayList<string> ();
        foreach (var key in activities.keys) {
            if (!known.contains (key)) {
                stale_activity.add (key);
            }
        }
        foreach (var key in stale_activity) {
            activities.unset (key);
        }
        var stale_outcome = new Gee.ArrayList<string> ();
        foreach (var key in last_outcome.keys) {
            if (!known.contains (key)) {
                stale_outcome.add (key);
            }
        }
        foreach (var key in stale_outcome) {
            last_outcome.unset (key);
        }
        var stale_error = new Gee.ArrayList<string> ();
        foreach (var key in pending_error.keys) {
            if (!known.contains (key)) {
                stale_error.add (key);
            }
        }
        foreach (var key in stale_error) {
            pending_error.unset (key);
        }
        /* Drop live turn buffers (and unfinished tools) for sessions
         * that no longer exist. */
        var stale_live = new Gee.ArrayList<string> ();
        foreach (var key in live_order.keys) {
            if (!known.contains (key)) {
                stale_live.add (key);
            }
        }
        foreach (var key in stale_live) {
            prune_live (key);
        }
        var stale_tools = new Gee.ArrayList<string> ();
        foreach (var entry in live_tools_by_session.entries) {
            if (!known.contains (entry.key)) {
                stale_tools.add (entry.key);
            }
        }
        foreach (var session_id in stale_tools) {
            var call_ids = live_tools_by_session[session_id];
            foreach (var call_id in call_ids) {
                live_tools.unset (call_id);
            }
            live_tools_by_session.unset (session_id);
        }
        /* Keep the tool output retained by the surviving sessions
         *  bounded (see cap_live_tools). */
        cap_live_tools ();

        /* Fresh server objects lose client-side flags: reapply. */
        apply_session_flags ();

        sessions_changed ();
    }

    /** Schedules one session-list reload at most; bursts of session.*
     *  events (the CLI creating several sessions, a rename right after
     *  a create, …) all collapse into this single fetch so the sidebar
     *  updates once instead of thrashing one round-trip per event. */
    private void schedule_reload () {
        if (reload_pending || reloading) {
            /* A fetch is in flight (or one is already scheduled behind
             * it): one extra refresh after the current one lands is
             * enough, so a burst of events never issues a second full
             * session-list download. */
            reload_pending = true;
            return;
        }
        if (reload_source != 0) {
            return;
        }
        reload_source = GLib.Timeout.add (120, () => {
            reload_source = 0;
            if (client != null) {
                run_reload.begin ();
            }
            return false;
        });
    }

    /** Runs one session-list reload, restarting once if events arrived
     *  while it was in flight. Serializes the debounced requests so a
     *  burst of session.* events results in one download at a time. */
    private async void run_reload () {
        reloading = true;
        reload_pending = false;
        try {
            yield reload_sessions ();
        } catch (Error e) {
            debug ("Session reload failed: %s", e.message);
        }
        reloading = false;
        if (reload_pending) {
            run_reload.begin ();
        }
    }

    /** Re-pulls the messages of the open session. Used to reconcile
     *  state after the event stream drops and reconnects (or the app
     *  regains focus with a stale stream). */
    public async void resync_active () {
        if (client == null || active_session_id == null) {
            return;
        }
        var session_id = active_session_id;
        try {
            var messages = yield client.list_messages (session_id);
            if (session_id != active_session_id) {
                return; /* user switched while the fetch was in flight */
            }
            clear_active_messages ();
            active_messages.add_all (messages);
            foreach (var existing in messages) {
                active_message_ids.add (existing.id);
            }
            messages_loaded ();
        } catch (Error e) {
            warning ("Resync failed: %s", e.message);
        }
    }

    /** Handles session.inbox.enqueued: the canonical source of truth
     *  for "a user message landed", including prompts submitted from
     *  the CLI or another client, which the GUI has no other signal
     *  for. The sender's own optimistic echo is swallowed (see
     *  self_echo) so a GUI send renders exactly one bubble. */
    private void on_inbox_enqueued (string session_id, Json.Object data) {
        /* Swallow this client's own prompt echo first, in event order:
         * for any session, not just the open one (the user may have
         * switched while the POST was in flight). */
        var pending = self_echo.has_key (session_id) ? self_echo[session_id] : 0;
        if (pending > 0) {
            self_echo[session_id] = pending - 1;
            return;
        }

        if (session_id != active_session_id) {
            return;
        }

        var inbox_id = JsonUtil.string_member (data, "inboxID");
        var item = JsonUtil.object_member (data, "item");
        var item_type = item != null ? (JsonUtil.string_member (item, "type") ?? "") : "";
        if (item_type != "user" || inbox_id == null) {
            return;
        }

        var text = "";
        var payload = JsonUtil.object_member (item, "payload");
        if (payload != null) {
            text = JsonUtil.string_member (payload, "text") ?? "";
        }
        if (text == "") {
            return;
        }

        /* Guard against a duplicate bubble (e.g. a resync raced us). */
        if (active_message_ids.contains (inbox_id)) {
            return;
        }

        var message = Message.user_message (inbox_id, text);
        active_messages.add (message);
        active_message_ids.add (inbox_id);
        message_appended (message);
    }

    public async void open_session (string session_id) {
        if (client == null) {
            return;
        }

        active_session_id = session_id;
        active_session_changed ();

        clear_active_messages ();
        messages_loaded ();

        try {
            var messages = yield client.list_messages (session_id);
            if (session_id != active_session_id) {
                return; /* user switched again while loading: dropping
                         * these prevents another session's history from
                         * leaking into the open conversation */
            }
            active_messages.add_all (messages);
            foreach (var existing in messages) {
                active_message_ids.add (existing.id);
            }
            messages_loaded ();
        } catch (Error e) {
            warning ("Failed to load messages: %s", e.message);
        }

        load_pending_forms.begin (session_id);
        refresh_context_usage_soon (session_id);
        /* Tell the server the session is being viewed so its unread
         *  tracking settles; failure is silent (best effort). */
        mark_viewed.begin (session_id);
    }

    private async void mark_viewed (string session_id) {
        if (client == null) {
            return;
        }
        try {
            yield client.mark_viewed (session_id);
        } catch (Error e) {
            debug ("mark_viewed failed: %s", e.message);
        }
    }

    /** Full session export as pretty JSON text (for the Export
     *  action's save dialog). Empty string when it cannot be built. */
    public async string export_session_text (string session_id) {
        if (client == null) {
            return "";
        }
        try {
            var root = yield client.export_session (session_id, true);
            var generator = new Json.Generator ();
            generator.set_pretty (true);
            generator.set_root (root);
            size_t length;
            return generator.to_data (out length);
        } catch (Error e) {
            warning ("Export failed: %s", e.message);
            return "";
        }
    }


    public async void load_pending_forms (string session_id) {
        if (client == null) {
            return;
        }
        try {
            var forms = yield client.list_forms (session_id);
            var changed = false;

            var stale = new Gee.ArrayList<string> ();
            foreach (var entry in pending_forms.entries) {
                if (entry.value.session_id == session_id) {
                    stale.add (entry.key);
                }
            }
            foreach (var key in stale) {
                pending_forms.unset (key);
                changed = true;
            }

            foreach (var form in forms) {
                pending_forms[form.id] = form;
                changed = true;
            }

            if (changed) {
                forms_changed (session_id);
            }
        } catch (Error e) {
            warning ("Failed to load pending forms: %s", e.message);
        }
    }

    public FormInfo? pending_form_for (string session_id) {
        foreach (var form in pending_forms.values) {
            if (form.session_id == session_id) {
                return form;
            }
        }
        return null;
    }

    /** Creates a session in @directory, falling back to the configured
     *  workspace folder, then to the server default. */
    public async void create_session (string? directory = null) {
        if (client == null) {
            return;
        }
        var dir = directory;
        if ((dir == null || dir.strip () == "") && config.workspace_directory.strip () != "") {
            dir = config.workspace_directory.strip ();
        }
        try {
            var session = yield client.create_session (null, dir);
            if (session != null) {
                sessions.insert (0, session);
                sessions_by_id[session.id] = session;
                sessions_changed ();
                yield open_session (session.id);
            }
        } catch (Error e) {
            warning ("Failed to create session: %s", e.message);
        }
    }

    /** New-session page flow: create in @directory (required, already
     *  validated by the view), apply an explicit model/agent when the
     *  pickers chose one, then send the first prompt right away. */
    public async void create_session_with_prompt (string directory, string text,
        string provider_id = "", string model_id = "", string variant = "", string agent_id = "",
        Gee.ArrayList<FileAttachment>? files = null) {
        if (client == null || (text.strip () == "" && (files == null || files.size == 0))) {
            return;
        }
        try {
            var session = yield client.create_session (null, directory);
            if (session == null) {
                notice ("Could not create session");
                return;
            }
            sessions.insert (0, session);
            sessions_by_id[session.id] = session;
            sessions_changed ();
            if (provider_id != "" && model_id != "") {
                yield set_model (session.id, provider_id, model_id, variant);
            }
            if (agent_id != "") {
                yield set_agent (session.id, agent_id);
            }
            yield open_session (session.id);
            yield send_prompt (text, files);
        } catch (Error e) {
            warning ("Failed to create session: %s", e.message);
            notice (@"Could not create session: $(e.message)");
        }
    }

    public async void delete_session (string session_id) {
        if (client == null) {
            return;
        }
        try {
            yield client.delete_session (session_id);
        } catch (Error e) {
            warning ("Failed to delete session: %s", e.message);
            notice (@"Could not delete session: $(e.message)");
            return;
        }

        var gone = new Gee.ArrayList<string> ();
        gone.add (session_id);
        forget_sessions (gone);
        sessions_changed ();
        /* Reconcile with server truth: if the local list ever diverged
         *  (missed events, partial failures), the display settles on
         *  what the server actually has. */
        try {
            yield reload_sessions ();
        } catch (Error e) {
            debug ("Post-delete reload failed: %s", e.message);
        }
    }

    /** Deletes several sessions, one round trip each. A failure does not
     *  stop the rest, and the outcome is reported once. */
    public async void delete_sessions (Gee.ArrayList<string> session_ids) {
        if (client == null || session_ids.size == 0) {
            return;
        }
        var gone = new Gee.ArrayList<string> ();
        var failed = 0;
        foreach (var session_id in session_ids) {
            try {
                yield client.delete_session (session_id);
                gone.add (session_id);
            } catch (Error e) {
                failed++;
                warning ("Failed to delete session %s: %s", session_id, e.message);
            }
        }

        if (gone.size == 0) {
            notice (@"Could not delete $(failed) session(s)");
            return;
        }
        forget_sessions (gone);
        notice (failed == 0
            ? @"Deleted $(gone.size) sessions"
            : @"Deleted $(gone.size) sessions, $(failed) failed");
        sessions_changed ();
        /* Reconcile with server truth (see delete_session). */
        try {
            yield reload_sessions ();
        } catch (Error e) {
            debug ("Post-delete reload failed: %s", e.message);
        }
    }

    /** Drops sessions from the local state: the list and its index, live
     *  buffers and tools, their pin/archive flags, and the open
     *  conversation when it was one of them. */
    private void forget_sessions (Gee.Collection<string> session_ids) {
        var gone = new Gee.HashSet<string> ();
        foreach (var session_id in session_ids) {
            gone.add (session_id);
            prune_live (session_id);
            if (live_tools_by_session.has_key (session_id)) {
                foreach (var call_id in live_tools_by_session[session_id]) {
                    live_tools.unset (call_id);
                }
                live_tools_by_session.unset (session_id);
            }
            sessions_by_id.unset (session_id);
        }

        for (int i = sessions.size - 1; i >= 0; i--) {
            if (gone.contains (sessions[i].id)) {
                sessions.remove_at (i);
            }
        }

        /* Deleted sessions take their flags with them. */
        var pinned = new Gee.HashSet<string> ();
        ListArrays.add_array (pinned, config.pinned_sessions);
        var archived = new Gee.HashSet<string> ();
        ListArrays.add_array (archived, config.archived_sessions);
        var flags_changed = false;
        foreach (var session_id in gone) {
            if (pinned.remove (session_id) || archived.remove (session_id)) {
                flags_changed = true;
            }
        }
        if (flags_changed) {
            config.pinned_sessions = ListArrays.to_string_array (pinned);
            config.archived_sessions = ListArrays.to_string_array (archived);
            config.save ();
        }

        if (active_session_id != null && gone.contains (active_session_id)) {
            active_session_id = null;
            clear_active_messages ();
            active_session_changed ();
            messages_loaded ();
        }
    }

    public async void send_prompt (string text, Gee.ArrayList<FileAttachment>? files = null) {
        if (client == null || active_session_id == null) {
            return;
        }
        if (text.strip () == "" && (files == null || files.size == 0)) {
            return;
        }

        var session_id = active_session_id;
        /* The stream also echoes this client's own prompts back through
         * session.inbox.enqueued; count it so that echo is swallowed and
         * we don't double-bubble the message. */
        self_echo[session_id] = (self_echo.has_key (session_id) ? self_echo[session_id] : 0) + 1;

        /* Optimistic echo: the user bubble (and the running state)
         * render instantly, without waiting for the POST round-trip.
         * The local id is never referenced by later server events
         * (stream deltas key off assistant ids) and history reloads
         * clear the view, so no reconciliation is needed. */
        var optimistic = Message.user_message (@"local_$(GLib.get_monotonic_time ())", text);
        if (files != null) {
            foreach (var file in files) {
                optimistic.parts.add (new MessagePart () {
                    kind = PartKind.FILE,
                    file = file
                });
            }
        }
        if (active_session_id == session_id) {
            add_active_message (optimistic);
            message_appended (optimistic);
        }
        set_status (session_id, "running");

        try {
            yield client.prompt (session_id, text, files);
        } catch (Error e) {
            /* The server rejected it, so no inbox echo will arrive:
             * drop the count so a later real prompt isn't swallowed. */
            var n = self_echo.has_key (session_id) ? self_echo[session_id] : 0;
            self_echo[session_id] = n > 0 ? n - 1 : 0;
            warning ("Prompt failed: %s", e.message);
            notice (@"Could not send message: $(e.message)");
            /* The optimistic bubble stays, but the turn never starts:
             * mark the failure visibly so it isn't mistaken for a
             * hanging request. */
            if (session_id == active_session_id) {
                divider_changed (session_id,
                    @"send-failed-$(GLib.get_monotonic_time ())",
                    "dialog-error", @"Could not send message: $(e.message)", "error");
            }
        }
    }

    public async void interrupt () {
        if (client == null || active_session_id == null) {
            return;
        }
        try {
            yield client.interrupt (active_session_id);
        } catch (Error e) {
            warning ("Interrupt failed: %s", e.message);
        }
    }

    public void stop_or_interrupt () {
        if (client == null || !is_active_running) {
            return;
        }
        interrupt.begin ();
    }

    public string status_for (string session_id) {
        return statuses.has_key (session_id) ? statuses[session_id] : "idle";
    }

    /** Live activity label for the sidebar indicator ("" when idle). */
    public string activity_for (string session_id) {
        return activities.has_key (session_id) ? activities[session_id] : "";
    }

    /** Last turn outcome for a session ("" when unknown). */
    public string outcome_for (string session_id) {
        return last_outcome.has_key (session_id) ? last_outcome[session_id] : "";
    }

    /** Human-readable text of an event's error object (message,
     *  falling back to type), or "" when there is none. */
    private string error_message (Json.Object data) {
        var err = JsonUtil.object_member (data, "error");
        if (err == null) {
            return "";
        }
        var message = JsonUtil.string_member (err, "message") ?? "";
        if (message != "") {
            return message;
        }
        return JsonUtil.string_member (err, "type") ?? "";
    }

    /** Accumulated live text per message id for a session ("" map
     *  when nothing is in flight). Powers switch-away-and-back replay. */
    public Gee.HashMap<string, string> live_text_for (string session_id) {
        return materialize_live (live_text, session_id);
    }

    public Gee.HashMap<string, string> live_reasoning_for (string session_id) {
        return materialize_live (live_reasoning, session_id);
    }

    /** Snapshots a session's StringBuilder buffers into plain strings
     *  for the (rare) replay path. */
    private static Gee.HashMap<string, string> materialize_live (
        Gee.HashMap<string, Gee.HashMap<string, LiveBuffer>> cache, string session_id) {
        var result = new Gee.HashMap<string, string> ();
        if (!cache.has_key (session_id)) {
            return result;
        }
        foreach (var entry in cache[session_id].entries) {
            result[entry.key] = entry.value.text.str;
        }
        return result;
    }

    /** Mutable accumulator for streamed text. Wrapped in a class so
     *  appending is in place (a plain string rebuild per delta made a
     *  long stream quadratic). */
    private class LiveBuffer : GLib.Object {
        public StringBuilder text = new StringBuilder ();

        public void append (string delta) {
            text.append (delta);
        }

        public void reset (string value) {
            text = new StringBuilder ();
            text.append (value);
        }
    }

    /** Live message ids for a session, in first-seen order. */
    public Gee.ArrayList<string> live_ids_for (string session_id) {
        return live_order.has_key (session_id) ? live_order[session_id] : new Gee.ArrayList<string> ();
    }

    /** Unfinished live tools for a session (for replaying tool cards). */
    public Gee.ArrayList<LiveTool> live_tools_for (string session_id) {
        var result = new Gee.ArrayList<LiveTool> ();
        foreach (var tool in live_tools.values) {
            if (tool.session_id == session_id && !tool.done) {
                result.add (tool);
            }
        }
        return result;
    }

    /** One replayable live message: partial text/reasoning plus its
     *  unfinished tools. Built by the store so the view layer stays
     *  dumb and the plan is unit-testable. */
    public class ReplayEntry : GLib.Object {
        public string message_id { get; set; default = ""; }
        public string text { get; set; default = ""; }
        public string reasoning { get; set; default = ""; }
        public Gee.ArrayList<LiveTool> tools;

        public ReplayEntry () {
            tools = new Gee.ArrayList<LiveTool> ();
        }

        public bool has_content {
            get {
                return text != "" || reasoning != "" || tools.size > 0;
            }
        }
    }

    /** Ordered replay plan for a session opened mid-turn. Skips ids
     *  with no content and no unfinished tool so the view never
     *  conjures an empty bubble. */
    public Gee.ArrayList<ReplayEntry> build_replay (string session_id) {
        var plan = new Gee.ArrayList<ReplayEntry> ();
        var texts = live_text_for (session_id);
        var thoughts = live_reasoning_for (session_id);
        var by_id = new Gee.HashMap<string, ReplayEntry> ();
        foreach (var message_id in live_ids_for (session_id)) {
            var entry = new ReplayEntry () { message_id = message_id };
            entry.text = texts.has_key (message_id) ? texts[message_id] : "";
            entry.reasoning = thoughts.has_key (message_id) ? thoughts[message_id] : "";
            by_id[message_id] = entry;
            plan.add (entry);
        }
        foreach (var tool in live_tools_for (session_id)) {
            if (!by_id.has_key (tool.message_id)) {
                var entry = new ReplayEntry () { message_id = tool.message_id };
                by_id[tool.message_id] = entry;
                plan.add (entry);
            }
            by_id[tool.message_id].tools.add (tool);
        }
        var filtered = new Gee.ArrayList<ReplayEntry> ();
        foreach (var entry in plan) {
            if (entry.has_content) {
                filtered.add (entry);
            }
        }
        return filtered;
    }

    /** One subagent run: a `task` tool call, live or from history. */
    public class SubagentRun : GLib.Object {
        public string call_id { get; set; default = ""; }
        public string description { get; set; default = ""; }
        public bool done { get; set; default = false; }
        public bool error { get; set; default = false; }
    }

    /** Subagent runs for a session: `task` tool calls, oldest first.
     *  Live calls come from live_tools, finished ones from history. */
    public Gee.ArrayList<SubagentRun> subagents_for (string session_id) {
        var runs = new Gee.ArrayList<SubagentRun> ();
        var seen = new Gee.HashSet<string> ();
        foreach (var message in active_messages) {
            foreach (var part in message.parts) {
                if (part.kind != PartKind.TOOL || part.tool_name != "task") {
                    continue;
                }
                if (seen.contains (part.tool_id)) {
                    continue;
                }
                seen.add (part.tool_id);
                runs.add (new SubagentRun () {
                    call_id = part.tool_id,
                    description = part.tool_input_summary,
                    done = true,
                    error = part.tool_status == "error"
                });
            }
        }
        foreach (var call_id in live_tool_ids (session_id)) {
            var tool = live_tools.has_key (call_id) ? live_tools[call_id] : null;
            if (tool == null || tool.name != "task") {
                continue;
            }
            if (seen.contains (tool.call_id)) {
                continue;
            }
            seen.add (tool.call_id);
            runs.add (new SubagentRun () {
                call_id = tool.call_id,
                description = tool.input_summary,
                done = tool.done,
                error = tool.error
            });
        }
        return runs;
    }

    /** Count of available skills on this server (context source). */
    public int skills_count { get; set; default = 0; }

    private void note_live_id (string session_id, string message_id) {
        if (!live_order.has_key (session_id)) {
            live_order[session_id] = new Gee.ArrayList<string> ();
        }
        var ids = live_order[session_id];
        if (!live_ids_seen.has_key (session_id)) {
            live_ids_seen[session_id] = new Gee.HashSet<string> ();
        }
        var seen = live_ids_seen[session_id];
        if (seen.add (message_id)) {
            ids.add (message_id);
        }
    }

    private void accum_live (Gee.HashMap<string, Gee.HashMap<string, LiveBuffer>> cache,
        string session_id, string message_id, string delta) {
        if (!cache.has_key (session_id)) {
            cache[session_id] = new Gee.HashMap<string, LiveBuffer> ();
        }
        var per_msg = cache[session_id];
        if (!per_msg.has_key (message_id)) {
            per_msg[message_id] = new LiveBuffer ();
        }
        per_msg[message_id].append (delta);
        note_live_id (session_id, message_id);
    }

    private void set_live (Gee.HashMap<string, Gee.HashMap<string, LiveBuffer>> cache,
        string session_id, string message_id, string text) {
        if (!cache.has_key (session_id)) {
            cache[session_id] = new Gee.HashMap<string, LiveBuffer> ();
        }
        if (!cache[session_id].has_key (message_id)) {
            cache[session_id][message_id] = new LiveBuffer ();
        }
        cache[session_id][message_id].reset (text);
        note_live_id (session_id, message_id);
    }

    /** Drops a session's live buffers: the turn settled, so server
     *  history is authoritative again. */
    private void prune_live (string session_id) {
        live_text.unset (session_id);
        live_reasoning.unset (session_id);
        live_order.unset (session_id);
        live_ids_seen.unset (session_id);
    }

    private void set_activity (string session_id, string text) {
        if (activity_for (session_id) == text) {
            return;
        }
        if (text == "") {
            activities.unset (session_id);
        } else {
            activities[session_id] = text;
        }
        activity_changed (session_id);
    }

    /** Recomputes "Running · ToolA, ToolB" from the session's unfinished
     *  tools, falling back to plain "Running". Called on every tool
     *  event so background sessions report live tool use too. */
    private void note_tool_activity (string session_id) {
        var names = new Gee.ArrayList<string> ();
        foreach (var call_id in live_tool_ids (session_id)) {
            var tool = live_tools.has_key (call_id) ? live_tools[call_id] : null;
            if (tool == null || tool.done || tool.name == "") {
                continue;
            }
            if (!names.contains (tool.name)) {
                names.add (tool.name);
            }
        }
        if (names.size > 0) {
            set_activity (session_id, "Running · " + ListArrays.join (", ", names));
        } else if (status_for (session_id) == "running") {
            set_activity (session_id, "Running");
        }
    }

    /** Call ids of the live tools belonging to one session (empty when
     *  none). Only that session's tools are touched, so the label is
     *  O(tools-in-this-session) instead of O(all live tools). */
    private Gee.ArrayList<string> live_tool_ids (string session_id) {
        if (live_tools_by_session.has_key (session_id)) {
            return live_tools_by_session[session_id];
        }
        return new Gee.ArrayList<string> ();
    }

    /** Registers a tool in the per-session index (insertion order). */
    private void index_live_tool (LiveTool tool) {
        if (!live_tools_by_session.has_key (tool.session_id)) {
            live_tools_by_session[tool.session_id] = new Gee.ArrayList<string> ();
        }
        var ids = live_tools_by_session[tool.session_id];
        if (!ids.contains (tool.call_id)) {
            ids.add (tool.call_id);
        }
    }

    /** Caps the tools kept per session. A long session accumulates a
     *  LiveTool (with up to 4 kB of output) per call, and nothing used
     *  to drop them, so a day of work retained every tool output for
     *  the app's lifetime. The newest ones are the relevant ones. */
    private void cap_live_tools () {
        foreach (var entry in live_tools_by_session.entries) {
            var ids = entry.value;
            if (ids.size <= MAX_LIVE_TOOLS_PER_SESSION) {
                continue;
            }
            var keep = new Gee.ArrayList<string> ();
            for (int i = ids.size - MAX_LIVE_TOOLS_PER_SESSION; i < ids.size; i++) {
                keep.add (ids[i]);
            }
            foreach (var call_id in ids) {
                if (!keep.contains (call_id)) {
                    live_tools.unset (call_id);
                }
            }
            ids.clear ();
            ids.add_all (keep);
        }
    }

    /** Merges execution status observed on ANOTHER server into the
     *  local status maps. The background service CLI clients use shares
     *  the session database, so ids match; only status/activity merge:
     *  messages, tools and actions stay on the managed connection. */
    public void note_remote_status (string session_id, string status, string activity = "") {
        set_status (session_id, status);
        if (activity != "") {
            set_activity (session_id, activity);
        }
    }

    /** A remote tap (the background-service watcher) uses this to ask
     *  for a session-list refresh without touching anything else. */
    public void request_reload () {
        schedule_reload ();
    }

    private void set_status (string session_id, string status) {
        if (status_for (session_id) == status) {
            return;
        }
        statuses[session_id] = status;
        status_changed (session_id, status);
    }

    /* Ensures a message exists in the active conversation cache. */
    private void ensure_assistant_message (string message_id) {
        /* Streaming deltas call this constantly and the growing
         * assistant message is the last entry, so check that first
         * before the id index (a conversation can be huge). */
        if (active_messages.size > 0
            && active_messages[active_messages.size - 1].id == message_id) {
            return;
        }
        if (active_message_ids.contains (message_id)) {
            return;
        }
        var message = new Message () {
            id = message_id,
            role = MessageRole.ASSISTANT
        };
        add_active_message (message);
    }

    private void on_event (string type, Json.Object data) {
        /* The stream reconnecting is surfaced here too: a full reload
         * guarantees we catch any session created/changed while we were
         * off the stream. */
        if (type == "server.connected") {
            return; /* handled via stream.connected signal + resync */
        }

        switch (type) {
            case "session.created":
            case "session.updated":
            case "session.deleted":
            /* Forks and moves change the list (or its order) without
             *  emitting created/updated. */
            case "session.forked":
            case "session.moved":
            /* Title/directory/agent metadata can change out of band. */
            case "session.instructions.updated":
            case "session.metadata.updated":
                schedule_reload ();
                break;

            /* Catalog changes carry no session id, so they must be
             *  handled here, before the session gate below. */
            case "config.updated":
            case "model.updated":
            case "provider.updated":
            case "agent.updated":
                load_models.begin ();
                load_agents.begin ();
                break;

            case "command.executed":
            case "command.updated":
                load_commands.begin ();
                break;

            case "mcp.status.changed":
            case "mcp.tools.changed":
            case "mcp.prompts.changed":
            case "mcp.resources.changed":
                mcp_changed ();
                break;

            case "session.renamed": {
                /* Live auto-title (the server titles a session once the
                 * first assistant reply lands). Update in place so the
                 * sidebar row, header and selection survive. */
                var renamed_id = JsonUtil.string_member (data, "sessionID");
                var new_title = JsonUtil.string_member (data, "title");
                if (renamed_id != null && new_title != null && new_title != "") {
                    var renamed = session_for (renamed_id);
                    if (renamed != null && renamed.title != new_title) {
                        renamed.title = new_title;
                        session_title_changed (renamed_id);
                    }
                }
                break;
            }
        }

        var session_id = JsonUtil.string_member (data, "sessionID");
        if (session_id == null && type.has_prefix ("form.")) {
            /* Form events nest the session (`data.form.sessionID`)
             *  instead of carrying it top-level like session.* and
             *  permission.* do. Without this every form event hits the
             *  early return below: the question tool's card spins at
             *  "Working…" forever and its form never reaches the dock. */
            var form_obj = JsonUtil.object_member (data, "form");
            if (form_obj != null) {
                session_id = JsonUtil.string_member (form_obj, "sessionID");
            }
        }
        if (session_id == null) {
            return;
        }

        switch (type) {
            case "session.inbox.enqueued":
                on_inbox_enqueued (session_id, data);
                break;

            case "session.execution.started":
                set_status (session_id, "running");
                set_activity (session_id, "Running");
                break;

            case "session.execution.succeeded":
            case "session.idle":
                if (type == "session.execution.succeeded") {
                    last_outcome[session_id] = "succeeded";
                }
                pending_error.unset (session_id);
                set_status (session_id, "idle");
                set_activity (session_id, "");
                prune_live (session_id);
                break;

            case "session.execution.failed": {
                /* The visible end of a failed turn: one error divider
                 * carrying the provider message (stashed from
                 * session.step.failed, or read here as fallback). */
                last_outcome[session_id] = "failed";
                set_status (session_id, "idle");
                set_activity (session_id, "");
                var message = pending_error.has_key (session_id)
                    ? pending_error[session_id] : error_message (data);
                pending_error.unset (session_id);
                prune_live (session_id);
                if (message == "") {
                    message = "Turn failed";
                }
                if (session_id == active_session_id) {
                    divider_changed (session_id,
                        @"exec-failed-$(GLib.get_monotonic_time ())",
                        "dialog-error", message, "error");
                }
                break;
            }

            case "session.execution.interrupted": {
                /* Stop must settle everything: no reasoning, tool card,
                 * live status or retry divider may be left running.
                 * set_status("idle") drives finish_live() in the view. */
                var cancelled_retry = active_retry.has_key (session_id) ? active_retry[session_id] : null;
                if (cancelled_retry != null) {
                    active_retry.unset (session_id);
                    if (session_id == active_session_id) {
                        divider_changed (session_id, cancelled_retry, "view-refresh", "Retry cancelled", "done");
                    }
                }
                if (session_id == active_session_id) {
                    divider_changed (session_id,
                        @"interrupted-$(GLib.get_monotonic_time ())",
                        "media-playback-stop", "Interrupted", "done");
                }
                set_status (session_id, "idle");
                set_activity (session_id, "");
                prune_live (session_id);
                break;
            }

            case "session.step.started": {
                set_status (session_id, "running");
                set_activity (session_id, "Running");
                /* A fresh attempt (e.g. after a retry): any error from
                 * the previous failed step no longer applies. */
                pending_error.unset (session_id);

                var retry_id = active_retry.has_key (session_id) ? active_retry[session_id] : null;
                if (retry_id != null) {
                    active_retry.unset (session_id);
                    if (session_id == active_session_id) {
                        divider_changed (session_id, retry_id, "view-refresh", "Retrying now", "done");
                    }
                }

                var message_id = JsonUtil.string_member (data, "assistantMessageID");
                if (message_id == null) {
                    break;
                }
                var model = "";
                var model_obj = JsonUtil.object_member (data, "model");
                if (model_obj != null) {
                    model = @"$(JsonUtil.string_member (model_obj, "providerID") ?? "")/$(JsonUtil.string_member (model_obj, "id") ?? "")";
                }
                if (session_id == active_session_id) {
                    ensure_assistant_message (message_id);
                    assistant_started (message_id, model);
                }
                break;
            }

            case "session.text.delta": {
                var message_id = JsonUtil.string_member (data, "assistantMessageID") ?? "";
                var delta = JsonUtil.string_member (data, "delta") ?? "";
                if (message_id == "") {
                    break;
                }
                accum_live (live_text, session_id, message_id, delta);
                if (session_id == active_session_id) {
                    ensure_assistant_message (message_id);
                    text_delta (message_id, delta);
                }
                break;
            }

            case "session.text.ended": {
                var message_id = JsonUtil.string_member (data, "assistantMessageID") ?? "";
                var text = JsonUtil.string_member (data, "text") ?? "";
                if (message_id == "") {
                    break;
                }
                set_live (live_text, session_id, message_id, text);
                if (session_id == active_session_id) {
                    ensure_assistant_message (message_id);
                    text_done (message_id, text);
                }
                break;
            }

            case "session.reasoning.delta": {
                var message_id = JsonUtil.string_member (data, "assistantMessageID") ?? "";
                var delta = JsonUtil.string_member (data, "delta") ?? "";
                if (message_id == "") {
                    break;
                }
                accum_live (live_reasoning, session_id, message_id, delta);
                if (session_id == active_session_id) {
                    ensure_assistant_message (message_id);
                    reasoning_delta (message_id, delta);
                }
                break;
            }

            case "session.reasoning.ended": {
                var message_id = JsonUtil.string_member (data, "assistantMessageID") ?? "";
                var text = JsonUtil.string_member (data, "text") ?? "";
                if (message_id == "") {
                    break;
                }
                set_live (live_reasoning, session_id, message_id, text);
                if (session_id == active_session_id) {
                    ensure_assistant_message (message_id);
                    reasoning_done (message_id, text);
                }
                break;
            }

            case "session.usage.updated": {
                var tokens = JsonUtil.object_member (data, "tokens");
                var session = session_for (session_id);
                if (session != null) {
                    session.cost = JsonUtil.double_member (data, "cost", session.cost);
                    if (tokens != null) {
                        session.input_tokens = JsonUtil.int_member (tokens, "input", session.input_tokens);
                        session.output_tokens = JsonUtil.int_member (tokens, "output", session.output_tokens);
                    }
                }
                usage_updated ();
                break;
            }

            case "session.compaction.started": {
                var divider_id = JsonUtil.string_member (data, "inputID")
                    ?? @"compaction-$(GLib.get_monotonic_time ())";
                var reason = JsonUtil.string_member (data, "reason") ?? "auto";
                active_compaction[session_id] = divider_id;
                set_status (session_id, "compacting");
                set_activity (session_id, "Compacting…");
                if (session_id == active_session_id) {
                    divider_changed (session_id, divider_id, "preferences-system",
                        reason == "auto" ? "Compacting context (auto)…" : "Compacting context…", "running");
                }
                break;
            }

            case "session.compaction.delta": {
                var divider_id = active_compaction.has_key (session_id) ? active_compaction[session_id] : null;
                if (divider_id == null || session_id != active_session_id) {
                    break;
                }
                divider_delta (session_id, divider_id, JsonUtil.string_member (data, "text") ?? "");
                break;
            }

            case "session.compaction.ended": {
                var divider_id = active_compaction.has_key (session_id) ? active_compaction[session_id] : null;
                var reason = JsonUtil.string_member (data, "reason") ?? "auto";
                active_compaction.unset (session_id);
                set_status (session_id, "idle");
                set_activity (session_id, "");
                if (divider_id != null && session_id == active_session_id) {
                    divider_changed (session_id, divider_id, "preferences-system",
                        reason == "auto" ? "Context compacted (auto)" : "Context compacted", "done");
                }
                /* The window just shrank: force a fresh measurement so
                 * the composer meter and the inspector update at once.
                 * Only the active session's meter is visible, so skip
                 * the (heavy) fetch for background compactions. */
                if (session_id == active_session_id) {
                    refresh_context_usage.begin (session_id, true);
                }
                break;
            }

            case "session.compaction.failed": {
                var divider_id = active_compaction.has_key (session_id) ? active_compaction[session_id] : null;
                active_compaction.unset (session_id);
                set_status (session_id, "idle");
                set_activity (session_id, "");
                if (divider_id != null && session_id == active_session_id) {
                    var error_obj = JsonUtil.object_member (data, "error");
                    var error_text = error_obj != null
                        ? (JsonUtil.string_member (error_obj, "message") ?? "") : "";
                    divider_changed (session_id, divider_id, "dialog-warning",
                        error_text != "" ? @"Compaction failed: $error_text" : "Compaction failed", "error");
                }
                break;
            }

            case "session.model.selected": {
                var model_obj = JsonUtil.object_member (data, "model");
                var label = "model";
                var icon_name = "applications-science";
                if (model_obj != null) {
                    var model_id = JsonUtil.string_member (model_obj, "id") ?? "model";
                    var provider_id = JsonUtil.string_member (model_obj, "providerID") ?? "";
                    var variant = JsonUtil.string_member (model_obj, "variant") ?? "";
                    var info = find_model (provider_id, model_id);
                    label = info != null ? info.name : model_id;
                    if (variant != "") {
                        label += @" ($variant)";
                    }
                    icon_name = ModelIcons.icon_for (provider_id, model_id);
                }
                if (session_id == active_session_id) {
                    divider_changed (session_id,
                        @"model-switch-$(GLib.get_monotonic_time ())",
                        icon_name, @"Switched model to $label", "done");
                }
                break;
            }

            case "session.agent.selected": {
                var agent_id = JsonUtil.string_member (data, "agent") ?? "agent";
                var agent_label = agent_id;
                foreach (var agent in agents) {
                    if (agent.id == agent_id) {
                        agent_label = agent.name;
                        break;
                    }
                }
                if (session_id == active_session_id) {
                    divider_changed (session_id,
                        @"agent-switch-$(GLib.get_monotonic_time ())",
                        "system-run", @"Switched agent to $agent_label", "done");
                }
                break;
            }

            case "session.retry.scheduled": {
                var attempt = JsonUtil.int_member (data, "attempt", 0);
                var divider_id = @"retry-$(GLib.get_monotonic_time ())";
                active_retry[session_id] = divider_id;
                set_status (session_id, "running");
                set_activity (session_id, "Retrying…");
                if (session_id == active_session_id) {
                    divider_changed (session_id, divider_id, "view-refresh",
                        @"Rate limited · retrying (attempt $(attempt + 1))", "running");
                }
                break;
            }

            case "form.created": {
                var form_obj = JsonUtil.object_member (data, "form");
                if (form_obj == null) {
                    debug ("form.created without a form payload");
                    break;
                }
                var form = FormInfo.from_json (form_obj);
                if (form == null) {
                    debug ("form.created with an unparsable form payload");
                    break;
                }
                if (form.session_id == "") {
                    form.session_id = session_id;
                }
                pending_forms[form.id] = form;
                set_status (form.session_id, "question");
                set_activity (form.session_id, "Question waiting");
                forms_changed (form.session_id);
                break;
            }

            /* Settle events end the question: the answered/dismissed
             *  form leaves pending_forms so the dock clears and the
             *  session resumes. (There is no `form.settled` on the
             *  wire; these two are the real events.) */
            case "form.replied":
            case "form.cancelled": {
                var form_id = JsonUtil.string_member (data, "id");
                if (form_id != null) {
                    pending_forms.unset (form_id);
                } else {
                    var stale = new Gee.ArrayList<string> ();
                    foreach (var entry in pending_forms.entries) {
                        if (entry.value.session_id == session_id) {
                            stale.add (entry.key);
                        }
                    }
                    foreach (var key in stale) {
                        pending_forms.unset (key);
                    }
                }
                set_status (session_id, "running");
                set_activity (session_id, "Running");
                forms_changed (session_id);
                break;
            }

            /** A session-level error outside a turn (e.g. background
             *  work failing): surface it instead of silently idling. */
            case "session.error": {
                var message = error_message (data);
                if (message == "") {
                    message = "Session error";
                }
                set_status (session_id, "idle");
                set_activity (session_id, "");
                if (session_id == active_session_id) {
                    divider_changed (session_id,
                        @"session-error-$(GLib.get_monotonic_time ())",
                        "dialog-error", message, "error");
                }
                notice (message);
                break;
            }

            /** The file state changed: the diff stat (composer chip,
             *  inspector) is stale. */
            case "session.diff": {
                if (session_id == active_session_id) {
                    refresh_diff_stat.begin (session_id);
                }
                break;
            }

            /** Compaction landed: the window shrank, so force a fresh
             *  context measurement like compaction.ended does. */
            case "session.compacted": {
                if (session_id == active_session_id) {
                    refresh_context_usage.begin (session_id, true);
                }
                break;
            }

            /** The server changed a session's permission ruleset
             *  (e.g. another client): the composer shield follows. */
            case "session.permissions": {
                permissions_changed (session_id);
                sessions_changed ();
                break;
            }

            /** Revert boundaries moved: file state and context both
             *  changed, so re-measure what the UI shows for them. */
            case "session.revert.staged":
            case "session.revert.committed":
            case "session.revert.cleared": {
                if (session_id == active_session_id) {
                    refresh_diff_stat.begin (session_id);
                    refresh_context_usage.begin (session_id, true);
                }
                break;
            }

            case "session.tool.input.started": {
                var call_id = JsonUtil.string_member (data, "id");
                var message_id = JsonUtil.string_member (data, "assistantMessageID");
                if (call_id == null || message_id == null) {
                    break;
                }
                var tool = new LiveTool () {
                    call_id = call_id,
                    message_id = message_id,
                    session_id = session_id,
                    name = JsonUtil.string_member (data, "name") ?? "tool"
                };
                tool.file_path = tool_file_path (tool.name,
                    JsonUtil.object_member (data, "input"));
                live_tools[call_id] = tool;
                index_live_tool (tool);
                set_status (session_id, "running");
                note_tool_activity (session_id);
                note_live_id (session_id, message_id);
                if (session_id == active_session_id) {
                    ensure_assistant_message (message_id);
                    tool_changed (message_id, call_id, "started");
                    if (tool.file_path != "") {
                        /* A file is being written right now: show it in
                         * the changed-files lists straight away. */
                        diffs_changed (session_id);
                    }
                }
                break;
            }

            case "session.tool.called": {
                var call_id = JsonUtil.string_member (data, "id");
                var message_id = JsonUtil.string_member (data, "assistantMessageID");
                if (call_id == null || message_id == null) {
                    break;
                }
                var tool = live_tools.has_key (call_id) ? live_tools[call_id] : null;
                if (tool == null) {
                    tool = new LiveTool () {
                        call_id = call_id,
                        message_id = message_id,
                        session_id = session_id
                    };
                    live_tools[call_id] = tool;
                    index_live_tool (tool);
                }
                tool.input_summary = ToolCard.summarize_input (
                    tool.name, JsonUtil.object_member (data, "input"));
                note_tool_activity (session_id);
                note_live_id (session_id, message_id);
                if (session_id == active_session_id) {
                    ensure_assistant_message (message_id);
                    tool_changed (message_id, call_id, "input");
                }
                break;
            }

            case "session.tool.success":
            /* The wire name is `failed`: there is no `tool.error`
             *  event (t3code confirms), so listening for it left
             *  errored tool cards spinning forever. */
            case "session.tool.failed": {
                var call_id = JsonUtil.string_member (data, "id");
                var message_id = JsonUtil.string_member (data, "assistantMessageID");
                if (call_id == null || message_id == null) {
                    break;
                }
                var tool = live_tools.has_key (call_id) ? live_tools[call_id] : null;
                if (tool == null) {
                    tool = new LiveTool () {
                        call_id = call_id,
                        message_id = message_id,
                        session_id = session_id
                    };
                    live_tools[call_id] = tool;
                    index_live_tool (tool);
                }
                tool.done = true;
                tool.error = type == "session.tool.failed";
                /* A finished write/edit changes the file list: refresh
                 * it (coalesced, so a burst of edits is one fetch). */
                if (tool.file_path != "" || is_file_mutation (tool.name)) {
                    tool.file_path = "";
                    schedule_diff_refresh (session_id);
                }
                var outputs = new StringBuilder ();
                foreach (var content_obj in JsonUtil.array_objects (data, "content")) {
                    var content_type = JsonUtil.string_member (content_obj, "type") ?? "";
                    if (content_type == "text") {
                        var chunk = JsonUtil.string_member (content_obj, "text") ?? "";
                        if (chunk != "") {
                            if (outputs.len > 0) {
                                outputs.append ("\n");
                            }
                            outputs.append (chunk);
                        }
                    } else if (content_type == "file") {
                        var file = FileAttachment.from_data_uri (
                            JsonUtil.string_member (content_obj, "uri") ?? "");
                        if (file != null) {
                            tool.files.add (file);
                        }
                    }
                }
                tool.output_text = outputs.str;
                if (tool.output_text.length > 4000) {
                    tool.output_text = tool.output_text.substring (0, 4000) + "\n… (truncated)";
                }
                if (tool.error && tool.output_text == "") {
                    tool.output_text = JsonUtil.string_member (data, "error") ?? "Failed";
                }
                note_tool_activity (session_id);
                note_live_id (session_id, message_id);
                if (session_id == active_session_id) {
                    ensure_assistant_message (message_id);
                    tool_changed (message_id, call_id, "done");
                }
                break;
            }

            case "session.step.ended": {
                if (session_id == active_session_id) {
                    refresh_diff_stat.begin (session_id);
                    refresh_context_usage.begin (session_id);
                }
                break;
            }

            case "session.step.failed": {
                /* Stash the provider message; session.execution.failed
                 * shows it as a single error divider when the turn
                 * settles, so a failed step + failed execution never
                 * produce two error lines. */
                var message = error_message (data);
                if (message != "") {
                    pending_error[session_id] = message;
                }
                break;
            }

            case "permission.asked": {
                var request_id = JsonUtil.string_member (data, "id");
                if (request_id == null) {
                    break;
                }
                var request = new PermissionRequest () {
                    id = request_id,
                    session_id = JsonUtil.string_member (data, "sessionID") ?? session_id,
                    action = JsonUtil.string_member (data, "action") ?? ""
                };
                request.resources = ListArrays.join (", ", JsonUtil.array_strings (data, "resources"));

                pending_permissions[request_id] = request;
                set_status (session_id, "waiting");
                set_activity (request.session_id, "Waiting for permission");
                permissions_changed (request.session_id);
                break;
            }

            case "permission.replied": {
                var request_id = JsonUtil.string_member (data, "requestID");
                if (request_id == null) {
                    break;
                }
                pending_permissions.unset (request_id);
                set_status (session_id, "running");
                set_activity (session_id, "Running");
                permissions_changed (session_id);
                break;
            }

            default:
                /* Unknown event: log it so the next wire addition is
                 *  visible instead of silently ignored (high-volume
                 *  streams like deltas all have handlers above, so this
                 *  stays quiet in practice). */
                debug ("Unhandled event: %s", type);
                break;
        }
    }
}

}
