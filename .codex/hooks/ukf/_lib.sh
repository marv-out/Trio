#!/usr/bin/env bash
# Local, fork-only hook helpers for the UKF / Adaptive Smoothing guards.
#
# NOT part of the distributable trio-fork-compliance plugin — UKF/Adaptive Smoothing is a
# fork divergence that isn't in nightscout dev, so these live here (git-excluded) and never
# reach the repo or an upstream PR. PreToolUse only: exit 2 blocks and stderr goes to Claude;
# exit 0 with hookSpecificOutput.additionalContext surfaces a non-blocking reminder.
set -euo pipefail

# Claude Code pipes the tool payload as JSON on stdin. Read it ONCE here (each $(subshell)
# helper would otherwise re-consume an already-empty stdin).
_PAYLOAD="$(cat)"
hook_file()     { printf '%s' "$_PAYLOAD" | jq -r '.tool_input.file_path // empty'; }
# Text being written: Write=file_text, Edit=edits[].new_string (older builds: new_string).
hook_new_text() { printf '%s' "$_PAYLOAD" | jq -r '[ .tool_input.file_text // empty,
                                                     .tool_input.new_string // empty,
                                                     ((.tool_input.edits // [])[].new_string) ]
                                                   | map(select(. != "")) | join("\n")'; }
block()  { echo "🚫 [trio-ukf] $1" >&2; exit 2; }
remind() { jq -cn --arg m "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$m}}'; exit 0; }
ok()     { exit 0; }
