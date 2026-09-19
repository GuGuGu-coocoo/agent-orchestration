#!/usr/bin/env bash
# run-a-single-task.sh - LIVE test A: the happy path.
#
# One throwaway repo, one implement Task ("hello" -> "hello worker"):
#   worker reads, edits, runs, verifies, writes RESULT.md
# Asserts: exit 0, RESULT.md present, diff only touches app.py, app.py says hello worker.

set -euo pipefail

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$SMOKE_DIR/helpers.sh"

require_live_env
TEST_NAME="A-single-task"
printf '== live test A: single implement task (model: %s) ==\n' "$SMOKE_MODEL"

repo="$(new_repo smoke-A)"
CLEANUP_DIRS+=("$repo")
copy_asset "single_task/app.py" "$repo"
copy_asset "single_task/test_app.py" "$repo"
commit_all "$repo" "initial commit"

write_task "$repo" "A01" "implement" \
    "Make the program's output exactly 'hello worker'. Change app.py's main block to print 'hello worker' (the greeting() and greet() functions and their return values must stay exactly as they are)." \
    "Running python3 app.py prints: hello. greeting() returns 'hello'. greet('worker') returns 'hello worker'." \
    "Running python3 app.py prints: hello worker. greeting() still returns 'hello'. greet('worker') still returns 'hello worker'." \
    "- app.py - the only production file involved" \
    "- app.py (the __main__ block's printed string only)" \
    "- test_app.py, the greeting() and greet() functions and their return values, any other file, public interface" \
    "- [ ] python3 app.py prints hello worker
- [ ] python3 test_app.py still passes" \
    "- python3 app.py
- python3 test_app.py" \
    "none expected; if the test contradicts the task, escalate"

info "running worker in $repo"
run_worker_live "$repo" --mode implement --task-id A01

check_eq "worker exit code is 0" "0" "$LAST_EXIT"
check "RESULT.md exists" test -s "$repo/.agent/current/RESULT.md"
check "no ESCALATION.md" bash -c "! test -e '$repo/.agent/current/ESCALATION.md'"
check "app.py prints hello worker" bash -c "cd '$repo' && [[ \"\$(python3 app.py)\" == 'hello worker' ]]"
check "test_app.py passes" bash -c "cd '$repo' && python3 test_app.py"
changed_files="$(cd "$repo" && git status --porcelain -- . ':!.agent' | awk '{print $2}' | sort -u | tr '\n' ' ' | sed 's/ $//')"
check_eq "diff touches only app.py" "app.py" "$changed_files"
check "RESULT.md mentions the task id" grep -q 'A01' "$repo/.agent/current/RESULT.md"
check "STATE.json recorded the model" grep -q "$SMOKE_MODEL" "$repo/.agent/current/STATE.json"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    printf '\n--- worker log tail ---\n'
    tail -20 "$OUT_DIR/worker-${TEST_NAME}.log" || true
    printf '\n--- RESULT.md ---\n'
    cat "$repo/.agent/current/RESULT.md" 2>/dev/null || true
fi

finish
