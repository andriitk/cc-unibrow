#!/bin/sh
# Opt-in hook timing logger, for measuring when Claude Code fires each event
# around a permission prompt. Development only; nothing in the plugin uses it.
#
#   scripts/hook-timing.sh settings > /tmp/timing.json
#   claude --settings /tmp/timing.json       # one session, nothing installed
#   tail -f "${TMPDIR:-/tmp}/unibrow-hook-timing.log"
#
# As a hook (`scripts/hook-timing.sh log <Event>`, hook JSON on stdin) it
# appends one line per event: local time with milliseconds, event, session
# tag, agent_id, tool_name, tool_use_id and a short hash of tool_input. For
# PostToolBatch, one line per call. No command text, file content, tool
# output or answers are written. It prints nothing and exits 0, so it never
# decides anything.
set -u
log="${UNIBROW_TIMING_LOG:-${TMPDIR:-/tmp}/unibrow-hook-timing.log}"
here=$(cd "$(dirname "$0")" && pwd)

case "${1:-}" in
settings)
    self="$here/$(basename "$0")"
    printf '{"hooks":{'
    sep=""
    for event in PreToolUse PermissionRequest PermissionDenied PostToolUse PostToolUseFailure \
        PostToolBatch Notification UserPromptSubmit Stop StopFailure SubagentStart SubagentStop; do
        printf '%s"%s":[{"hooks":[{"type":"command","command":"\\"%s\\" log %s","timeout":5}]}]' \
            "$sep" "$event" "$self" "$event"
        sep=","
    done
    printf '}}\n'
    ;;
log)
    /usr/bin/perl -MJSON::PP -MDigest::SHA=sha1_hex -MTime::HiRes=time -MPOSIX=strftime -e '
        my ($event, $log) = @ARGV;
        local $/; my $raw = <STDIN>;
        my $in = eval { JSON::PP->new->decode($raw) } || {};
        my $json = JSON::PP->new->canonical;
        my $now = time;
        my $stamp = strftime("%H:%M:%S", localtime $now) . sprintf(".%03d", ($now - int $now) * 1000);
        my $hash = sub { defined $_[0] ? substr(sha1_hex($json->encode($_[0])), 0, 8) : "-" };
        my $base = join " ", $stamp, $event, substr($in->{session_id} // "-", 0, 4),
            "agent=" . ($in->{agent_id} // "-");
        my @lines;
        if (ref $in->{tool_calls} eq "ARRAY") {
            push @lines, "$base call=" . ($_->{tool_name} // "-") . " id=" . ($_->{tool_use_id} // "-")
                . " input=" . $hash->($_->{tool_input}) for @{ $in->{tool_calls} };
            @lines = ("$base calls=0") unless @lines;
        } else {
            push @lines, "$base tool=" . ($in->{tool_name} // "-") . " id=" . ($in->{tool_use_id} // "-")
                . " input=" . $hash->($in->{tool_input}) . " mode=" . ($in->{permission_mode} // "-")
                . (defined $in->{notification_type} ? " type=$in->{notification_type}" : "");
        }
        open my $out, ">>", $log or exit 0;
        print $out "$_\n" for @lines;
    ' "${2:-unknown}" "$log" 2>/dev/null
    exit 0
    ;;
*)
    echo "usage: $0 settings | log <HookEvent>" >&2
    exit 2
    ;;
esac
