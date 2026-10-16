# Changelog

## 0.2.0

The first release with everything in place for daily use.

### Added

- Bulk session management: tick sessions in the sidebar and delete them
  in one batch, with a single confirmation.
- Session export to a JSON file through the system save dialog.
- The full v2 REST surface, including revert, inbox, instructions,
  environment, permissions, forms, stats and export.
- Status for turns driven from a terminal: the app taps the background
  `opencode serve --service` that CLI clients use.
- A question wizard: one question per page with Back, a review page and
  Submit.
- The app runs and owns its own OpenCode server, and stops it on exit.

### Changed

- Settings pages are flat label-and-control rows with list actions
  underneath, and the inspector follows the same pattern.
- Status and activity are kept per session, so switching All, Pinned or
  Archived no longer resets a running session's indicator.
- Missing inspector values read `None` instead of a dash.
- The app presents itself as bytecode, an OpenCode client.

### Fixed

- Deleting sessions did nothing: the confirm dialog's button list was
  passed to GTK without a terminator.
- Failed tool calls and question forms never settled, because the event
  names did not match the wire (`session.tool.failed`, `form.replied`).
- The new-session page no longer shows the previous session's title in
  the header bar.
- Agents added during a session appear without a restart.

## 0.1.0

- Initial release: sessions, streaming chat, reasoning output, tool
  cards, model and agent pickers, notifications.
