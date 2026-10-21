#!/bin/sh
# Unibrow installer: builds the app from source, installs it and adds the
# Claude Code plugin. Safe to run again to update.
#
#   curl -fsSL https://raw.githubusercontent.com/andriitk/cc-unibrow/main/install.sh | sh
#
# Options (after `sh -s --` when piped):
#   --no-plugin   install only the app
#   --uninstall   remove the app, its data and the plugin
#   --help
#
# Environment:
#   CC_UNIBROW_REF   git branch or tag to build (default: main)
#   CC_UNIBROW_SRC   where the source is kept (default: ~/.local/share/cc-unibrow/src)
#   APP_DIR          where Unibrow.app goes (default: ~/Applications)
set -eu

REPO="andriitk/cc-unibrow"
MARKETPLACE="cc-unibrow"
PLUGIN="cc-unibrow@cc-unibrow"
REF="${CC_UNIBROW_REF:-main}"
SRC="${CC_UNIBROW_SRC:-$HOME/.local/share/cc-unibrow/src}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\033[1;33m›\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,17p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || true
}

with_plugin=1
action=install
for arg in "$@"; do
    case "$arg" in
        --no-plugin) with_plugin=0 ;;
        --uninstall) action=uninstall ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown option: $arg (see --help)" ;;
    esac
done

# ── Checks ───────────────────────────────────────────────────────────────────

[ "$(uname -s)" = "Darwin" ] || fail "Unibrow is a macOS app."

major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || fail "Unibrow needs macOS 14 Sonoma or later (this Mac: $(sw_vers -productVersion))."

have_claude=0
command -v claude >/dev/null 2>&1 && have_claude=1

# ── Uninstall ────────────────────────────────────────────────────────────────

if [ "$action" = uninstall ]; then
    bold "Uninstalling Unibrow"
    if [ "$have_claude" = 1 ]; then
        claude plugin uninstall "$PLUGIN" >/dev/null 2>&1 && ok "Removed the Claude Code plugin" || true
    fi
    if [ -f "$SRC/Makefile" ]; then
        make -C "$SRC" --no-print-directory uninstall
    else
        osascript -e 'quit app "Unibrow"' >/dev/null 2>&1 || true
        rm -rf "${APP_DIR:-$HOME/Applications}/Unibrow.app" "$HOME/Library/Application Support/cc-unibrow"
    fi
    case "$SRC" in
        "$HOME"/.local/share/cc-unibrow/src) rm -rf "$SRC" ;;
    esac
    ok "Unibrow removed"
    exit 0
fi

# ── Build tools ──────────────────────────────────────────────────────────────

if ! xcrun --find swift >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    warn "Swift and git come with Apple's Command Line Tools, which are not installed."
    warn "Run this, finish the installer that opens, then run this script again:"
    printf '\n    xcode-select --install\n\n' >&2
    exit 1
fi

# ── Source ───────────────────────────────────────────────────────────────────

bold "Installing Unibrow ($REF)"

# Use a local checkout only when this script was run as a file from inside
# one. Piped through `sh`, $0 is "sh" and dirname is the user's current
# directory, which must never be mistaken for our source (it could be any
# other project with a Makefile).
script_dir=""
if [ -f "$0" ]; then
    script_dir=$(cd "$(dirname "$0")" && pwd)
fi
if [ -n "$script_dir" ] && [ -d "$script_dir/Sources/UnibrowHook" ] && [ -f "$script_dir/Makefile" ]; then
    # Run from a checkout: build that checkout as it is.
    SRC="$script_dir"
    step "Using the source in $SRC"
elif [ -d "$SRC/.git" ]; then
    step "Updating the source in $SRC"
    git -C "$SRC" fetch --quiet --depth 1 origin "$REF"
    git -C "$SRC" checkout --quiet --force FETCH_HEAD
else
    step "Downloading the source to $SRC"
    mkdir -p "$(dirname "$SRC")"
    git clone --quiet --depth 1 --branch "$REF" "https://github.com/$REPO.git" "$SRC"
fi

# ── App ──────────────────────────────────────────────────────────────────────

step "Building and installing the app (about a minute the first time)"
make -C "$SRC" --no-print-directory install
ok "Unibrow.app installed and running — look for the eyebrow in the menu bar"

# ── Claude Code plugin ───────────────────────────────────────────────────────

if [ "$with_plugin" = 0 ]; then
    exit 0
fi

if [ "$have_claude" = 0 ]; then
    warn "Claude Code (the \`claude\` command) was not found, so the plugin was not installed."
    warn "Install Claude Code, then run:"
    printf '\n    claude plugin marketplace add %s\n    claude plugin install %s\n\n' "$REPO" "$PLUGIN" >&2
    exit 0
fi

step "Installing the Claude Code plugin"
# HTTPS works without a GitHub SSH key; the owner/repo shorthand tries SSH first.
export CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1
# One step on Claude Code 2.1.292+; otherwise add the marketplace, then install.
if claude plugin install "$MARKETPLACE" --marketplace "$REPO" >/dev/null 2>&1; then
    installed=1
else
    claude plugin marketplace add "$REPO" >/dev/null 2>&1 \
        || claude plugin marketplace update "$MARKETPLACE" >/dev/null 2>&1 \
        || true
    installed=0
    claude plugin install "$PLUGIN" >/dev/null 2>&1 && installed=1
fi
if [ "$installed" = 1 ]; then
    ok "Plugin $PLUGIN installed"
else
    warn "Could not install the plugin automatically. Run:"
    printf '\n    claude plugin marketplace add %s\n    claude plugin install %s\n\n' "$REPO" "$PLUGIN" >&2
fi

printf '\n'
bold "Done. Restart running Claude Code sessions so they pick up the plugin."
printf 'Try it without Claude: make -C "%s" demo\n' "$SRC"
