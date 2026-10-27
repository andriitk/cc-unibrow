# Architecture

Unibrow has three parts: a Claude Code **plugin** that registers hooks, a tiny
**relay** that each hook runs, and the **app** that draws the notch.

```
 Claude Code session ──PermissionRequest──▶ plugin shim ─▶ unibrow-hook ──┐
 Claude Code session ──Elicitation────────▶ plugin shim ─▶ unibrow-hook ──┤  Unix socket
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
| `Elicitation` | blocking, 1 h timeout | MCP server requests: a form or a URL to open (below). |
| `StopFailure` | async | The turn ended on an API error: drop the session's cards, show an alert. |
| `Notification` (matcher `agent_needs_input`) | async | A background agent waits for input: show an alert. |
| `PostToolUse`, `PostToolUseFailure`, `PermissionDenied` | async | A request was answered elsewhere: drop its card. |
| `UserPromptSubmit`, `SessionEnd` | async | The session moved on: drop its cards, alert and “finished” notice. |
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
hook ◀──DecisionMessage── app      PermissionRequest, Elicitation
```

`HookMessage` carries the raw hook payload untouched, so fields Claude Code adds
later survive, plus `branch`, `projectRoot` and `ancestorPIDs` gathered by the
relay. `DecisionMessage` is one of `allow`, `allowAlways` (forwards Claude Code's
own `permission_suggestions` as `updatedPermissions`), `allowWithInput` (question
answers), `deny` (with `interrupt`), `elicitation` (`action` accept, decline
or cancel, with `content` for a form) and `passthrough`. The relay prints a
decision only for the event it belongs to; anything else prints nothing. For
an `Elicitation` the relay also sends `propertyOrder`, the form's property
names read from the raw input, because decoded JSON objects lose their order.

## MCP elicitations

An `Elicitation` hook waits in the same queue as permission requests
(`PendingRequest.elicitation`), so pausing, the 100-request cap, grouping by
project, the one-hour expiry and the connection-closed rule all apply.
`ElicitationRequest` turns the payload into one of three cards:

- **Form.** `ElicitationForm` accepts the MCP schema subset: a flat object of
  `string` (formats `email`, `uri`, `date`, `date-time`, `minLength`,
  `maxLength`), `number`/`integer` (`minimum`, `maximum`), `boolean`, single
  choice (`enum` with optional `enumNames`, or `oneOf` of `{const, title}`)
  and multiple choice (`array` of such `items`, `minItems`, `maxItems`), with
  `required`, `title`, `description` and `default`. Values are validated in
  the core; `content` holds only valid, non-empty values keyed by property
  name. Fields whose name, title or format look like a password or token are
  secure fields. Values are never logged.
- **URL.** `ElicitationLink` parses the URL once with `URLComponents`; the
  scheme, user info, host and the rest shown on the card, and the URL that
  opens, all come from that one parse, so a parser differential cannot show
  one host and open another (`https://good.com\@evil.com`). The host is
  highlighted; an international host is shown as punycode with its Unicode
  form flagged. The link opens only on a click, and only when it is `http` or
  `https`, has a host, no user info, no percent-encoded host, no `\`,
  whitespace, control or format characters, and the parsed URL is exactly
  the text sent (international host to punycode is the only rewrite allowed).
  Otherwise the card says why and offers the terminal. **Open** opens the
  browser and answers `accept`, since Claude Code does not open the URL itself
  once a hook accepted.
- **Unsupported** (another type, a nested or malformed schema, more than 25
  fields or 100 options, a URL request without a URL): the card offers
  **Answer in Terminal** (no output, so Claude Code shows its dialog) and
  Decline. Claude Code 2.1.296 already rejects schemas outside the MCP subset
  before hooks run, so in practice this is mostly the size limits.

Every server string shown (server name, message, titles, descriptions, option
titles, URL parts) is escaped with `ToolSummary`'s rules and capped. Values
sent back (property names, option `const`s, the URL opened) stay exact.

**Measured with Claude Code 2.1.296** (a stdio MCP server in an interactive
session): Claude Code runs the `Elicitation` hook *before* it shows its own
dialog and shows the dialog only if the hook prints nothing. So while a card
waits, the terminal shows "running Elicitation hook" and no dialog; this is
different from a permission request. Pressing Esc in the terminal interrupts
the turn but does not end the hook; the dialog then appears once the hook
returns. The `elicitation_response` notification carries only the server name
in its message text and no elicitation ID, so Unibrow does not use it to drop
cards. A card leaves the notch when it is answered, sent to the terminal, when
the hook ends (EOF), when the session moves on (`UserPromptSubmit`, `Stop`,
`StopFailure`, `SessionEnd`), or after the hook timeout. Elicitations from
`claude -p` never reach hooks (Claude Code cancels them).

## Alerts

`SessionAlert` covers what needs the user without a request to answer:
`StopFailure` (the error type mapped to a readable title and a hint, the
escaped `error_details` and API error text behind **Details**) and
`agent_needs_input` notifications. One alert per session; a new one replaces
the old. It goes away when the user opens or dismisses it, when the session
moves on (`UserPromptSubmit`, `Stop`, `SessionEnd`, a new request; tool
activity also clears an "agent needs input" alert), or after 30 minutes.
Pause hides alerts like everything else. **Show Finished Sessions** does not
apply to them: a failed turn or a waiting agent is not a "done" FYI, it needs
the user. They play the request sound when sounds are on.

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

**Show what is hidden.** `ToolSummary.review` says whether the one-line
headline shows the whole input. If not (several lines, longer than fits, a
separate diff, file contents or plan, escaped characters, non-ASCII in a
command, or input fields the card has no place for), the card marks it and
offers "Show full …". Allow and Always stay enabled (owner's decision: no
forced extra click); `Review.allowsApproval` remains for callers that want to
gate. Fields the card does not know turn the detail into the full input as
JSON, and safety-relevant ones such as `dangerouslyDisableSandbox` are called
out. A capped detail is flagged and points to the
terminal. Control characters (`\r`, ANSI escapes), bidi overrides,
default-ignorable and other invisible characters and non-ASCII spaces are
shown escaped, so text cannot hide or overwrite other text; MCP arguments
are shown as JSON values, so one value cannot pose as another field. Deny is
always available.

**Local and private.** No network code. The socket lives in a `0700` directory
with mode `0600`, and the server checks the peer's UID. The app never reads
project files, so macOS never asks for access to Documents or Desktop; the relay,
which runs inside the user's terminal, reads the git branch instead.

## Claude Code 2.1.299: plugin hooks fail closed

Claude Code 2.1.299 changed "actions a plugin hook can block to be refused,
not let through, when the hook cannot be handed them or cannot hand back its
answer; a tool that already ran has its result withheld". This note is an
analysis made on 2.1.296; nothing was changed for it.

**Why Unibrow's fail-open is not "let through".** When the app is absent,
paused or broken, the relay exits 0 with no output. For `PermissionRequest`
and `Elicitation` that is a documented, valid answer: "no decision, ask the
user". Claude Code then shows its own prompt or dialog. Unibrow never allows
anything by failing, so a fail-closed rule cannot turn a Unibrow failure into
an unwanted approval. The worst case is the opposite: something gets refused.

**What the change most likely covers.** The surrounding 2.1.299 entries are
about the plugin hooks worker (JavaScript mods, `next()`, `.catch`). Unibrow
uses plain command hooks from `hooks.json`, whose contract in the hooks
reference is unchanged. If the rule also reaches command hooks, these are the
paths that could change from "ask in the terminal" to "refused":

- **Stdin not read.** Without the app, the shim exits for every event but
  `SessionStart` without reading stdin. If Claude Code reports the failed
  write (EPIPE) as "could not hand the hook its input", a permission request
  or elicitation would be refused instead of prompted. The relay itself
  always reads stdin to the end. A one-line `cat >/dev/null` before
  `exit 0` in the shim would remove this risk.
- **Timeout.** `PermissionRequest` and `Elicitation` time out after an hour.
  A timed-out hook "cannot hand back its answer": the request might be denied
  or declined instead of falling back to the terminal.
- **Crash or kill.** A relay killed by a signal, or a shim that cannot exec
  the relay (exit 126/127), is a failed hook rather than "no output".
- **Async hooks** (`PostToolUse`, `PostToolUseFailure`, `PermissionDenied`,
  `Stop`, `StopFailure`, `Notification`, `UserPromptSubmit`, `SessionEnd`)
  cannot block, so they should be unaffected. "A tool that already ran has
  its result withheld" applies to blocking `PostToolUse` hooks; Unibrow's is
  async. Worth confirming, because a withheld result would break sessions.

**What to test before moving to 2.1.299 or later** (with `claude --debug`
and the hook log):

1. App quit, plugin enabled: a Bash permission prompt and an MCP elicitation
   still show the normal terminal prompt and dialog (not a denial), with and
   without the relay link present.
2. App paused: same.
3. A request answered in the terminal while its card waits (the hook is
   cancelled): the tool runs as answered; no extra denial.
4. Kill the waiting relay (`pkill -f unibrow-hook`): what Claude Code does
   now (prompt, or deny).
5. A short hook timeout (edit `timeout` in a local copy of `hooks.json`):
   prompt or deny/decline after the timeout.
6. Tools still return their results with the async `PostToolUse` hooks on,
   including large outputs.
7. Allow, Always, Deny, question answers and elicitation Submit/Decline/
   Cancel/Open from the notch still reach Claude Code.

If 1 or 2 now end in a refusal, drain stdin in the shim first. If 4 or 5 do,
the terminal fallback no longer covers a crashed or timed-out relay: say so
in the docs (a missing answer refuses), and keep the relay's own
"parent died" exit, which ends quietly before Claude Code gives up on it.

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
