# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

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
