#!/bin/sh
# Checks how plugin/bin/unibrow-bootstrap handles a release that is not
# published yet (the minutes between a version bump landing on main and the
# release workflow attaching the app). It must keep the current app, exit 0
# and leave no failure marker, so the next session tries again.
#
# Needs network access to github.com. Runs in a throwaway HOME, so it never
# touches your installed app or its state.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
home=$(mktemp -d "${TMPDIR:-/tmp}/unibrow-bootstrap-test.XXXXXX")
trap 'rm -rf "$home"' EXIT
support="$home/Library/Application Support/cc-unibrow"

# v0.0.0 is never released, so GitHub answers 404.
if ! HOME="$home" UNIBROW_BOOTSTRAP_NO_LAUNCH=1 sh "$root/plugin/bin/unibrow-bootstrap" 0.0.0 >"$home/log" 2>&1; then
    cat "$home/log"
    echo "FAIL: a missing release made the bootstrap fail"
    exit 1
fi
if [ -e "$support/bootstrap-failed" ]; then
    cat "$home/log"
    echo "FAIL: a missing release left a failure marker"
    exit 1
fi
if [ -e "$home/Applications/Unibrow.app" ]; then
    echo "FAIL: something was installed"
    exit 1
fi
grep -q "not published yet" "$home/log" || { cat "$home/log"; echo "FAIL: no 'not published yet' log line"; exit 1; }
echo "ok: a release that is not published yet is retried later, not marked failed"
