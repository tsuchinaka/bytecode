/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Model and agent metadata fetched from the OpenCode v2 API,
 * plus the provider -> icon mapping used across the UI.
 */

namespace OpenClient {

public class ModelInfo : GLib.Object {
    public string id { get; set; default = ""; }
    public string provider_id { get; set; default = ""; }
    public string name { get; set; default = ""; }
    public string family { get; set; default = ""; }
    public bool enabled { get; set; default = true; }
    public int context_limit { get; set; default = 0; }
    public bool supports_vision { get; set; default = false; }
    public bool supports_tools { get; set; default = false; }
    public Gee.ArrayList<string> variants;
    /** Input modalities advertised by the API (text, image, audio,
     *  video, pdf…). Drives the capability icons in the picker. */
    public Gee.ArrayList<string> input_modalities;

    public ModelInfo () {
        variants = new Gee.ArrayList<string> ();
        input_modalities = new Gee.ArrayList<string> ();
    }

    public string key {
        owned get {
            return @"$provider_id/$id";
        }
    }

    public string icon_name {
        owned get {
            return ModelIcons.icon_for (provider_id, id, name, family);
        }
    }

    public static ModelInfo? from_json (Json.Object obj) {
        var id = JsonUtil.string_member (obj, "id");
        var provider = JsonUtil.string_member (obj, "providerID");
        if (id == null || provider == null) {
            return null;
        }

        var model = new ModelInfo () {
            id = id,
            provider_id = provider
        };
        model.name = JsonUtil.string_member (obj, "name") ?? id;
        model.family = JsonUtil.string_member (obj, "family") ?? "";
        model.enabled = JsonUtil.bool_member (obj, "enabled", true);

        var limit = JsonUtil.object_member (obj, "limit");
        if (limit != null) {
            model.context_limit = (int) JsonUtil.int_member (limit, "context");
        }

        var capabilities = JsonUtil.object_member (obj, "capabilities");
        if (capabilities != null) {
            model.supports_tools = JsonUtil.bool_member (capabilities, "tools", false);
            foreach (var input in JsonUtil.array_strings (capabilities, "input")) {
                model.input_modalities.add (input);
                if (input == "image") {
                    model.supports_vision = true;
                }
            }
        }

        foreach (var variant in JsonUtil.array_objects (obj, "variants")) {
            var variant_id = JsonUtil.string_member (variant, "id");
            if (variant_id != null) {
                model.variants.add (variant_id);
            }
        }

        return model;
    }
}

public class AgentInfo : GLib.Object {
    public string id { get; set; default = ""; }
    public string name { get; set; default = ""; }
    public string description { get; set; default = ""; }
    public string mode { get; set; default = ""; }
    public bool hidden { get; set; default = false; }

    /** Internal agents that should not appear in the picker. */
    private const string[] INTERNAL = { "compaction", "title", "summary", "general" };

    public bool pickable {
        get {
            if (mode != "primary" || hidden) {
                return false;
            }
            foreach (var internal in INTERNAL) {
                if (id == internal) {
                    return false;
                }
            }
            return true;
        }
    }

    public static AgentInfo? from_json (Json.Object obj) {
        var id = JsonUtil.string_member (obj, "id");
        if (id == null) {
            return null;
        }

        var agent = new AgentInfo () { id = id };
        agent.name = JsonUtil.string_member (obj, "name") ?? id;
        agent.description = JsonUtil.string_member (obj, "description") ?? "";
        agent.mode = JsonUtil.string_member (obj, "mode") ?? "primary";
        agent.hidden = JsonUtil.bool_member (obj, "hidden", false);
        return agent;
    }
}

public class ModelIcons : GLib.Object {
    public const string FALLBACK = "applications-science";

    /** Base (theme-agnostic) provider icon name, or "" for unknown
     *  providers. Both the symbolic and the colored icon are derived
     *  from it ("<base>-symbolic" / "<base>"). */
    private static string base_for (string provider_id, string model_id, string name, string family) {
        var haystack = @"$family $model_id $name".down ();

        if (haystack.contains ("claude")) return "anthropic";
        if (haystack.contains ("gpt") || haystack.contains ("o1-") || haystack.contains ("o3-") || haystack.contains ("openai") || haystack.contains ("codex")) return "openai";
        if (haystack.contains ("gemini") || haystack.contains ("google")) return "gemini";
        if (haystack.contains ("deepseek")) return "deepseek";
        if (haystack.contains ("glm") || haystack.contains ("zai")) return "zai";
        if (haystack.contains ("grok")) return "xai";
        if (haystack.contains ("kimi") || haystack.contains ("moonshot")) return "moonshot";
        if (haystack.contains ("qwen")) return "qwen";
        if (haystack.contains ("minimax")) return "minimax";
        if (haystack.contains ("mistral") || haystack.contains ("mixtral")) return "mistral";
        if (haystack.contains ("llama") || haystack.contains ("meta")) return "meta";
        if (haystack.contains ("nemotron") || haystack.contains ("nvidia")) return "nvidia";
        if (haystack.contains ("perplexity") || haystack.contains ("sonar")) return "perplexity";
        if (haystack.contains ("copilot")) return "copilot";
        if (haystack.contains ("muse")) return "meta";
        if (haystack.contains ("mimo") || haystack.contains ("xiaomi")) return "xiaomi";

        switch (provider_id) {
            case "openai":
                return "openai";
            case "anthropic":
                return "anthropic";
            case "gemini":
            case "google":
                return "gemini";
            case "deepseek":
                return "deepseek";
            case "qwen":
                return "qwen";
            case "mistral":
                return "mistral";
            case "meta":
                return "meta";
            case "nvidia":
                return "nvidia";
            case "xai":
                return "xai";
            case "copilot":
                return "copilot";
            case "minimax":
                return "minimax";
            case "moonshot":
                return "moonshot";
            case "xiaomi":
                return "xiaomi";
            case "zai":
                return "zai";
            case "perplexity":
                return "perplexity";
            case "ollama":
                return "ollama";
            case "openrouter":
                return "openrouter";
            case "huggingface":
                return "huggingface";
            default:
                break;
        }

        return "";
    }

    /** Colored brand icon, used across the whole UI (picker, sidebar
     *  avatars, bubbles, panels) so provider identity is consistent. */
    public static string icon_for (string provider_id, string model_id, string name = "", string family = "") {
        /* Lazily built: a static field initializer is not guaranteed to
         *  have run when a static method of the same class is the first
         *  thing that touches the class. */
        if (icon_cache == null) {
            icon_cache = new Gee.HashMap<string, string> ();
        }
        /* Memoized: this runs once per sidebar row per event (plus
         *  every picker row and bubble), and each call otherwise
         *  lowercases and concatenates four strings and runs ~40
         *  substring searches. The key is every input that can change
         *  the outcome. */
        var key = provider_id + "\x1f" + model_id + "\x1f" + name + "\x1f" + family;
        if (icon_cache.has_key (key)) {
            return icon_cache[key];
        }
        var base_name = base_for (provider_id, model_id, name, family);
        var resolved = base_name != "" ? base_name : FALLBACK;
        icon_cache[key] = resolved;
        return resolved;
    }

    private static Gee.HashMap<string, string>? icon_cache = null;

    /** Symbolic (theme-recolored) variant, kept for contexts that need
     *  a monochrome icon. */
    public static string symbolic_icon_for (string provider_id, string model_id, string name = "", string family = "") {
        var base_name = base_for (provider_id, model_id, name, family);
        return base_name != "" ? base_name + "-symbolic" : FALLBACK;
    }
}

}
