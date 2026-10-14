/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Server-sent events client for `GET /api/event`.
 *
 * Reads the SSE stream line by line off a libsoup-3 response stream
 * and forwards every `data:` payload to the store. Reconnects with
 * exponential backoff when the stream drops.
 */

namespace OpenClient {

public delegate void EventHandler (string type, Json.Object data);

public class EventStream : GLib.Object {
    public signal void connected ();
    public signal void connection_error (string message);

    public EventHandler? event_handler = null;

    public string base_url { get; construct; }
    public string auth_header { get; construct; }

    private Soup.Session soup;
    private GLib.Cancellable? cancellable = null;
    private bool running = false;
    private bool is_connected = false;
    private uint backoff_ms = 1000;

    public EventStream (string base_url, string auth_header) {
        Object (base_url: base_url, auth_header: auth_header);
    }

    construct {
        soup = new Soup.Session () {
            user_agent = "openclient/0.1"
        };
    }

    public void start () {
        if (running) {
            return;
        }
        running = true;
        reconnect_loop.begin ();
    }

    public void stop () {
        running = false;
        if (cancellable != null) {
            cancellable.cancel ();
        }
    }

    private async void delay (uint ms) {
        SourceFunc callback = delay.callback;
        Timeout.add_once (ms, () => callback ());
        yield;
    }

    private async void reconnect_loop () {
        while (running) {
            cancellable = new GLib.Cancellable ();

            try {
                yield run_once ();
            } catch (Error e) {
                if (running) {
                    connection_error (e.message);
                }
            }

            is_connected = false;
            if (!running) {
                break;
            }

            yield delay (backoff_ms);
            backoff_ms = uint.min (backoff_ms * 2, 30000);
        }
    }

    private async void run_once () throws Error {
        var message = new Soup.Message ("GET", base_url + "/api/event");
        message.request_headers.append ("Authorization", auth_header);
        message.request_headers.append ("Accept", "text/event-stream");
        message.request_headers.append ("Cache-Control", "no-cache");

        var stream = yield soup.send_async (message, GLib.Priority.DEFAULT, cancellable);

        if (message.status_code != 200) {
            throw new RequestError.HTTP_ERROR (@"Event stream HTTP $(message.status_code)");
        }

        if (!is_connected) {
            is_connected = true;
            backoff_ms = 1000;
            connected ();
        }

        var data_stream = new DataInputStream (stream);
        while (running) {
            var line = yield data_stream.read_line_async (GLib.Priority.DEFAULT, cancellable);
            if (line == null) {
                break;
            }
            if (!line.has_prefix ("data: ")) {
                continue;
            }
            parse_event (line.substring (6).strip ());
        }

        if (running) {
            throw new RequestError.NETWORK_ERROR ("event stream closed");
        }
    }

    private void parse_event (string payload) {
        if (payload == "") {
            return;
        }

        var parser = new Json.Parser ();
        try {
            parser.load_from_data (payload);
        } catch (Error e) {
            return;
        }

        var root = parser.get_root ();
        if (root.get_node_type () != Json.NodeType.OBJECT) {
            return;
        }

        var obj = root.get_object ();
        var type = JsonUtil.string_member (obj, "type");
        if (type == null) {
            return;
        }

        var data = JsonUtil.object_member (obj, "data");
        if (data == null) {
            return;
        }

        if (event_handler != null) {
            event_handler (type, data);
        }
    }
}

}
