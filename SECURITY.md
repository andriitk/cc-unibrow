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
- **Least access.** The app never reads project files. Accessibility access is
  optional and used only to read window titles and raise one window.

Relevant reports include: a way for another user or process to approve a
request, a request that silently disappears without a decision, or the app
reading or sending data it should not.
