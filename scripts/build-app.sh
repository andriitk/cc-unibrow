#!/bin/sh
# Builds Unibrow.app from the SwiftPM products. No Xcode project needed;
# the Command Line Tools are enough.
#
#   scripts/build-app.sh [output-dir]     (default: ./build)
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-"$root/build"}
version=$(cat "$root/VERSION")
build=$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 1)

echo "› Building release binaries"
swift build --package-path "$root" -c release --product Unibrow
swift build --package-path "$root" -c release --product unibrow-hook
bin=$(swift build --package-path "$root" -c release --show-bin-path)

# Assemble and sign outside the source tree: folders synced by iCloud Drive
# (e.g. ~/Documents) get extended attributes that make codesign reject the
# bundle. The signed result is then copied out without any attributes.
staging=$(mktemp -d "${TMPDIR:-/tmp}/unibrow-build.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/Unibrow.app"
echo "› Assembling Unibrow.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Unibrow" "$bin/unibrow-hook" "$app/Contents/MacOS/"
sed -e "s/__VERSION__/$version/" -e "s/__BUILD__/$build/" "$root/Resources/Info.plist" > "$app/Contents/Info.plist"
[ -f "$root/Resources/AppIcon.icns" ] && cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/"

# Ad-hoc signature: enough to run locally. Release builds should use a
# Developer ID certificate and notarization (see README).
codesign --force --sign "${CODESIGN_IDENTITY:--}" --options runtime "$app/Contents/MacOS/unibrow-hook"
codesign --force --sign "${CODESIGN_IDENTITY:--}" --options runtime "$app"

codesign --verify --deep --strict "$app"

mkdir -p "$out"
rm -rf "$out/Unibrow.app"
ditto --norsrc --noextattr "$app" "$out/Unibrow.app"
echo "✓ $out/Unibrow.app ($version, build $build)"
