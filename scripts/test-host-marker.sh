#!/bin/sh
# Checks the compatible-host marker (plugin/scripts/unibrow-host): the hook shim and
# the bootstrap leave Unibrow.app alone only while a valid marker names an
# installed app with the stated bundle ID; a stale or forged marker is ignored.
#
# No network. Runs in a throwaway HOME with fake app bundles, so it never
# touches your installed app, its socket or ~/Applications.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
bin="$root/plugin/scripts"
home=$(mktemp -d "${TMPDIR:-/tmp}/unibrow-host-test.XXXXXX")
trap 'rm -rf "$home"' EXIT
support="$home/Library/Application Support/cc-unibrow"
marker="$support/host.json"
# Never start an app, whatever happens.
export UNIBROW_BOOTSTRAP_NO_LAUNCH=1

fail() { echo "FAIL: $*"; exit 1; }

# fake_app <path> <bundle id>
fake_app() {
    mkdir -p "$1/Contents"
    plutil -create xml1 "$1/Contents/Info.plist"
    plutil -insert CFBundleIdentifier -string "$2" "$1/Contents/Info.plist"
    plutil -insert CFBundleShortVersionString -string "0.0.1" "$1/Contents/Info.plist"
}

# write_marker <app path> <bundle id>
write_marker() {
    mkdir -p "$support"
    chmod 700 "$support"
    printf '{"version":1,"appPath":"%s","bundleID":"%s"}\n' "$1" "$2" >"$marker"
    chmod 600 "$marker"
}

honoured() { HOME="$home" sh "$bin/unibrow-host" >/dev/null 2>&1; }

host="$home/Hosts/Example Host.app"
fake_app "$host" "com.example.host"

# 1. No marker.
honoured && fail "honoured a missing marker"

# 2. A valid marker is honoured and names the app.
write_marker "$host" "com.example.host"
[ "$(HOME="$home" sh "$bin/unibrow-host")" = "$host" ] || fail "valid marker not honoured"
echo "ok: a valid marker is honoured"

# 3. Bundle ID mismatch.
write_marker "$host" "com.example.other"
honoured && fail "honoured a marker whose bundle ID does not match the app"
echo "ok: a bundle ID mismatch is ignored"

# 4. The marker may not name Unibrow itself (that would only stop its updates).
unibrow="$home/Applications/Unibrow.app"
fake_app "$unibrow" "dev.andriitk.unibrow"
write_marker "$unibrow" "dev.andriitk.unibrow"
honoured && fail "honoured a marker that names Unibrow"
rm -rf "$home/Applications"

# 5. Relative path, not an .app, malformed JSON, missing field.
write_marker "Hosts/Example Host.app" "com.example.host"
honoured && fail "honoured a relative app path"
write_marker "$home/Hosts" "com.example.host"
honoured && fail "honoured a path that is not an .app"
printf '{"appPath":' >"$marker"
honoured && fail "honoured malformed JSON"
printf '{"appPath":"%s"}\n' "$host" >"$marker"
honoured && fail "honoured a marker without bundleID"
echo "ok: malformed markers are ignored"

# 6. Writable by others, or a symlink.
write_marker "$host" "com.example.host"
chmod 620 "$marker"
honoured && fail "honoured a group-writable marker"
chmod 600 "$marker"
chmod 777 "$support"
honoured && fail "honoured a marker in a world-writable directory"
chmod 700 "$support"
mv "$marker" "$home/elsewhere.json"
ln -s "$home/elsewhere.json" "$marker"
honoured && fail "honoured a symlinked marker"
rm -f "$marker" "$home/elsewhere.json"
echo "ok: markers others could write, or links, are ignored"

# 7. Shim, SessionStart, valid marker: silent, no bootstrap started.
write_marker "$host" "com.example.host"
out=$(echo '{}' | HOME="$home" sh "$bin/unibrow-hook" SessionStart)
[ -z "$out" ] || fail "shim printed with a host app present: $out"
[ ! -e "$home/Library/Logs/cc-unibrow-bootstrap.log" ] || fail "shim started the bootstrap with a host app present"
# Also with a relay link into the host app (no update attempt).
mkdir -p "$support/bin" "$host/Contents/MacOS"
printf '#!/bin/sh\nexit 0\n' >"$host/Contents/MacOS/unibrow-hook"
chmod +x "$host/Contents/MacOS/unibrow-hook"
ln -s "$host/Contents/MacOS/unibrow-hook" "$support/bin/unibrow-hook"
out=$(echo '{}' | HOME="$home" sh "$bin/unibrow-hook" SessionStart)
[ -z "$out" ] || fail "shim tried to update the host app: $out"
rm -f "$support/bin/unibrow-hook"
echo "ok: the shim leaves Unibrow alone while the host app is installed"

# 8. Bootstrap with a valid marker: exits 0 before any download or change.
fake_app "$home/Old/Unibrow.app" "dev.andriitk.unibrow"
HOME="$home" sh "$bin/unibrow-bootstrap" 9.9.9 --update "$home/Old/Unibrow.app" >"$home/log" 2>&1 \
    || { cat "$home/log"; fail "bootstrap failed with a host app present"; }
grep -q "compatible host app" "$home/log" || { cat "$home/log"; fail "bootstrap did not defer to the host app"; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$home/Old/Unibrow.app/Contents/Info.plist")" = "0.0.1" ] \
    || fail "bootstrap changed Unibrow.app"
HOME="$home" sh "$bin/unibrow-bootstrap" 9.9.9 >"$home/log" 2>&1 || fail "bootstrap install failed with a host app present"
grep -q "compatible host app" "$home/log" || fail "bootstrap install did not defer to the host app"
[ ! -e "$home/Applications/Unibrow.app" ] || fail "bootstrap installed Unibrow with a host app present"
[ ! -e "$support/bootstrap-failed" ] || fail "deferring left a failure marker"
echo "ok: the bootstrap neither installs nor updates while the host app is installed"

# 9. Stale marker (host app removed): the free app's path comes back. With
# auto-install off the shim says how to install instead of starting a download.
rm -rf "$home/Hosts"
honoured && fail "honoured a marker whose app is gone"
out=$(echo '{}' | HOME="$home" UNIBROW_NO_AUTO_INSTALL=1 sh "$bin/unibrow-hook" SessionStart)
case "$out" in
    *"Unibrow app is not"*) ;;
    *) fail "a stale marker still blocked the shim: $out" ;;
esac
echo "ok: a stale marker is ignored and Unibrow comes back"
