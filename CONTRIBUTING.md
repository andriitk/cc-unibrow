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

## Pull requests

`main` is what every user runs: the plugin marketplace and auto-update serve
it directly. So nothing lands there without a pull request and green CI,
maintainers included.

1. Fork the repository (maintainers: create a branch) and make your change.
2. Open a pull request against `main`. CI for a first-time contributor
   starts after a maintainer approves the run.
3. A maintainer reviews it and squash-merges it. Leave `VERSION`,
   `plugin.json` and release tags alone; releases are cut separately.

## Releasing (maintainers)

1. Open a pull request that bumps `VERSION` and the `version` in
   `plugin/.claude-plugin/plugin.json` to the same number, and turns the
   `CHANGELOG.md` entries into a `## [x.y.z] - YYYY-MM-DD` section. CI checks
   that the three agree.
2. Merge it. The release workflow tests, builds the universal app, tags the
   merge commit `vx.y.z` and publishes the release with that changelog
   section as its notes. Do not push tags by hand.
3. Check that the release has `Unibrow.zip` and `Unibrow.zip.sha256`. Users
   get the update through plugin auto-update; see the README.

## Reporting bugs

Include your macOS and Claude Code versions (`claude --version`), what you did,
what you expected and what happened. Logs help:

```sh
log stream --predicate 'subsystem == "dev.andriitk.unibrow"'
```
