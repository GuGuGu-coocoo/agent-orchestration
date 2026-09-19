#!/usr/bin/env bash
# run-b-investigate.sh - LIVE test B: investigate mode must not modify business code.
#
# Throwaway repo with a deliberately suspicious function. Task: find out whether
# divide() has a defect, do not change any code.
# Asserts: exit 0, RESULT.md present, git diff empty (no business code change).

set -euo pipefail

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$SMOKE_DIR/helpers.sh"

require_live_env
TEST_NAME="B-investigate"
printf '== live test B: investigate mode, no code changes (OpenCode default model) ==\n'

repo="$(new_repo smoke-B)"
CLEANUP_DIRS+=("$repo")
copy_asset "investigate/calc.py" "$repo"
commit_all "$repo" "initial commit"

write_task "$repo" "B01" "investigate" \
    "Determine whether calc.divide() returns correct results for a == 0 and report the finding." \
    "calc.divide(a, b) returns a / b and has not been tested with a == 0." \
    "A written finding in RESULT.md; no code changes at all." \
    "- calc.py - the file under investigation" \
    "- NOTHING. Read-only task. Do not modify any file." \
    "- calc.py and every other file - this run must leave the tree clean" \
    "- [ ] RESULT.md describes what divide(0, 5) returns
- [ ] no file in the repo was modified" \
    "- python3 -c \"from calc import divide; print(divide(0, 5))\"
- git status --porcelain (must show no changes)" \
    "none; this is a read-only investigation"

info "running worker in $repo"
run_worker_live "$repo" --mode investigate --task-id B01

check_eq "worker exit code is 0" "0" "$LAST_EXIT"
check "RESULT.md exists" test -s "$repo/.agent/current/RESULT.md"
b_diff="$(cd "$repo" && git status --porcelain -- . ':!.agent' | tr -d ' \n')"
check_eq "no tracked file was modified" "" "$b_diff"
check "RESULT.md mentions divide" grep -qi 'divide' "$repo/.agent/current/RESULT.md"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    printf '\n--- worker log tail ---\n'
    tail -20 "$OUT_DIR/worker-${TEST_NAME}.log" || true
    printf '\n--- RESULT.md ---\n'
    cat "$repo/.agent/current/RESULT.md" 2>/dev/null || true
fi

finish
