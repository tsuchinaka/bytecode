/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Small helpers for moving between string collections and arrays.
 *
 * Vala's Gee `.to_array()` / `.add_all_array (…)` emit the element
 * array as `void **` / `gchar **`, which GCC 14 flags against the
 * gee and GTK prototypes even with -Wno-*, so the handful of round
 * trips in the app go through these instead.
 */

namespace OpenClient {

internal class ListArrays {

    /** Copies a collection into a fresh string[] (order preserved). */
    public static string[] to_string_array (Gee.Collection<string> items) {
        var result = new string[items.size];
        int i = 0;
        foreach (var item in items) {
            result[i++] = item;
        }
        return result;
    }

    /** Adds every element of an array to a set. */
    public static void add_array (Gee.Set<string> set, string[] items) {
        foreach (var item in items) {
            set.add (item);
        }
    }

    /** Joins a collection with `separator`, without the array round trip. */
    public static string join (string separator, Gee.Collection<string> items) {
        var text = new StringBuilder ();
        bool first = true;
        foreach (var item in items) {
            if (!first) {
                text.append (separator);
            }
            text.append (item);
            first = false;
        }
        return text.str;
    }
}

}
