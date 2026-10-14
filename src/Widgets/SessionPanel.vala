/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Right-hand session inspector, OpenChamber-style: context meter,
 * project, model usage, turn stats, subagent runs and context
 * sources — all read from data the app already has (no invented
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

    /* Context sources */
    private Gtk.Label sources_skills;
    private Gtk.Label sources_mcp;

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

        var scrolled = new Gtk.ScrolledWindow () {
            vexpand = true,
            hscrollbar_policy = Gtk.PolicyType.NEVER
        };        sections = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        scrolled.child = sections;
        append (scrolled);

        empty_label = new Gtk.Label ("Open a session to see its details") {
            wrap = true,
            justify = Gtk.Justification.CENTER,
            margin_top = 32,
            margin_start = 16,
            margin_end = 16
        };
        empty_label.add_css_class ("dim-label");
        sections.append (empty_label);

        build_context ();
        build_project ();
        build_usage ();
        build_turn_stats ();
        build_subagents ();
        build_sources ();
    }

    /* -- section scaffolding ------------------------------------------ */

    private Gtk.Box section_header (string title, out Gtk.Label value) {
        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            margin_top = 12,
            margin_bottom = 4,
            margin_start = 12,
            margin_end = 12
        };
        var label = new Gtk.Label (title) { xalign = 0, hexpand = true };
        label.add_css_class ("panel-section-title");
        value = new Gtk.Label ("") { xalign = 1 };
        value.add_css_class ("dim-label");
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
        key_label.add_css_class ("dim-label");
        key_label.add_css_class ("caption");
        value = new Gtk.Label ("—") { xalign = 1 };
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
        project_path_label.add_css_class ("monospace");
        add_section (header, project_path_label);
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
        var header = section_header ("Turn stats", out value);
        value.label = "";

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) { margin_bottom = 6 };
        box.append (stat_row ("Steps", out stat_steps));
        box.append (stat_row ("Tokens", out stat_tokens));
        box.append (stat_row ("Cache", out stat_cache));
        box.append (stat_row ("Elapsed", out stat_elapsed));
        box.append (stat_row ("Model time", out stat_model_time));
        box.append (stat_row ("Tool time", out stat_tool_time));
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
        subagents_empty.add_css_class ("dim-label");
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
        var header = section_header ("Context sources", out value);
        value.label = "";

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) { margin_bottom = 12 };
        box.append (stat_row ("Skills", out sources_skills));
        box.append (stat_row ("MCP servers", out sources_mcp));
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
        var fraction = store.context_fraction (session.id);
        if (fraction >= 0.0) {
            context_bar.value = fraction;
            context_bar.remove_css_class ("context-high");
            context_bar.remove_css_class ("context-full");
            if (fraction >= 0.92) {
                context_bar.add_css_class ("context-full");
            } else if (fraction >= 0.75) {
                context_bar.add_css_class ("context-high");
            }
            context_label.label = "%.1f%%".printf (fraction * 100.0);
        } else {
            context_bar.value = 0.0;
            context_label.label = "—";
        }

        /* Project */
        var dir = session.directory;
        project_label.label = session.directory_name != "" ? session.directory_name : "—";
        project_path_label.label = dir != "" ? dir : "—";
        project_path_label.tooltip_text = dir;

        /* Usage */
        usage_icon.icon_name = ModelIcons.icon_for (session.provider_id, session.model_id);
        usage_model_label.label = session.model != "" ? session.model : "—";
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
        clear_box (subagents_box);
        subagents_count.label = runs.size > 0 ? runs.size.to_string () : "";
        subagents_empty.visible = runs.size == 0;
        foreach (var run in runs) {
            var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            var icon = new Gtk.Image.from_icon_name (
                run.error ? "dialog-warning"
                : (run.done ? "process-completed" : "system-run")
            ) { pixel_size = 14, valign = Gtk.Align.CENTER };
            var label = new Gtk.Label (run.description != "" ? run.description : "Subagent task") {
                xalign = 0,
                hexpand = true,
                ellipsize = Pango.EllipsizeMode.END
            };
            label.add_css_class ("caption");
            label.tooltip_text = run.description;
            row.append (icon);
            row.append (label);
            subagents_box.append (row);
        }

        /* Context sources */
        sources_skills.label = store.skills_count > 0
            ? store.skills_count.to_string () : "—";
        sources_mcp.label = mcp_count > 0 ? mcp_count.to_string () : "0";
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

        stat_steps.label = steps > 0 ? steps.to_string () : "—";
        stat_tokens.label = in_tokens + out_tokens > 0
            ? @"$(Store.format_tokens (in_tokens)) ↑ · $(Store.format_tokens (out_tokens)) ↓"
            : "—";
        var cache_total = cache_read + cache_write;
        stat_cache.label = cache_total > 0
            ? @"%.0f%%".printf (100.0 * cache_read / cache_total) : "—";
        stat_elapsed.label = (last_completed > first_created && first_created > 0)
            ? format_duration (last_completed - first_created) : "—";
        stat_model_time.label = model_time > 0 ? format_duration (model_time) : "—";
        stat_tool_time.label = tool_time > 0 ? format_duration (tool_time) : "—";
        stat_cost.label = cost > 0 ? "$%.4f".printf (cost) : "—";
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

    private static void clear_box (Gtk.Box box) {
        Gtk.Widget? child = box.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            box.remove (child);
            child = next;
        }
    }
}

}
