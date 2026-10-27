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
| `Elicitation` | An MCP server asks for input (a form or a link to open). Sends it to the app and waits for your answer in the notch; without the app, or on any failure, prints nothing and Claude Code shows its own dialog. |
| `StopFailure`, `Notification` (`agent_needs_input` only) | Tells the app that a turn stopped on an API error or that a background agent needs input, so it can show an alert. These run in the background. |
| `PostToolUse`, `PostToolUseFailure`, `PermissionDenied`, `UserPromptSubmit`, `Stop`, `SessionEnd` | Tells the app that a request was answered elsewhere or that a turn finished, so it can remove the card or show a “finished” notice. These run in the background. |
| `SessionStart` | If the app is missing, starts the one-time install below. If the installed app is older than this plugin, starts the same process as an update. Otherwise does nothing. |

**Where data goes.** Hook data is sent only to the Unibrow app on the same Mac,
through a Unix socket in `~/Library/Application Support/cc-unibrow/` that only
your user can open. Nothing is sent to any server. The app keeps requests in
memory only (at most one hour) and writes no conversation data to disk. See the
[privacy policy](https://github.com/andriitk/cc-unibrow/blob/main/PRIVACY.md).

## App install and updates

The notch is drawn by a native app, which a plugin can’t contain. When a
session starts without the app, or with an app older than this plugin,
`bin/unibrow-bootstrap` runs once in the background:

1. Downloads `Unibrow.zip` and `Unibrow.zip.sha256` for exactly this plugin’s
   version from this project’s
   [GitHub Releases](https://github.com/andriitk/cc-unibrow/releases)
   (`https://github.com/andriitk/cc-unibrow/releases/download/v<version>/`).
   These files are built from this repository’s source by a public GitHub
   Actions workflow.
2. Checks the SHA-256 checksum, the app’s code signature, its bundle ID and
   its version. On any mismatch nothing is installed.
3. **Install:** copies `Unibrow.app` to `~/Applications` (never over an
   existing copy) and starts it.
   **Update:** only replaces a `Unibrow.app` with the bundle ID
   `dev.andriitk.unibrow` and a lower version, never downgrades. If that app
   is running, it is quit first (prompts waiting in the notch fall back to the
   terminal) and started again afterwards. If the copy fails, the old app is
   put back. After an update it clears Unibrow’s own Accessibility permission
   (`tccutil reset Accessibility dev.andriitk.unibrow`), because macOS ties
   that permission to the old build; turn **Exact Window Focus** on again in
   the menu if you use it. No other app’s permissions are touched.

It logs to `~/Library/Logs/cc-unibrow-bootstrap.log`. If it fails, for example
offline, Claude Code says so once and it retries after an hour.

To skip automatic updates, set `UNIBROW_NO_AUTO_UPDATE=1`. To skip the
automatic install and updates, set `UNIBROW_NO_AUTO_INSTALL=1` and install the
app yourself from source:
`curl -fsSL https://raw.githubusercontent.com/andriitk/cc-unibrow/main/install.sh | sh`.

## Files the plugin writes

- `~/Applications/Unibrow.app` (the app; replaced only by a newer release)
- `~/Library/Application Support/cc-unibrow/` (socket, a link to the relay, install lock)
- `~/Library/Logs/cc-unibrow-bootstrap.log` (install log)

Remove them all with
`curl -fsSL https://raw.githubusercontent.com/andriitk/cc-unibrow/main/install.sh | sh -s -- --uninstall`.

## Support

Questions and bugs: [GitHub Issues](https://github.com/andriitk/cc-unibrow/issues).
Security reports: [private advisory](https://github.com/andriitk/cc-unibrow/security/advisories/new).

MIT licensed. Unofficial community project, not affiliated with or endorsed by
Anthropic.
