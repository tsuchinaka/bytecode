# Troubleshooting

## The app cannot reach a server

Settings > Connection shows the managed server's state, and the
**Server Log** button opens the log the server writes
(`~/.local/state/opencode-client/serve.log`).

- If the port is taken, the app moves to the next free one and records
  it in the config, so a stale process on 4599 is not fatal.
- After changing the command, port or passcode, press
  **Apply & Restart Server**.
- To use a server you run yourself, turn the managed switch off and fill
  in host, port and password. This is the right choice when a TUI is
  attached to that server.

Config lives in `~/.config/opencode-client/client.conf`:

```ini
[server]
managed=true
command=opencode
port=4599
password=<generated on first run>
```

## Sessions driven from a terminal do not light up

Terminal clients (`opencode`, `opencode run`) talk to the background
service, a different server on its own port, which shares the session
database. The app taps that service's event stream so their turns move
the sidebar indicators.

Check `opencode service status`. If it is not running, only the app's own
turns move the indicators. Settings > Connection says which case the app
is in.

## A question card never appears

Question forms arrive on the session's event stream and open above the
composer. If a card is missing, the turn is likely waiting on a
permission request instead: the banner above the input shows it, and the
permission mode button (Always ask / Read-only / Allow YOLO) decides how
much it asks.

## Agents or models are missing from the pickers

Both follow the server's catalog. The app watches `opencode.jsonc` and
the `agents/` directory, so an agent added mid-session appears within a
second; a **Server configuration reloaded** toast confirms it.

## Deleting a session fails

The confirmation dialog has to be answered first. If the delete still
fails, the toast carries the server's error; a session that is mid-turn
can refuse deletion until the turn settles.

## Attachments

Images are attached with the paperclip, by dropping files on the input,
or by pasting (Ctrl+V) a screenshot or copied image file. File handling
goes through the XDG desktop portal, so it also works inside a sandbox.

## Where things are

| Path | Contents |
| --- | --- |
| `~/.config/opencode-client/client.conf` | connection and app settings |
| `~/.local/state/opencode-client/serve.log` | the app server's log |
| `~/.local/share/opencode/opencode.db` | sessions (shared with the CLI) |
