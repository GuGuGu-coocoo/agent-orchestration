#!/usr/bin/env bash
# fake-opencode.sh - offline stand-in for the opencode CLI used by the smoke tests.
#
# It records its cwd, consumes the prompt on stdin, prints one JSONL event with a
# sessionID, and then behaves according to FAKE_OPENCODE_MODE:
#
#   none        writes no report (default)
#   result      writes a valid RESULT.md for FAKE_TASK_ID
#   wrong-id    writes a RESULT.md for task WRONG
#   invalid     writes a RESULT.md without a Status section
#   escalation  writes a valid ESCALATION.md
#   both        writes a valid RESULT.md and ESCALATION.md
#
# FAKE_OPENCODE_EXIT sets the exit code (default 0). FAKE_OPENCODE_CWD_LOG is
# appended with the cwd of each `run` invocation.

set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
    printf 'opencode v0.0.0-fake\n'
    exit 0
fi

cat >/dev/null

if [[ -n "${FAKE_OPENCODE_CWD_LOG:-}" ]]; then
    printf '%s\n' "$PWD" >>"$FAKE_OPENCODE_CWD_LOG"
fi

printf '{"type":"text","sessionID":"ses_fake_offline_0001","part":{"text":"fake worker"}}\n'

mode="${FAKE_OPENCODE_MODE:-none}"
task_id="${FAKE_TASK_ID:-UNKNOWN}"
current=".agent/current"

case "$mode" in
    result|both)
        {
            printf '# Result\n\n## Task ID\n%s\n\n## Status\nDONE\n\n## Summary\nfake result\n' "$task_id"
        } >"$current/RESULT.md"
        ;;
    wrong-id)
        printf '# Result\n\n## Task ID\nWRONG\n\n## Status\nDONE\n\n## Summary\nfake result\n' >"$current/RESULT.md"
        ;;
    invalid)
        printf '# Result\n\n## Task ID\n%s\n\n## Summary\nno status section\n' "$task_id" >"$current/RESULT.md"
        ;;
esac

case "$mode" in
    escalation|both)
        {
            printf '# Escalation\n\n## Task ID\n%s\n\n## Current Blocker\nfake blocker\n' "$task_id"
        } >"$current/ESCALATION.md"
        ;;
esac

exit "${FAKE_OPENCODE_EXIT:-0}"
