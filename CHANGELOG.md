# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.7] - 2026-11-10

### Changed

- The dot and the count beside the notch turn red while a session that
  stopped on an error (rate limit, overload, sign-in, billing and others) is
  shown, the same red as its card. Requests and other alerts keep them
  orange.

## [0.2.6] - 2026-11-06

### Added

- MCP server requests (elicitations) in the notch. A form shows as native
  fields (text, email, URL, date, numbers, yes/no, single and multiple
  choice) with the server's rules checked before Submit; password- and
  token-like fields are hidden. Sign-in links show the full URL with the real
  host highlighted (international names as punycode) and open only when you
  click Open; links with a user name before the host, an encoded host or
  characters browsers read differently are shown but not opened. Submit,
  Decline and Cancel answer the server. Claude Code shows no dialog while
  the card waits, so the card counts down and after about two minutes (110
  seconds) the request moves to Claude Code's own dialog; forms the notch
  cannot show and a paused or closed app go there right away.
- An alert when a turn stops on an API error (rate limit, overload, sign-in,
  billing and others), with the details one click away, and when a
  background agent needs your input. Click to jump to the session.
- The plugin leaves `Unibrow.app` alone (no install, update or start) while
  a compatible host app serves the same socket and says so in
  `~/Library/Application Support/cc-unibrow/host.json`. Removing that app
  brings Unibrow back at the next session. Contract in
  `docs/ARCHITECTURE.md`.
- `SubagentStart` and `SubagentStop` hooks: the relay passes them, with
  `agent_id` and `agent_type`, to the app.
- An **Impact** line on permission cards for risky shell commands: a force
  push shows the remote's host and repository, the branch and how many
  commits on the remote would be overwritten (as of the last fetch);
  `git reset --hard`, `git checkout -- .`, `git restore` and `git clean -f`
  show how many files would be lost; `rm -r` shows each target's real path,
  whether it exists, how many items it holds (up to 10,000) and whether it is
  outside the project, the home folder or a top-level folder; `gh pr
  create|merge`, `gh repo delete|archive`, `gh release create|delete` and
  `gh api -X DELETE` show the account and repository. Read-only lookups,
  at most 0.3 s; an unclear command gets no line. Allow is unaffected.
- Cards, alerts and finished notices show how many subagents are running in
  that session ("2 agents", types on hover), without pulsing or opening the
  notch.
- README and SECURITY.md: other plugins' hooks and Claude Code mods can
  answer a permission request before or instead of Unibrow; mods run
  unsandboxed with your permissions.

### Changed

- The "Finished" header in the notch drops its check icon (the rows already
  show one), and a project header shows its count in parentheses:
  `my-project (2)`. The README has a new demo video and a link to the
  website.
- For developers: the notch views are now the `UnibrowNotchUI` library,
  and `UnibrowCore` and `UnibrowNotchUI` are library products, so another
  app can show the same notch by depending on this package. The views
  talk to the app only through the `NotchHost` protocol. Nothing changes
  in the app. See "Notch UI library" in `docs/ARCHITECTURE.md`.
- The relay protocol is at version 2 (adds the subagent events). The app
  accepts versions 1 and 2, and reads a message without a version as 1.
  The impact note travels as a new optional `impact` field, so it needs no
  new version.
- The plugin's shell scripts moved from `plugin/bin/` to `plugin/scripts/`:
  they are hook scripts, not commands for the Bash tool. The hooks call them
  by their new path; nothing else changes.
- The plugin's own messages and README no longer suggest piping the
  installer into a shell; they link to the install and uninstall
  instructions in the main README instead.
- The hook script prints its one-line JSON message with a single command,
  checks version numbers before printing them, and keeps the bootstrap's
  output and errors in its log without merging the two streams.

### Security

- Without the app, the plugin's hook script now reads its whole input before
  exiting, so Claude Code 2.1.299+ never sees a hook it "could not hand its
  input" (which it may answer with a refusal) and keeps asking as usual.

- The notch shows when a request is not fully visible. A long or multi-line
  command, an edit, file contents or a plan is marked (line count, cut or
  escaped content) with "Show full …"; Allow and Always stay one click.
  Control characters, ANSI escapes, bidi overrides and invisible characters
  are shown escaped.
- Input with fields the card does not show (for example `timeout` or
  `dangerouslyDisableSandbox`, which is highlighted) and commands with
  non-ASCII characters are flagged; the detail then shows the full input.
  MCP arguments are shown as JSON values (`repo: "a/b"`).

### Fixed

- A card now leaves the notch as soon as Claude Code reports that its request
  was decided elsewhere, in more cases: an `AskUserQuestion` answered or a
  plan accepted in the terminal (their input changes when answered, so the
  card used to wait for the end of the turn), and a request refused in the
  terminal with feedback (new `PostToolBatch` hook). A subagent's tool calls
  no longer drop the main conversation's identical request. Claude Code
  keeps the hook running after a terminal or auto-mode approval and fires no
  event until the tool ends, so a long command approved in the terminal
  still keeps its card until it finishes.
- `make install` no longer stops before launching the app when macOS has no
  Accessibility grant to reset (for example on the first install, or after
  the app was removed).

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
