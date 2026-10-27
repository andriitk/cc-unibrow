# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Security

- The notch no longer lets you allow a request you could not fully see. A long
  or multi-line command, an edit, file contents or a plan has to be opened
  with "Show full …" before Allow and Always turn on; the card shows the line
  count and marks cut or escaped content. Control characters, ANSI escapes,
  bidi overrides and invisible characters are shown escaped. Input too long
  to show in full is answered in the terminal.
- Input with fields the card does not show (for example `timeout` or
  `dangerouslyDisableSandbox`, which is highlighted) and commands with
  non-ASCII characters also have to be opened first; the detail then shows
  the full input. MCP arguments are shown as JSON values (`repo: "a/b"`).

## [0.2.5] - 2026-10-22

### Added

- The menu shows the running app version, so you can tell whether an update
  arrived.

## [0.2.4] - 2026-10-22

### Fixed

- A plugin update that arrives while its release is still being built no
  longer blocks the app update for an hour. The plugin keeps the current app
  and tries again at the next session.

### Changed

- Releases are cut by merging a version bump into `main`; CI tags and
  publishes them. The contributing guide describes the pull request flow.

## [0.2.3] - 2026-10-22

### Fixed

- Pause now silences the notch completely: "finished" notices no longer show
  while paused, and requests already waiting in the notch go back to the
  terminal the moment you pause.

## [0.2.2] - 2026-10-22

### Fixed

- After an app update, Exact Window Focus could look enabled in System
  Settings but not work, because macOS ties the Accessibility permission to
  the old build. The update now clears Unibrow's old entry, so the menu shows
  the feature as off and one click grants it to the new build.

## [0.2.1] - 2026-10-21

### Added

- The plugin keeps the app up to date: when a session starts and the installed
  app is older than the plugin, it downloads the matching release, verifies it
  like the first install (SHA-256, code signature, bundle ID, version), quits
  the old app and starts the new one. It never downgrades and only replaces
  Unibrow itself. Set `UNIBROW_NO_AUTO_UPDATE=1` to opt out.
- Demo video, privacy policy and a plugin README for Anthropic's plugin
  directory.

### Changed

- Hooks other than `SessionStart` reach the app with one less process.

## [0.2.0] - 2026-10-21

### Added

- Install with one command inside Claude Code: on first start the plugin
  downloads the matching Unibrow.app from GitHub Releases, verifies its
  SHA-256 and code signature, installs it to `~/Applications` and starts it.
  No Swift or Command Line Tools needed. Set `UNIBROW_NO_AUTO_INSTALL=1` to
  opt out.
- Universal (Apple silicon and Intel) app builds attached to every release by
  CI.

### Fixed

- The repository lookup could loop forever outside a git repository on some
  macOS versions.

## [0.1.0] - 2026-10-21

First public release.

### Added

- Notch island with collapsed, peek and expanded states; a virtual notch on
  displays without one.
- Pending permission requests from every Claude Code session, grouped by
  project, with Allow, Always and Deny.
- Answers to Claude's questions (`AskUserQuestion`), including free text, and
  plan approval (`ExitPlanMode`) with Approve and Keep Planning.
- Quiet green "finished" notices when a session completes its turn.
- Project, git branch, session tag, subagent and host app on every card; jump
  to the session's app, or its exact window with Accessibility access.
- Requests answered in the terminal leave the list (hook closed, later hook
  events, orphaned relay, expiry).
- Claude Code plugin and marketplace; `unibrow-hook` relay that always falls
  back to the terminal prompt.
- One-command installer, in-app plugin check and install, and a hint from the
  plugin when the app is missing.
- Menu bar settings: pause, deny stops the turn, sound, finished notices,
  launch at login, exact window focus.
