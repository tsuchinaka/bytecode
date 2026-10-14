/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Safe accessors for json-glib objects. The OpenCode v2 API wraps most
 * payloads in a `{ "data": ... }` envelope and mixes integer/double
 * number types, so all reads go through these helpers.
 */

namespace OpenClient {

public class JsonUtil : GLib.Object {

    public static string? string_member (Json.Object obj, string name) {
        if (!obj.has_member (name)) {
            return null;
        }
        var node = obj.get_member (name);
        if (node.get_node_type () != Json.NodeType.VALUE) {
            return null;
        }
        if (node.get_value_type () == typeof (string)) {
            return node.get_string ();
        }
        return null;
    }

    public static int64 int_member (Json.Object obj, string name, int64 fallback = 0) {
        if (!obj.has_member (name)) {
            return fallback;
        }
        var node = obj.get_member (name);
        if (node.get_node_type () != Json.NodeType.VALUE) {
            return fallback;
        }
        var value_type = node.get_value_type ();
        if (value_type == typeof (int64)) {
            return node.get_int ();
        }
        if (value_type == typeof (double)) {
            return (int64) node.get_double ();
        }
        return fallback;
    }

    public static double double_member (Json.Object obj, string name, double fallback = 0.0) {
        if (!obj.has_member (name)) {
            return fallback;
        }
        var node = obj.get_member (name);
        if (node.get_node_type () != Json.NodeType.VALUE) {
            return fallback;
        }
        var value_type = node.get_value_type ();
        if (value_type == typeof (double)) {
            return node.get_double ();
        }
        if (value_type == typeof (int64)) {
            return (double) node.get_int ();
        }
        return fallback;
    }

    public static bool bool_member (Json.Object obj, string name, bool fallback = false) {
        if (!obj.has_member (name)) {
            return fallback;
        }
        var node = obj.get_member (name);
        if (node.get_node_type () != Json.NodeType.VALUE) {
            return fallback;
        }
        if (node.get_value_type () == typeof (bool)) {
            return node.get_boolean ();
        }
        return fallback;
    }

    public static Json.Object? object_member (Json.Object obj, string name) {
        if (!obj.has_member (name)) {
            return null;
        }
        var node = obj.get_member (name);
        if (node.get_node_type () != Json.NodeType.OBJECT) {
            return null;
        }
        return node.get_object ();
    }

    /** Non-owning list of object elements from an array member. */
    public static GLib.List<weak Json.Object> array_objects (Json.Object obj, string name) {
        var list = new GLib.List<weak Json.Object> ();
        if (!obj.has_member (name)) {
            return list;
        }
        var node = obj.get_member (name);
        if (node.get_node_type () != Json.NodeType.ARRAY) {
            return list;
        }
        var array = node.get_array ();
        for (uint i = 0; i < array.get_length (); i++) {
            var element = array.get_element (i);
            if (element.get_node_type () == Json.NodeType.OBJECT) {
                list.append (element.get_object ());
            }
        }
        return list;
    }

    /** String elements from an array member, skipping non-strings. */
    public static Gee.ArrayList<string> array_strings (Json.Object obj, string name) {
        var result = new Gee.ArrayList<string> ();
        if (!obj.has_member (name)) {
            return result;
        }
        var node = obj.get_member (name);
        if (node.get_node_type () != Json.NodeType.ARRAY) {
            return result;
        }
        var array = node.get_array ();
        for (uint i = 0; i < array.get_length (); i++) {
            var element = array.get_element (i);
            if (element.get_node_type () == Json.NodeType.VALUE &&
                element.get_value_type () == typeof (string)) {
                result.add (element.get_string ());
            }
        }
        return result;
    }

    /** The nodes of a JSON array value. */
    public static Gee.ArrayList<Json.Node> node_array (Json.Node array_node) {
        var result = new Gee.ArrayList<Json.Node> ();
        if (array_node.get_node_type () != Json.NodeType.ARRAY) {
            return result;
        }
        var array = array_node.get_array ();
        for (uint i = 0; i < array.get_length (); i++) {
            result.add (array.get_element (i));
        }
        return result;
    }

    /** `data` member of a response envelope, as an object. */
    public static Json.Object? data_object (Json.Node root) {
        if (root.get_node_type () != Json.NodeType.OBJECT) {
            return null;
        }
        return object_member (root.get_object (), "data");
    }

    /** `data` member of a response envelope, as an array of objects. */
    public static GLib.List<weak Json.Object> data_objects (Json.Node root) {
        if (root.get_node_type () != Json.NodeType.OBJECT) {
            return new GLib.List<weak Json.Object> ();
        }
        return array_objects (root.get_object (), "data");
    }

    /** Objects from either a bare top-level array or a `{data:[...]}`
     *  envelope. Some endpoints (e.g. /api/project) return the former. */
    public static GLib.List<weak Json.Object> root_objects (Json.Node root) {
        if (root.get_node_type () == Json.NodeType.ARRAY) {
            var list = new GLib.List<weak Json.Object> ();
            var array = root.get_array ();
            for (uint i = 0; i < array.get_length (); i++) {
                var element = array.get_element (i);
                if (element.get_node_type () == Json.NodeType.OBJECT) {
                    list.append (element.get_object ());
                }
            }
            return list;
        }
        return data_objects (root);
    }
}

}
