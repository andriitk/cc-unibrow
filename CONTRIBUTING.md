# Contributing

Thanks for helping make Unibrow better. Bug reports, ideas and pull requests
are all welcome.

## Before you start

- For anything bigger than a small fix, open an issue first so we can agree on
  the approach.
- Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); the safety guarantees
  there are non-negotiable. In particular, every failure must fall back to
  Claude Code's normal terminal prompt.

## Setup

You need macOS 14+ and Swift 6 (Xcode 16+ or the Command Line Tools).

```sh
git clone https://github.com/andriitk/cc-unibrow.git
cd cc-unibrow
swift test
make install      # build and run your copy
make demo         # send fake requests to it
```

To run a development copy next to an installed one, give it its own socket:

```sh
UNIBROW_SOCKET=/tmp/unibrow-dev.sock make run
```

## Guidelines

- Put logic in `UnibrowCore` and cover it with tests (Swift Testing). Keep the
  app layer thin.
- Swift 6 strict concurrency, no warnings. No new dependencies without a strong
  reason.
- No network access, analytics or telemetry.
- Match the existing style: small types, clear names, comments that explain
  *why*.
- One topic per pull request, with a short description of what and why. Add a
  line to `CHANGELOG.md` for user-visible changes.

## Reporting bugs

Include your macOS and Claude Code versions (`claude --version`), what you did,
what you expected and what happened. Logs help:

```sh
log stream --predicate 'subsystem == "dev.andriitk.unibrow"'
```
