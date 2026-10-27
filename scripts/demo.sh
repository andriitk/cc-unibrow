#!/bin/sh
# Sends a few fake permission requests to a running Unibrow, as if three
# Claude Code sessions were waiting. Handy for UI work and screenshots.
#
#   scripts/demo.sh            # needs Unibrow running
#
# Each request is a background relay process waiting for your click; the
# decision it would hand to Claude Code is printed when you answer.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
relay=$(swift build --package-path "$root" --show-bin-path)/unibrow-hook
[ -x "$relay" ] || swift build --package-path "$root" --product unibrow-hook

request() { # session cwd tool input-json
    printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PermissionRequest","tool_name":"%s","tool_input":%s,"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"%s"}],"behavior":"allow","destination":"localSettings"}]}' \
        "$1" "$2" "$3" "$4" "$3" \
        | "$relay" PermissionRequest | sed "s|^|[$3 in $(basename "$2")] → |" &
    sleep 0.4
}

request demo-1 "$HOME/code/shop-api" Bash '{"command":"npm run migrate -- --env staging","description":"Run database migrations on staging"}'
request demo-2 "$HOME/code/landing" Edit '{"file_path":"'"$HOME"'/code/landing/src/hero.tsx","old_string":"<h1>Hello</h1>","new_string":"<h1 className=\"title\">Ship faster</h1>"}'
request demo-3 "$HOME/code/infra" Bash '{"command":"terraform apply -auto-approve","description":"Apply infrastructure changes"}'
request demo-3 "$HOME/code/infra" WebFetch '{"url":"https://registry.terraform.io/providers/hashicorp/aws/latest","prompt":"Find the latest provider version"}'
request demo-2 "$HOME/code/landing" mcp__github__create_pull_request '{"repo":"me/landing","title":"New hero copy","base":"main"}'
# Multi-line: Allow stays off until "Show full command" was opened.
request demo-1 "$HOME/code/shop-api" Bash '{"command":"npm ci\nnpm run build\nrm -rf ./dist-old","description":"Clean rebuild"}'

# An extra field: the detail becomes the full input, the sandbox flag is called out.
request demo-3 "$HOME/code/infra" Bash '{"command":"make deploy","description":"Deploy","dangerouslyDisableSandbox":true}'

echo "Seven requests sent. Answer them in the notch (Ctrl-C to abandon)."
wait
