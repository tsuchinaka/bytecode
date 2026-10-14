# OpenCode Client

A native [OpenCode](https://opencode.ai) client for elementary OS.

Built with **Vala + GTK4 + Granite**, talking directly to the OpenCode
server API (`opencode serve`). No Electron, no web view, no Node.js
runtime in the app itself.

## Why this exists

OpenChamber proves the idea — a GUI over the OpenCode agent — but it
ships as an Electron/React app. This project takes the same idea and
builds it natively for elementary OS:

| | OpenChamber | This client |
|---|---|---|
| Runtime | Electron + Node.js | Native (C via Vala) |
| UI | React in a web view | GTK4 + Granite |
| Memory | several hundred MB | a few dozen MB |
| Styling | custom CSS | follows the system stylesheet |

## Architecture

```
┌──────────────────────────────────────────┐
│  OpenCode Client (Vala / GTK4)           │
│                                          │
│  Widgets ── Store ── Client (REST)       │
│              │       EventStream (SSE)   │
└──────────────┼───────────────────────────┘
               │  HTTP Basic + text/event-stream
┌──────────────▼───────────────────────────┐
│  opencode serve (v2 API)                 │
└──────────────────────────────────────────┘
```

- `src/Services/Client.vala` — REST client (libsoup 3), auth via
  HTTP Basic (`opencode:<password>`).
- `src/Services/EventStream.vala` — SSE reader for `GET /api/event`
  with exponential-backoff reconnect.
- `src/Services/Store.vala` — turns raw events (`session.text.delta`,
  `session.reasoning.delta`, `session.execution.*`, …) into
  view-friendly signals.
- `src/Widgets/` — sidebar, chat view, message bubbles, composer,
  connection dialog. Two-pane layout following the elementary OS
  panes pattern.

## Requirements

- elementary OS 8 (or a distro with GTK4, Granite 7 and libsoup 3)
- `opencode` (v2) installed and a server running

Runtime build dependencies:

```bash
sudo apt install valac meson libgtk-4-dev libgranite-7-dev \
                 libsoup-3.0-dev libjson-glib-dev libgee-0.8-dev
```

## Running the server

```bash
opencode serve --port 4096
```

The server prints a password at startup (also honored:
`OPENCODE_PASSWORD` in the environment). Enter host, port and password
in the app's connection dialog on first run.

## Building

```bash
meson setup build --prefix=/usr
meson compile -C build
```

Run without installing:

```bash
./build/io.github.haruki.openclient
```

Or install system-wide:

```bash
sudo meson install -C build
```

## Features

- Sessions: list, create, delete, rename, fork
- Live CLI sync: prompts sent from the CLI appear instantly, titles
  update live, reconnects resync automatically
- Chat with throttled streaming text + reasoning (coalesced renders,
  autoscroll with intent: each new message reveals from the top,
  live output is followed only while you stay at the bottom —
  scrolling up freezes the view and shows a "Latest" pill)
- Stop/interrupt a running turn
- Live status dots, per-session cost and token counts
- Live activity indicators on each session avatar: spinner while the
  model works (with tooltip naming the tool: "Running · Bash"),
  accent dot while it waits on you
- Pending-turn placeholder: your message echoes instantly and a spinner
  with rotating playful lines ("Doing the cookies…") covers the wait
  until the first streamed content lands
- Session switching without desync: live turns keep accumulating in the
  background and replay into the view when you come back; rapid
  switches can never leak one session's history into another
- Your bubbles show a "You · time" header mirroring the assistant's
  line, with image thumbnails inline
- Paste images from screenshots and files copied in the file manager
- In-window Settings, elementary style: category sidebar
  (Connection, Appearance, Behavior, Workspace, Providers,
  Credentials, MCP servers, Worktrees) with H2 titles, card groups
  led by H4 section labels and HIG list rows — no separate window,
  a single place for host, port and password
- Connection page: live server status with version, one-click Test
  against the entered credentials, Save & Reconnect
- Appearance page: color-scheme override (System / Light / Dark),
  applied instantly and remembered
- Behavior page: master desktop-notification switch with per-event
  toggles (finished turns, permission requests, question prompts),
  playful status lines, Ctrl+Enter-to-send for the composer, and
  delete-session confirmation — every switch saved instantly and
  honored everywhere
- Providers with live detail: endpoint, models served, context max,
  scoped to the open session's folder; editing opencode.jsonc
  anywhere reloads the page in real time (file monitor, no polling)
- Per-session workspace: the New Session page is a normal chat-style
  hero ("What are we working on?") with the folder chosen right from
  the input card (agent, model and thinking-level pickers inline) and
  suggestion chips that fill the box; send stays locked until a
  folder is set. The server fixes the directory at creation, so it
  can never desync mid-conversation
- Right-hand session inspector (toggle in the chat header): context
  meter, project folder, model usage, turn stats (steps, tokens,
  cache, elapsed, model/tool time, cost), subagent runs (task calls,
  live and from history) and context sources (skills, MCP servers)
- Desktop notifications: turn finished/failed on background sessions,
  permission requests with Allow once / Reject buttons, question
  prompts — only when you are not already looking at that session
- Model picker with search, thinking-level variants and colored
  capability icons (text, vision, audio, video, PDF, tool calling)
  plus colored provider brand logos used consistently across the UI
  (picker, sidebar avatars, message bubbles, session panel)
- Pickers (model/agent/thinking level) and the slash-command list
  use native GTK popovers sized to their content, with the server-side
  catalog deduplicated so no model or agent ever appears twice
- Agent picker (permissions mode: Plan, Build, …)
- Permission requests: Allow Once / Always / Reject banner
- Rich tool cards: per-tool icon, one-line summary (command, path,
  URL, query), animated spinner while running, expandable details
  with full output and image results — live via SSE tool events
- Verbose thinking by default: single "Thinking…" line (symbolic
  icon + spinner, no duplicated status), "Thought for Xs" with
  duration when done; quiet card-style "↓ Latest" pill
- Live session changes chip (+N −M · F files) refreshed after every
  step, opening the diff viewer
- Agent question forms: full OpenCode form support — string, number,
  integer, boolean, multiselect, dropdowns (with optional custom
  answers), external links, conditional `when` fields, hidden fields,
  per-field constraints (min/max length/value, min/max items, email/
  URL formats, placeholders), client-side validation before submit,
  and Cancel to settle the question server-side
- Centered system dividers (rules + icon, no bubble) for
  compaction, model/agent switches, retries — and failed turns, with
  the real provider error message instead of silence
- Failures persist: turns the server stored with finish "error" render
  their error line from history, surviving restarts and session hops
- Compaction anywhere: manual `/compact` or automatic — shows a
  live braille spinner and streams the summary into an expander
- Slash commands in the composer: `/compact`, `/new`, `/diff`
  plus every server command (`/init`, `/review`, …) with a
  filtered picker (↑/↓ + Enter)
- CLI-style braille spinners (⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏) for thinking, tool
  execution, generation, compaction and retry states
- Thinking level lives in its own picker next to the model picker
- Image attachments: paste from clipboard, drag-and-drop or file
  picker; thumbnails in the composer and in history
- File handling through XDG desktop portals (no direct file-chooser
  dialogs): workspace folder and image picking, opening the server
  config in its default app, "Show in Files" for the workspace —
  the same code works sandboxed and unsandboxed
- Context meter per session (input tokens vs model limit)
- Session changes viewer (unified diffs per file)
- Context compaction from the sidebar
- Connection dialog with validation, config in
  `~/.config/opencode-client/client.conf`
- Follows the system light/dark color scheme (and adapts live),
  keyboard shortcuts (`Ctrl+N` new session, `Ctrl+,` settings)

## Roadmap

- [ ] Markdown: syntax highlighting for code blocks
- [ ] Manage the `opencode serve` process from the app
- [ ] Flatpak packaging

## Configuration

Stored in `~/.config/opencode-client/client.conf`:

```ini
[connection]
host=127.0.0.1
port=4096
password=...
```

Environment overrides: `OPENCODE_HOST`, `OPENCODE_PORT`,
`OPENCODE_PASSWORD`.

## License

GPL-3.0-or-later
