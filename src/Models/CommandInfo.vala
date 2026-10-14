/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Slash command metadata from `GET /api/command`, plus the
 * client-side built-ins (compact/new/diff).
 */

namespace OpenClient {

public class CommandInfo : GLib.Object {
    public string name { get; set; default = ""; }
    public string description { get; set; default = ""; }
    public bool builtin { get; set; default = false; }

    public static CommandInfo? from_json (Json.Object obj) {
        var name = JsonUtil.string_member (obj, "name");
        if (name == null) {
            return null;
        }
        return new CommandInfo () {
            name = name,
            description = JsonUtil.string_member (obj, "description") ?? ""
        };
    }
}

}
