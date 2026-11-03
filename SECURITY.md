# Security

Unibrow sits in the path of Claude Code's permission decisions, so security
reports are taken seriously.

## Reporting a vulnerability

Please do **not** open a public issue. Use GitHub's
[private vulnerability reporting](https://github.com/andriitk/cc-unibrow/security/advisories/new)
instead. You will get a reply within a few days.

## Design principles

- **Fail to the terminal.** Any error makes the hook print nothing, so Claude
  Code shows its normal prompt. Unibrow never approves anything on its own.
- **Local only.** No network code. The socket is in a `0700` directory with
  mode `0600`, and the app checks that connections come from the same user.
- **Nothing hidden.** When the card cannot show the whole input on one line (a
  long, multi-line or non-ASCII command, an edit or plan, or fields the card
  does not show, with `dangerouslyDisableSandbox` called out), it says so and
  offers "Show full …"; control, bidi and invisible characters are shown
  escaped. Allow is not blocked on opening it: that is the user's call.
- **MCP servers are untrusted.** In an elicitation card the server name,
  message, field titles, option titles and URL are escaped the same way and
  capped; values sent back stay exact. A link is parsed once and the host shown
  is the host opened; it opens only on a click, only for unambiguous
  `http`/`https` URLs (no user name before `@`, no encoded host, no `\` or
  hidden characters), with international hosts shown as punycode and plain
  HTTP called out. Password- and
  token-like fields are secure fields, and no value is logged.
- **Least access.** The app never reads project files; the hook, which runs in
  your terminal, reads the git branch and, for *Impact* lines, does the
  read-only lookups below. Accessibility access is optional and used only to
  read window titles and raise one window.

Relevant reports include: a way for another user or process to approve a
request, a request that silently disappears without a decision, or the app
reading or sending data it should not.

## Other hooks, plugins and mods

Unibrow is not the only thing that can answer a permission request, and it
cannot see or stop the others. From the Claude Code documentation:

- **Other hooks.** "When an event fires, its matching hooks run in parallel",
  and plugin hooks "merge with your user and project hooks"
  ([hooks reference](https://code.claude.com/docs/en/hooks)). Another
  `PermissionRequest` hook can allow or deny the same request. The reference
  gives a precedence order for conflicting `PreToolUse` decisions but does
  not say how differing `PermissionRequest` decisions are resolved, so do
  not assume Unibrow's answer is the one that counts when another hook also
  answers.
- **Mods** (plugins whose hooks are JavaScript functions inside Claude Code;
  on by default, Claude Code 2.1.287 or later in the terminal). A mod's `tool.call` hook can
  answer a tool call itself, and then "no permission prompt appears and the
  tool doesn't run"; its `tool.check` hook decides allow, ask or deny "after
  the `PreToolUse` hooks run, and before the permission prompt, auto mode's
  classifier, or a `PermissionRequest` hook"
  ([React to events with a mod](https://code.claude.com/docs/en/plugins/mods/events)).
  So a mod can settle a request before Unibrow's hook runs: no card appears.
- **Trust.** "A mod is code that runs with your permissions": it can read and
  write your files, read your secrets, see every prompt and tool call, and
  "approve a tool call before you're asked". "Mods aren't sandboxed", and a
  process a mod starts runs outside Claude Code's sandbox
  ([Mods overview](https://code.claude.com/docs/en/plugins/mods/overview)).
  Install mods and plugins only from authors and marketplaces you trust;
  `claude plugin validate <dir>` lists what a mod handles before you install
  it.

What this means for the notch: a card may not appear, or may disappear (its
hook ended) without you answering it, because something else decided. The
documentation does say a mod "can restyle much of Claude Code's interface, but
not the permission prompt", so the terminal prompt itself stays Claude Code's.

## Impact lines

The *Impact* line on a risky Bash request is computed by the hook, in the
session's folder, with read-only lookups only: `git` with
`GIT_OPTIONAL_LOCKS=0` and no fsmonitor (`remote get-url`, `rev-parse`,
`symbolic-ref`, `rev-list --count`, `status --porcelain`), `lstat`, and a
directory walk that never follows symlinks and stops at 10,000 items. No
fetch, no network. Everything stops at a 0.3 s budget, and a failed or slow
lookup only leaves the line out. It is information: it never enables, blocks
or delays Allow, and the review rules (“Show full …”) are unchanged. Remote
URLs are reduced to host and repository path; user names and tokens in them
are never shown. Lines are escaped like any other card text.
