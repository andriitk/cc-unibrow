#!/bin/sh
# Checks that the plugin's hook shim, without the app, reads its whole input
# and exits 0 with no output. Claude Code 2.1.299+ refuses an action when it
# cannot hand a plugin hook its input, so an unread stdin must never happen.
#
# Runs in a throwaway HOME, so it never touches your installed app.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
home=$(mktemp -d "${TMPDIR:-/tmp}/unibrow-shim-test.XXXXXX")
trap 'rm -rf "$home"' EXIT

for event in PermissionRequest Elicitation PostToolUse StopFailure Notification; do
    # 4 MB is far more than a pipe buffer: a shim that exits without reading
    # makes the writer fail with SIGPIPE.
    status=$( { { head -c 4194304 /dev/zero; echo "$?" >"$home/writer"; } \
        | HOME="$home" sh "$root/plugin/bin/unibrow-hook" "$event" >"$home/out"; echo "$?"; } )
    writer=$(cat "$home/writer" 2>/dev/null || echo "killed by SIGPIPE")
    rm -f "$home/writer"
    if [ "$status" != 0 ] || [ "$writer" != 0 ]; then
        echo "FAIL: $event without the app: shim exit $status, writer exit $writer (unread stdin?)"
        exit 1
    fi
    if [ -s "$home/out" ]; then
        echo "FAIL: $event without the app printed output:"
        cat "$home/out"
        exit 1
    fi
done
echo "ok: without the app the shim reads its whole input and prints nothing"
