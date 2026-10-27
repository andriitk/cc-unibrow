# Architecture

Unibrow has three parts: a Claude Code **plugin** that registers hooks, a tiny
**relay** that each hook runs, and the **app** that draws the notch.

```
 Claude Code session ──PermissionRequest──▶ plugin shim ─▶ unibrow-hook ──┐
 Claude Code session ──PermissionRequest──▶ plugin shim ─▶ unibrow-hook ──┤  Unix socket
 Claude Code session ──PostToolUse/Stop…──▶ plugin shim ─▶ unibrow-hook ──┤  ~/Library/Application Support/cc-unibrow/unibrow.sock
                                                                            ▼
                                                              Unibrow.app (notch + menu bar)
```

## Components

| Path | Role |
|---|---|
| `plugin/` | The Claude Code plugin: `hooks/hooks.json` and `bin/unibrow-hook`, a POSIX shell shim. The shim execs the relay that the app links on launch, so the plugin never needs to know where the app is installed. Without the app it is a no-op (and says so once per session). |
| `Sources/UnibrowHook` | `unibrow-hook`, the relay. Reads the hook JSON from stdin, adds session details (git branch, repository root, process ancestry), sends it to the app, and for a permission request waits for the decision and prints it in Claude Code's format. |
| `Sources/UnibrowCore` | Everything worth testing, with no UI: wire protocol, hook payloads and output, the pending-request queue, finished-session notices, tool summaries, questions, window-title matching, git and process lookups. |
| `Sources/Unibrow` | The app: socket server, notch panel, SwiftUI views, menu bar, window focus. Kept thin. |
| `.claude-plugin/marketplace.json` | Makes the repository itself a plugin marketplace. |
| `install.sh`, `scripts/` | Installer, app bundling, icon rendering, demo requests. |

## Hooks

| Event | Mode | Used for |
|---|---|---|
| `PermissionRequest` | blocking, 1 h timeout | The cards: tool permissions, `AskUserQuestion`, `ExitPlanMode`. |
| `PostToolUse`, `PostToolUseFailure`, `PermissionDenied` | async | A request was answered elsewhere: drop its card. |
| `UserPromptSubmit`, `SessionEnd` | async | The session moved on: drop its cards and its “finished” notice. |
| `Stop` | async | The turn ended: drop leftover cards, show a “finished” notice. |
| `SessionStart` | sync, 5 s | Installs a missing app, or updates one older than the plugin (below). |

## App install and updates (bootstrap)

On `SessionStart` the shim compares the plugin's version with the app it can
find. With no app, it starts `plugin/bin/unibrow-bootstrap <version>`; with an
app older than the plugin (found through the relay link, which points into the
bundle), it starts `unibrow-bootstrap <version> --update <app>`. Both run
detached from the hook (new session via `setsid`, output to
`~/Library/Logs/cc-unibrow-bootstrap.log`), so the hook returns immediately.

The bootstrap downloads `Unibrow.zip` for exactly that version from GitHub
Releases and installs it only if the SHA-256 published next to it, the code
signature, the bundle ID and the version all match. A first install never
writes over an existing app. An update only replaces a bundle with Unibrow's
bundle ID and a lower version: it quits that copy if it runs (prompts waiting
in the notch fall back to the terminal), swaps the bundles, puts the old one
back if the copy fails, clears Unibrow's Accessibility entry (macOS ties it to
the old ad-hoc build) and starts the new app if the old one was running. A
lock directory keeps concurrent sessions from racing; a failure marker stops
retries (and repeated announcements) for an hour. A release that answers 404
is not a failure: it means the release is still being built, so the bootstrap
keeps the current app, sets no marker and tries again at the next session.
`UNIBROW_NO_AUTO_UPDATE` and `UNIBROW_NO_AUTO_INSTALL` opt out.

Releases come from `main`. Merging a pull request that changes `VERSION` runs
the release workflow: it checks that `VERSION`, `plugin.json` and the
`CHANGELOG.md` section agree, tests, builds the universal app, tags the
merge commit `v<VERSION>` and attaches the app to the release. CI runs the
same version checks on every pull request. The plugin reaches users from
`main` a few minutes before its app is attached; the 404 rule above covers
that gap.

## Wire protocol

One connection per hook invocation over a Unix stream socket; newline-delimited
compact JSON (compact JSON never contains a raw newline).

```
hook ──HookMessage──────▶ app      every event
hook ◀──DecisionMessage── app      PermissionRequest only
```

`HookMessage` carries the raw hook payload untouched, so fields Claude Code adds
later survive, plus `branch`, `projectRoot` and `ancestorPIDs` gathered by the
relay. `DecisionMessage` is one of `allow`, `allowAlways` (forwards Claude Code's
own `permission_suggestions` as `updatedPermissions`), `allowWithInput` (question
answers), `deny` (with `interrupt`) and `passthrough`.

## Safety guarantees

**Fail open to the terminal, never closed.** If the app is not running, is
paused, crashes, or anything goes wrong, the relay exits 0 without output and
Claude Code shows its normal prompt. Unibrow can make a prompt easier to answer;
it can never make one disappear or approve anything on its own.

**A card leaves the list when its request is no longer waiting:**

1. the user answers in the notch;
2. Claude Code ends the hook (answered in the terminal): the socket reaches EOF;
3. a later hook event proves it was handled (tool ran, failed, was denied, the
   turn ended, a new prompt was sent, the session ended);
4. the waiting relay notices its parent died and exits within a second;
5. after one hour, the hook timeout.

**Bounded resources.** At most 100 pending requests (the rest go to the
terminal) and 50 finished notices, which expire after 30 minutes. A card's data
lives only in that card. Large inputs are capped for display only; Claude Code
always receives the full input.

**Approve only what was shown.** `ToolSummary.review` says whether the
one-line headline shows the whole input. If not (several lines, longer than
fits, a separate diff, file contents or plan, escaped characters, non-ASCII
in a command, or input fields the card has no place for), Allow and Always
stay disabled until the card's detail has been opened for that request (the
card remembers the reviewed request's ID, not a flag). Fields the card does
not know turn the detail into the full input as JSON, and safety-relevant
ones such as `dangerouslyDisableSandbox` are called out. If the detail was
capped, Allow stays disabled and the request has to be answered in the
terminal. Control characters (`\r`, ANSI escapes), bidi overrides,
default-ignorable and other invisible characters and non-ASCII spaces are
shown escaped, so text cannot hide or overwrite other text; MCP arguments
are shown as JSON values, so one value cannot pose as another field. Deny is
always available.

**Local and private.** No network code. The socket lives in a `0700` directory
with mode `0600`, and the server checks the peer's UID. The app never reads
project files, so macOS never asks for access to Documents or Desktop; the relay,
which runs inside the user's terminal, reads the git branch instead.

## Finding the session's window

The relay sends its own process ancestry (hook → shell → `claude` → … → app),
collected with `sysctl` so root-owned links such as Terminal's `login` don't
break the chain. tmux servers are followed to their attached clients. The app
picks the first regular, Dock-visible process. To raise the right window it
tries, in order: Accessibility window titles (opt-in, any app), asking the
editor to open the repository root (VS Code family, JetBrains), and finally
activating the app.

## Concurrency

Swift 6 language mode with strict concurrency. The socket server confines its
state to one serial queue and reports events through an `AsyncStream`; the
model and UI are `@MainActor`. Process walks and CLI calls run on detached
utility tasks.
