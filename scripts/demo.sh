#!/bin/sh
# Sends a few fake permission requests, MCP elicitations and alerts to a
# running Unibrow, as if several Claude Code sessions were waiting. Handy for
# UI work and screenshots.
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

# MCP elicitations: a form (every field kind) and a sign-in link whose host
# hides behind a user name. The answer JSON is printed when you respond.
elicit() { # session cwd json-fields
    printf '{"session_id":"%s","cwd":"%s","hook_event_name":"Elicitation",%s}' "$1" "$2" "$3" \
        | "$relay" Elicitation | sed "s|^|[Elicitation in $(basename "$2")] → |" &
    sleep 0.4
}

elicit demo-4 "$HOME/code/tracker" '"mcp_server_name":"issue-tracker","message":"Where should the bug report go?","mode":"form","requested_schema":{"type":"object","properties":{"project":{"type":"string","title":"Project","oneOf":[{"const":"WEB","title":"Website"},{"const":"API","title":"Public API"}]},"title":{"type":"string","title":"Title","minLength":5,"maxLength":80},"reporter":{"type":"string","title":"Your email","format":"email"},"priority":{"type":"integer","title":"Priority","minimum":1,"maximum":5,"default":3},"due":{"type":"string","title":"Due date","format":"date"},"labels":{"type":"array","title":"Labels","items":{"type":"string","enum":["bug","ui","perf"]},"maxItems":2},"notify":{"type":"boolean","title":"Notify the team","default":true},"api_token":{"type":"string","title":"API token","description":"Never logged; shown as dots"}},"required":["project","title"]}'
elicit demo-5 "$HOME/code/payments" '"mcp_server_name":"billing","message":"Sign in to your billing account to continue","mode":"url","url":"https://accounts.example.com@login.example.net/oauth/authorize?client_id=demo&state=xyz","elicitation_id":"demo-url"'

# Alerts: a turn that stopped on an API error, and a background agent that
# waits for input. Nothing waits for an answer.
printf '{"session_id":"demo-6","cwd":"%s","hook_event_name":"StopFailure","error":"rate_limit","error_details":"429 Too Many Requests","last_assistant_message":"API Error: Rate limit reached"}' \
    "$HOME/code/analytics" | "$relay" StopFailure
printf '{"session_id":"demo-7","cwd":"%s","hook_event_name":"Notification","notification_type":"agent_needs_input","title":"Claude Code","message":"The migrator agent is waiting for your input"}' \
    "$HOME/code/backend" | "$relay" Notification

echo "Seven requests, two MCP elicitations and two alerts sent. Answer them in the notch (Ctrl-C to abandon)."
wait
