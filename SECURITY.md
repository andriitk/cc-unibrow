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
- **What you approve is what you saw.** Allow stays off until the whole input
  is on screen: a long, multi-line or non-ASCII command, or input with fields
  the card does not show (such as `dangerouslyDisableSandbox`, which is called
  out), has to be opened first; control, bidi and invisible characters are
  shown escaped; input too long to show in full can only be answered in the
  terminal.
- **Least access.** The app never reads project files. Accessibility access is
  optional and used only to read window titles and raise one window.

Relevant reports include: a way for another user or process to approve a
request, a request that silently disappears without a decision, or the app
reading or sending data it should not.
