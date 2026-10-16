/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Right-hand session inspector, OpenChamber-style: context meter,
 * project, model usage, turn stats, subagent runs and context
 * sources, all read from data the app already has (no invented
 * metrics). Collapsible from the chat header.
 */

namespace OpenClient {

public class SessionPanel : Gtk.Box {
    private Gtk.Box sections;
    private Gtk.Label empty_label;
    private Store store;

    /* Context */
    private Gtk.LevelBar context_bar;
    private Gtk.Label context_label;

    /* Project */
    private Gtk.Label project_label;
    private Gtk.Label project_path_label;

    /* Usage */
    private Gtk.Image usage_icon;
    private Gtk.Label usage_model_label;
    private Gtk.Label usage_tokens_label;

    /* Turn stats */
    private Gtk.Label stat_steps;
    private Gtk.Label stat_tokens;
    private Gtk.Label stat_cache;
    private Gtk.Label stat_cost;
    private Gtk.Label stat_elapsed;
    private Gtk.Label stat_model_time;
    private Gtk.Label stat_tool_time;

    /* Subagents */
    private Gtk.Box subagents_box;
    private Gtk.Label subagents_count;
    private Gtk.Label subagents_empty;
    /** Existing subagent rows keyed by call id, so update() can patch
     *  the rows that changed instead of rebuilding all of them. */
    private Gee.HashMap<string, Gtk.Box> subagent_rows;
    /** Last meter band applied (""/context-high/context-full) and last
     *  provider icon, to skip redundant style + icon work. */
    private string last_context_band = "";
    private string last_usage_icon = "";

    /* Context sources */
    private Gtk.Label sources_skills;
    private Gtk.Label sources_mcp;

    /* Changed files */
    private Gtk.Box? changes_box = null;
    private Gtk.Label? changes_empty = null;
    private Gtk.Label? changes_count = null;

    private int mcp_count = 0;
    /** When set, the panel ignores the active session and shows this
     *  message instead (e.g. while composing a brand-new session). */
    private string? placeholder = null;

    public SessionPanel (Store store) {
        Object (
            orientation: Gtk.Orientation.VERTICAL,
            spacing: 0,
            width_request: 280
        );
        this.store = store;
        add_css_class ("session-panel");
        subagent_rows = new Gee.HashMap<string, Gtk.Box> ();

        var scrolled = new Gtk.ScrolledWindow () {
            vexpand = true,
            hscrollbar_policy = Gtk.PolicyType.NEVER
        };
        sections = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        scrolled.child = sections;
        append (scrolled);

        empty_label = new Gtk.Label ("Open a session to see its details") {
            wrap = true,
            justify = Gtk.Justification.CENTER,
            margin_top = 32,
            margin_start = 16,
            margin_end = 16
        };
        empty_label.add_css_class (Granite.CssClass.DIM);
        sections.append (empty_label);

        build_context ();
        build_project ();
        build_changes ();
        build_usage ();
        build_turn_stats ();
        build_subagents ();
        build_sources ();
    }

    /* -- section scaffolding ------------------------------------------ */

    /** Section head: a native Granite.HeaderLabel (small-caps section
     *  typography, no hand-rolled bold class) with a dim trailing value
     *  (percentage, project name, counts). */
    private Gtk.Box section_header (string title, out Gtk.Label value) {
        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            margin_top = 12,
            margin_bottom = 4,
            margin_start = 12,
            margin_end = 12
        };
        var label = new Granite.HeaderLabel (title) {
            hexpand = true,
            valign = Gtk.Align.CENTER
        };
        value = new Gtk.Label ("") { xalign = 1, valign = Gtk.Align.CENTER };
        value.add_css_class (Granite.CssClass.DIM);
        value.add_css_class ("caption");
        box.append (label);
        box.append (value);
        return box;
    }

    private void add_section (Gtk.Widget header, Gtk.Widget? body = null) {
        sections.append (header);
        if (body != null) {
            sections.append (body);
        }
    }

    private static Gtk.Box stat_row (string key, out Gtk.Label value) {
        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            margin_start = 12,
            margin_end = 12,
            margin_top = 1,
            margin_bottom = 1
        };
        var key_label = new Gtk.Label (key) { xalign = 0, hexpand = true };
        key_label.add_css_class (Granite.CssClass.DIM);
        key_label.add_css_class ("caption");
        value = new Gtk.Label ("None") { xalign = 1 };
        value.add_css_class ("caption");
        box.append (key_label);
        box.append (value);
        return box;
    }

    /* -- context ------------------------------------------------------- */

    private void build_context () {
        Gtk.Label value;
        var header = section_header ("Context", out value);
        context_label = value;

        context_bar = new Gtk.LevelBar.for_interval (0.0, 1.0) {
            hexpand = true,
            margin_start = 12,
            margin_end = 12,
            margin_bottom = 6
        };
        add_section (header, context_bar);
    }

    /* -- project ------------------------------------------------------- */

    private void build_project () {
        Gtk.Label value;
        var header = section_header ("Project", out value);
        project_label = value;

        project_path_label = new Gtk.Label ("") {
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.MIDDLE,
            margin_start = 12,
            margin_end = 12,
            margin_bottom = 4
        };
        project_path_label.add_css_class ("caption");
        project_path_label.add_css_class (Granite.CssClass.MONOSPACE);
        add_section (header, project_path_label);
    }

    /* -- changed files ------------------------------------------------ */

    private void build_changes () {
        Gtk.Label value;
        var header = section_header ("Changed Files", out value);
        changes_count = value;

        changes_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) {
            margin_start = 12,
            margin_end = 12,
            margin_bottom = 6
        };
        changes_empty = new Gtk.Label ("No changes yet") {
            xalign = 0
        };
        changes_empty.add_css_class (Granite.CssClass.DIM);
        changes_empty.add_css_class ("caption");
        changes_box.append (changes_empty);
        add_section (header, changes_box);
    }

    /** Rebuilds the changed-files list: one row per path (the store
     *  already collapses duplicates), with a spinner on files being
     *  written right now. */
    public void set_diff_files (Gee.ArrayList<FileDiff> files, Gee.ArrayList<string> editing) {
        if (changes_box == null || changes_empty == null || changes_count == null) {
            return;
        }
        Gtk.Widget? child = changes_box.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            changes_box.remove (child);
            child = next;
        }

        var total_add = 0;
        var total_del = 0;
        foreach (var diff in files) {
            total_add += diff.additions;
            total_del += diff.deletions;
        }
        changes_count.label = files.size > 0
            ? @"$(files.size) · +$total_add −$total_del"
            : "";
        changes_empty.visible = files.size == 0 && editing.size == 0;
        changes_box.append (changes_empty);

        var listed = new Gee.HashSet<string> ();
        foreach (var diff in files) {
            listed.add (diff.path);
            changes_box.append (new ChangeRow (diff.path, diff.additions,
                diff.deletions, diff.status, editing.contains (diff.path), true));
        }
        /* Files being written that the diff has not caught up with. */
        foreach (var path in editing) {
            if (!listed.contains (path)) {
                changes_box.append (new ChangeRow (path, -1, -1, "", true, true));
            }
        }
    }

    /* -- usage --------------------------------------------------------- */

    private void build_usage () {
        Gtk.Label value;
        var header = section_header ("Usage", out value);
        usage_tokens_label = value;

        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
            margin_start = 12,
            margin_end = 12,
            margin_bottom = 4
        };
        usage_icon = new Gtk.Image.from_icon_name ("applications-science") {
            pixel_size = 16,
            valign = Gtk.Align.CENTER
        };
        usage_model_label = new Gtk.Label ("") { xalign = 0, hexpand = true, ellipsize = Pango.EllipsizeMode.END };
        row.append (usage_icon);
        row.append (usage_model_label);
        add_section (header, row);
    }

    /* -- turn stats ---------------------------------------------------- */

    private void build_turn_stats () {
        Gtk.Label value;
        var header = section_header ("Turn Stats", out value);
        value.label = "";

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) { margin_bottom = 6 };
        box.append (stat_row ("Steps", out stat_steps));
        box.append (stat_row ("Tokens", out stat_tokens));
        box.append (stat_row ("Cache", out stat_cache));
        box.append (stat_row ("Elapsed", out stat_elapsed));
        box.append (stat_row ("Model Time", out stat_model_time));
        box.append (stat_row ("Tool Time", out stat_tool_time));
        box.append (stat_row ("Cost", out stat_cost));
        add_section (header, box);
    }

    /* -- subagents ----------------------------------------------------- */

    private void build_subagents () {
        var header = section_header ("Subagents", out subagents_count);
        subagents_empty = new Gtk.Label ("None yet") {
            xalign = 0,
            margin_start = 12,
            margin_end = 12,
            margin_bottom = 6
        };
        subagents_empty.add_css_class (Granite.CssClass.DIM);
        subagents_empty.add_css_class ("caption");
        subagents_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) {
            margin_start = 12,
            margin_end = 12,
            margin_bottom = 6
        };
        var wrapper = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        wrapper.append (subagents_empty);
        wrapper.append (subagents_box);
        add_section (header, wrapper);
    }

    /* -- context sources ----------------------------------------------- */

    private void build_sources () {
        Gtk.Label value;
        var header = section_header ("Context Sources", out value);
        value.label = "";

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) { margin_bottom = 12 };
        box.append (stat_row ("Skills", out sources_skills));
        box.append (stat_row ("MCP Servers", out sources_mcp));
        add_section (header, box);
    }

    /* -- refresh ------------------------------------------------------- */

    public void set_mcp_count (int count) {
        mcp_count = count;
        sources_mcp.label = count.to_string ();
    }

    /** Shows @message instead of session details. Used while a new
     *  session is being composed: there is no data to show yet, so the
     *  panel stays empty until the conversation actually starts. */
    public void set_placeholder (string message) {
        placeholder = message;
        update ();
    }

    /** Leaves placeholder mode and shows the active session again. */
    public void clear_placeholder () {
        if (placeholder == null) {
            return;
        }
        placeholder = null;
        update ();
    }

    /** Recomputes every section from the store's current state. */
    public void update () {
        if (placeholder != null) {
            empty_label.label = placeholder;
            empty_label.visible = true;
            set_sections_visible (false);
            return;
        }

        var session = store.active_session;
        var has_session = session != null;
        empty_label.label = "Open a session to see its details";
        empty_label.visible = !has_session;
        set_sections_visible (has_session);
        if (session == null) {
            return;
        }

        /* Context */
        double fraction;
        string ctx_label;
        store.context_info (session.id, out fraction, out ctx_label);
        if (fraction >= 0.0) {
            context_bar.value = fraction;
            /* Only touch the CSS classes when the band actually
             *  changed: add/remove of an already-correct class
             *  invalidates the style context. */
            string band = fraction >= 0.92 ? "context-full"
                : (fraction >= 0.75 ? "context-high" : "");
            if (band != last_context_band) {
                context_bar.remove_css_class ("context-high");
                context_bar.remove_css_class ("context-full");
                if (band != "") {
                    context_bar.add_css_class (band);
                }
                last_context_band = band;
            }
            context_label.label = "%.1f%%".printf (fraction * 100.0);
        } else {
            context_bar.value = 0.0;
            context_label.label = "None";
            last_context_band = "";
        }

        /* Project */
        var dir = session.directory;
        project_label.label = session.directory_name != "" ? session.directory_name : "None";
        project_path_label.label = dir != "" ? dir : "None";
        project_path_label.tooltip_text = dir;

        /* Usage */
        var provider_icon = ModelIcons.icon_for (session.provider_id, session.model_id);
        if (provider_icon != last_usage_icon) {
            usage_icon.icon_name = provider_icon;
            last_usage_icon = provider_icon;
        }
        usage_model_label.label = session.model != "" ? session.model : "None";
        var tokens_line = new StringBuilder ();
        if (session.input_tokens > 0) {
            tokens_line.append (@"◊ $(Store.format_tokens (session.input_tokens)) in");
            if (session.output_tokens > 0) {
                tokens_line.append (@" · $(Store.format_tokens (session.output_tokens)) out");
            }
        }
        usage_tokens_label.label = tokens_line.str;

        compute_turn_stats ();

        /* Subagents */
        var runs = store.subagents_for (session.id);
        subagents_count.label = runs.size > 0 ? runs.size.to_string () : "";
        subagents_empty.visible = runs.size == 0;
        update_subagent_rows (runs);

        /* Context sources: both counts read as plain numbers, 0 included,
         *  so the section does not mix placeholders. */
        sources_skills.label = store.skills_count.to_string ();
        sources_mcp.label = mcp_count.to_string ();
    }

    /** Diff the subagent list against the rows already on screen: a
     *  turn fires several events per second and each one used to
     *  destroy and rebuild every row (plus its icon lookups). */
    private void update_subagent_rows (Gee.ArrayList<Store.SubagentRun> runs) {
        var live_ids = new Gee.HashSet<string> ();
        foreach (var run in runs) {
            live_ids.add (run.call_id);
        }
        /* Drop rows whose run is gone. */
        var gone = new Gee.ArrayList<string> ();
        foreach (var id in subagent_rows.keys) {
            if (!live_ids.contains (id)) {
                gone.add (id);
            }
        }
        foreach (var id in gone) {
            var row = subagent_rows[id];
            subagents_box.remove (row);
            subagent_rows.unset (id);
        }
        foreach (var run in runs) {
            Gtk.Box? row = null;
            Gtk.Label? label = null;
            Gtk.Image? icon = null;
            if (subagent_rows.has_key (run.call_id)) {
                row = subagent_rows[run.call_id];
                for (var c = row.get_first_child (); c != null; c = c.get_next_sibling ()) {
                    if (c is Gtk.Label) {
                        label = (Gtk.Label) c;
                    } else if (c is Gtk.Image) {
                        icon = (Gtk.Image) c;
                    }
                }
                /* Keep the existing widget and only rewrite the fields
                 *  that actually changed. */
                var text = run.description != "" ? run.description : "Subagent task";
                if (label != null && label.label != text) {
                    label.label = text;
                    label.tooltip_text = run.description;
                }
                if (icon != null) {
                    var wanted = run.error ? "dialog-warning"
                        : (run.done ? "process-completed" : "system-run");
                    if (icon.icon_name != wanted) {
                        icon.icon_name = wanted;
                    }
                }
                continue;
            }
            row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            icon = new Gtk.Image.from_icon_name (
                run.error ? "dialog-warning"
                : (run.done ? "process-completed" : "system-run")
            ) { pixel_size = 14, valign = Gtk.Align.CENTER };
            label = new Gtk.Label (run.description != "" ? run.description : "Subagent task") {
                xalign = 0,
                hexpand = true,
                ellipsize = Pango.EllipsizeMode.END
            };
            label.add_css_class ("caption");
            label.tooltip_text = run.description;
            row.append (icon);
            row.append (label);
            subagents_box.append (row);
            subagent_rows[run.call_id] = row;
        }
    }

    private void compute_turn_stats () {
        int steps = 0;
        int64 in_tokens = 0;
        int64 out_tokens = 0;
        int64 cache_read = 0;
        int64 cache_write = 0;
        double cost = 0.0;
        int64 first_created = 0;
        int64 last_completed = 0;
        int64 model_time = 0;
        int64 tool_time = 0;

        foreach (var message in store.active_messages) {
            if (message.role == MessageRole.ASSISTANT) {
                steps++;
                in_tokens += message.input_tokens;
                out_tokens += message.output_tokens;
                cache_read += message.cache_read;
                cache_write += message.cache_write;
                cost += message.cost;
                if (message.created > 0) {
                    if (first_created == 0 || message.created < first_created) {
                        first_created = message.created;
                    }
                }
                if (message.completed > message.created && message.created > 0) {
                    model_time += message.completed - message.created;
                    if (message.completed > last_completed) {
                        last_completed = message.completed;
                    }
                }
            }
            foreach (var part in message.parts) {
                if (part.kind == PartKind.TOOL && part.time_completed > part.time_created
                    && part.time_created > 0) {
                    tool_time += part.time_completed - part.time_created;
                }
            }
        }

        stat_steps.label = steps > 0 ? steps.to_string () : "None";
        stat_tokens.label = in_tokens + out_tokens > 0
            ? @"$(Store.format_tokens (in_tokens)) ↑ · $(Store.format_tokens (out_tokens)) ↓"
            : "None";
        var cache_total = cache_read + cache_write;
        stat_cache.label = cache_total > 0
            ? @"%.0f%%".printf (100.0 * cache_read / cache_total) : "None";
        stat_elapsed.label = (last_completed > first_created && first_created > 0)
            ? format_duration (last_completed - first_created) : "None";
        stat_model_time.label = model_time > 0 ? format_duration (model_time) : "None";
        stat_tool_time.label = tool_time > 0 ? format_duration (tool_time) : "None";
        stat_cost.label = cost > 0 ? "$%.4f".printf (cost) : "None";
    }

    private static string format_duration (int64 millis) {
        if (millis < 1000) {
            return "0s";
        }
        var seconds = millis / 1000;
        if (seconds < 60) {
            return @"$(seconds)s";
        }
        var minutes = seconds / 60;
        seconds = seconds % 60;
        if (minutes < 60) {
            return @"$(minutes)m $(seconds)s";
        }
        var hours = minutes / 60;
        minutes = minutes % 60;
        return @"$(hours)h $(minutes)m";
    }

    private void set_sections_visible (bool visible) {
        Gtk.Widget? child = sections.get_first_child ();
        while (child != null) {
            if (child != empty_label) {
                child.visible = visible;
            }
            child = child.get_next_sibling ();
        }
    }
}

}
