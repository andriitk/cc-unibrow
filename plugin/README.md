# Unibrow for Claude Code

Approve Claude Code from your MacBook notch. Every permission prompt, question,
plan and “finished” notice from all your Claude Code sessions shows up in one
list that grows out of the notch. Answer there, or in the terminal as usual.

This plugin is the Claude Code side of [Unibrow](https://github.com/andriitk/cc-unibrow),
a small open-source macOS app. Full documentation, screenshots and a demo video
are in the [main README](https://github.com/andriitk/cc-unibrow#readme).

## Install

In Claude Code:

```
/plugin install cc-unibrow --marketplace andriitk/cc-unibrow
```

The next session that starts installs the app (see below). Restart sessions
that were already open.

## Requirements

- macOS 14 Sonoma or later
- Claude Code running on that Mac (any terminal, or the terminal inside an IDE)

The plugin works only through Claude Code hooks. In claude.ai chat and Cowork
it has no effect.

## What the plugin does

Everything below is in this folder as plain shell scripts and JSON; nothing
is minified or compiled.

**Hooks** (`hooks/hooks.json`). Each hook runs `bin/unibrow-hook`:

| Hook | What happens |
|---|---|
| `PermissionRequest` | Sends the request to the Unibrow app and waits for your answer in the notch. If the app is not running, is paused or anything fails, the hook prints nothing and Claude Code asks in the terminal as usual. Unibrow never answers on its own. |
| `PostToolUse`, `PostToolUseFailure`, `PermissionDenied`, `UserPromptSubmit`, `Stop`, `SessionEnd` | Tells the app that a request was answered elsewhere or that a turn finished, so it can remove the card or show a “finished” notice. These run in the background. |
| `SessionStart` | If the app is installed, does nothing. If it is not, starts the one-time app install below. |

**Where data goes.** Hook data is sent only to the Unibrow app on the same Mac,
through a Unix socket in `~/Library/Application Support/cc-unibrow/` that only
your user can open. Nothing is sent to any server. The app keeps requests in
memory only (at most one hour) and writes no conversation data to disk. See the
[privacy policy](https://github.com/andriitk/cc-unibrow/blob/main/PRIVACY.md).

## One-time app install

The notch is drawn by a native app, which a plugin can’t contain. The first
time a session starts without the app, `bin/unibrow-bootstrap` runs once in the
background:

1. Downloads `Unibrow.zip` and `Unibrow.zip.sha256` for exactly this plugin’s
   version from this project’s
   [GitHub Releases](https://github.com/andriitk/cc-unibrow/releases)
   (`https://github.com/andriitk/cc-unibrow/releases/download/v<version>/`).
   These files are built from this repository’s source by a public GitHub
   Actions workflow.
2. Checks the SHA-256 checksum and the app’s code signature. On any mismatch
   nothing is installed.
3. Copies `Unibrow.app` to `~/Applications` (it never replaces an existing
   copy) and starts it.

It logs to `~/Library/Logs/cc-unibrow-bootstrap.log`. If it fails, for example
offline, Claude Code says so once and it retries after an hour.

To skip the automatic install, set `UNIBROW_NO_AUTO_INSTALL=1` and install the
app yourself from source:
`curl -fsSL https://raw.githubusercontent.com/andriitk/cc-unibrow/main/install.sh | sh`.

## Files the plugin writes

- `~/Applications/Unibrow.app` (the app, installed once)
- `~/Library/Application Support/cc-unibrow/` (socket, a link to the relay, install lock)
- `~/Library/Logs/cc-unibrow-bootstrap.log` (install log)

Remove them all with
`curl -fsSL https://raw.githubusercontent.com/andriitk/cc-unibrow/main/install.sh | sh -s -- --uninstall`.

## Support

Questions and bugs: [GitHub Issues](https://github.com/andriitk/cc-unibrow/issues).
Security reports: [private advisory](https://github.com/andriitk/cc-unibrow/security/advisories/new).

MIT licensed. Unofficial community project, not affiliated with or endorsed by
Anthropic.
