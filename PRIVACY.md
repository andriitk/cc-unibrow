# Privacy policy

_Last updated: 2026-11-03_

Unibrow (the macOS app and the `cc-unibrow` Claude Code plugin) is built to keep
everything on your Mac.

## What it collects

Nothing is collected by the author or any third party. There is no account,
no analytics, no telemetry and no crash reporting.

## What it processes, and where

- **Permission requests, questions and plans** that Claude Code sends to its
  hooks: the tool name and input (for example a command or a file diff), the
  session ID, the working directory, the git branch, and the last assistant
  message when a turn finishes. They go from the hook to the Unibrow app on the
  same Mac over a Unix socket that only your user can open.
- **MCP server requests** (elicitations): the server name, its message, the
  form it asks you to fill in or the link it asks you to open, and the values
  you submit, which go back to Claude Code only. **Alerts**: the API error
  type and message when a turn fails, and the text of an "agent needs input"
  notification. None of it is logged or written to disk.
- **Impact lines** for risky shell commands: the hook looks up, on your Mac
  and read-only, the git remote (host and repository path only, never user
  names or tokens), branches, how many commits or changed files are involved,
  and how many items a folder to be removed holds. Only the resulting short
  lines go to the app with the request. **Subagents**: their IDs and types,
  to show how many are running.
- **Process IDs and window titles**, used only to find and raise the window a
  session runs in. Window titles are read only if you turn on *Exact Window
  Focus* and grant Accessibility access.

## Retention

Requests live in the app’s memory until they are answered, or for at most one
hour. Running-subagent entries are dropped when the agent or session ends, or
after six hours without news from them. “Finished” notices are kept in memory for at most 30 minutes. Nothing
from your sessions is written to disk. Quitting the app clears everything.

The app stores only its own settings (macOS user defaults) and, for the
plugin-only install, a log of the one-time download in
`~/Library/Logs/cc-unibrow-bootstrap.log`.

## Network

The app makes no network requests. The plugin makes one kind of request: when
the app is missing, or older than the plugin, it downloads the app from this
project’s GitHub Releases (`github.com/andriitk/cc-unibrow/releases`). GitHub may log
that download under [GitHub’s privacy statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement).
No data from your sessions is sent with it.

## Contact

[GitHub Issues](https://github.com/andriitk/cc-unibrow/issues), or a
[private security advisory](https://github.com/andriitk/cc-unibrow/security/advisories/new)
for anything sensitive.
