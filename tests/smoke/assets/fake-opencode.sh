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

# The harness validates CHEAP_WORKER_MODELS with `opencode models`; report the
# list the fixtures expect (the two valid entries only).
if [[ "${1:-}" == "models" ]]; then
    printf '%s\n' "opencode/muse-spark-1.3-contributor-free" "deepseek/deepseek-flash" "opencode/nemotron-3.5-lightning-free"
    exit 0
fi

cat >/dev/null

if [[ -n "${FAKE_OPENCODE_CWD_LOG:-}" ]]; then
    printf '%s\n' "$PWD" >>"$FAKE_OPENCODE_CWD_LOG"
fi

# Slow mode: record the pid, then wait for the release file (used by signal tests).
if [[ -n "${FAKE_OPENCODE_PID_LOG:-}" ]]; then
    printf '%s\n' "$$" >>"$FAKE_OPENCODE_PID_LOG"
fi
if [[ -n "${FAKE_OPENCODE_WAIT_FILE:-}" ]]; then
    while [[ ! -f "$FAKE_OPENCODE_WAIT_FILE" ]]; do
        sleep 0.1
    done
fi

if [[ -n "${FAKE_OPENCODE_ARGS_LOG:-}" ]]; then
    printf '%s\n' "$*" >>"$FAKE_OPENCODE_ARGS_LOG"
fi

# quota-always: every invocation reports a rate limit (for the exhausted case).
if [[ "${FAKE_OPENCODE_MODE:-none}" == "quota-always" ]]; then
    printf '{"type":"error","error":{"type":"provider.quota","message":"Rate limit exceeded. Please try again later.","status":429}}\n'
    exit 1
fi

# quota-once: the first invocation reports a rate limit, later ones succeed.
if [[ "${FAKE_OPENCODE_MODE:-none}" == "quota-once" ]]; then
    n=0
    if [[ -n "${FAKE_OPENCODE_COUNTER:-}" && -f "${FAKE_OPENCODE_COUNTER}" ]]; then
        n="$(cat "$FAKE_OPENCODE_COUNTER")"
    fi
    n=$((n + 1))
    [[ -n "${FAKE_OPENCODE_COUNTER:-}" ]] && printf '%s' "$n" >"$FAKE_OPENCODE_COUNTER"
    if [[ "$n" -eq 1 ]]; then
        printf '{"type":"error","error":{"type":"provider.quota","message":"Rate limit exceeded. Please try again later.","status":429}}\n'
        exit 1
    fi
    FMODE="result"
fi

printf '{"type":"text","sessionID":"ses_fake_offline_0001","part":{"text":"fake worker"}}\n'

mode="${FMODE:-${FAKE_OPENCODE_MODE:-none}}"
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
