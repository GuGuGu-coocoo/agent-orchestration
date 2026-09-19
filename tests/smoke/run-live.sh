#!/usr/bin/env bash
# run-live.sh - run the live end-to-end smoke tests in throwaway repos.
#
# Every test creates its own temp git repo; nothing touches a real project.
# Model calls are real and use OpenCode's configured default model, exactly like
# the worker does in production. To test a specific model, change OpenCode's own
# configuration first (opencode.json "model").
#
# Usage:
#   tests/smoke/run-live.sh [a|b|c|d]     # run one test
#   tests/smoke/run-live.sh              # run all live tests
#   SMOKE_KEEP_REPOS=1 tests/smoke/run-live.sh   # keep temp repos for inspection

set -euo pipefail

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

case "${1:-all}" in
    a) tests=("$SMOKE_DIR/run-a-single-task.sh") ;;
    b) tests=("$SMOKE_DIR/run-b-investigate.sh") ;;
    c) tests=("$SMOKE_DIR/run-c-escalation.sh") ;;
    d) tests=("$SMOKE_DIR/run-d-phase-runner.sh") ;;
    all) tests=(
            "$SMOKE_DIR/run-a-single-task.sh"
            "$SMOKE_DIR/run-b-investigate.sh"
            "$SMOKE_DIR/run-c-escalation.sh"
            "$SMOKE_DIR/run-d-phase-runner.sh"
        ) ;;    -h|--help) usage; exit 0 ;;
    *) printf 'unknown test selection: %s\n' "$1" >&2; usage; exit 1 ;;
esac

failed=0
for t in "${tests[@]}"; do
    printf '\n'
    if bash "$t"; then
        :
    else
        failed=$((failed + 1))
    fi
done

printf '\n== live smoke summary: %d/%d test scripts passed ==\n' \
    "$(( ${#tests[@]} - failed ))" "${#tests[@]}"
[[ "$failed" -eq 0 ]]
