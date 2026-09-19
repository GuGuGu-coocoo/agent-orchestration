#!/usr/bin/env bash
# run-e-resume.sh - LIVE test F: resume an interrupted Phase with the real loop.
#
# Scenario (the window between "mark in_progress" and the report being written):
#   A01 done, A02 in_progress (no report), A03 pending, TASK.md still the blank
#   template, and a stale ESCALATION.md from an older Task in the way.
#
# The loop must:
#   - quarantine the stale report,
#   - rebuild .agent/current/TASK.md from the A02 queue definition,
#   - resume A02 (never re-run A01),
#   - continue automatically with A03,
#   - stop at awaiting_phase_review.
#
# Usage: tests/smoke/run-e-resume.sh

set -euo pipefail

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$SMOKE_DIR/helpers.sh"

require_live_env
TEST_NAME="E-resume"
printf '== live test F: resume an interrupted Phase (OpenCode default model) ==\n'

repo="$(new_repo smoke-E)"
CLEANUP_DIRS+=("$repo")

copy_asset "phase/app.py" "$repo"
copy_asset "phase/test_app.py" "$repo"
copy_asset "phase/pytest.ini" "$repo"
printf '# Fixture project\n' >"$repo/README.md"

mkdir -p "$repo/.agent/phases/A/history" "$repo/.agent/current"
cp "$SMOKE_DIR/assets/phase/PHASE.md" "$repo/.agent/phases/A/PHASE.md"

TASKS="$OUT_DIR/.e-tasks.$$"
queue_task_json A01 "add uppercase()" low done \
    "python3 -c \"from app import uppercase; assert uppercase('abc') == 'ABC'\"" \
    "app.py, test_app.py" \
    "" \
    "uppercase('abc') == 'ABC'" >>"$TASKS"
queue_task_json A02 "add shutdown(seconds)" low in_progress \
    "grep -q 'def test_shutdown' test_app.py && python3 -m pytest -q test_app.py" \
    "app.py, test_app.py" \
    "" \
    "shutdown(5) == 'shutting down in 5s' and test_shutdown() exists" >>"$TASKS"
queue_task_json A03 "add farewell(name)" low pending \
    "grep -q 'def test_farewell' test_app.py && python3 -m pytest -q test_app.py" \
    "app.py, test_app.py" \
    "" \
    "farewell('Ada') == 'bye, Ada' and test_farewell() exists" >>"$TASKS"
write_queue "$repo" "A" "$TASKS" "python3 -m pytest -q test_app.py"

python3 - "$repo/.agent/phases/A/TASK_QUEUE.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
texts = {
    "A01": "uppercase(s) already exists; this Task was completed before the interruption.",
    "A02": "Add shutdown(seconds) to app.py returning exactly 'shutting down in <N>s' for an integer N. Append a test function named test_shutdown to test_app.py asserting shutdown(5) == 'shutting down in 5s'. Do not change test_uppercase or anything else.",
    "A03": "Add farewell(name) to app.py returning exactly 'bye, <name>'. Append a test function named test_farewell to test_app.py asserting farewell('Ada') == 'bye, Ada'. Do not change test_uppercase/test_shutdown or anything else.",
}
for t in d["tasks"]:
    t["objective"] = texts[t["id"]]
    t["desired_behavior"] = texts[t["id"]]
    t["context"] = "Smoke-test Phase A resume scenario."
    t["existing_behavior"] = "app.py has uppercase(); test_app.py has test_uppercase()."
    t["escalation_conditions"] = ["needs a public API or schema change", "two genuinely different attempts failed"]
# A01 was completed before this session: it must never be re-run.
d["tasks"][0]["history"] = [{"at": "2026-09-19T00:00:00Z", "decision": "ACCEPT", "note": "before this session", "by": "run-phase.sh"}]
json.dump(d, open(p, "w"), indent=2)
PY

write_run_state "$repo" "A" "running" >/dev/null
python3 - "$repo/.agent/RUN_STATE.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["current_task"] = "A02"
d["notes"] = "A02 interrupted before its report"
d["stop_reason"] = "worker_plumbing"
json.dump(d, open(p, "w"), indent=2)
PY

# The M03 window: the queue says in_progress but TASK.md is still the blank template.
cp "$PROJECT_ROOT/skills/cheap-worker/assets/templates/TASK.md" "$repo/.agent/current/TASK.md"
printf '%s' '{"task_id":"A02","mode":"implement","run_id":"20260919T000000Z-0000","status":"running","session_id":"","started_at":"2026-09-19T00:00:00Z","log_file":""}' \
    >"$repo/.agent/current/STATE.json"

# A stale report from an older Task must be quarantined, not treated as current.
cat >"$repo/.agent/current/ESCALATION.md" <<'EOF'
# Escalation

## Task ID
A00

## Class
CHECKPOINT

## Current Blocker
stale report from an older Task
EOF

commit_all "$repo" "phase A interrupted resume scaffold"

info "resuming the phase loop in $repo"
run_phase_live "$repo"

check_eq "the loop resumed and finished the phase -> exit 0" "0" "$LAST_EXIT"
check "the loop reported the resume" grep -q 'resumed=yes' "$OUT_DIR/phase-${TEST_NAME}.log"
check "it resumed A02, not A01" grep -q 'A02 start (mode=implement risk=low resumed=yes)' "$OUT_DIR/phase-${TEST_NAME}.log"
check "A01 was never re-run" bash -c "! ls -d '$repo'/.agent/history/*A01 >/dev/null 2>&1"
check "the stale report was quarantined" bash -c "grep -rl 'stale report from an older Task' '$repo/.agent/history/attempts' >/dev/null 2>&1"
check "A02 is done" bash -c \
    "jq -e '[.tasks[] | select(.id==\"A02\")][0].status == \"done\"' '$repo/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "A03 continued automatically" bash -c \
    "jq -e '[.tasks[] | select(.id==\"A03\")][0].status == \"done\"' '$repo/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "shutdown works" bash -c "cd '$repo' && python3 -c \"from app import shutdown; assert shutdown(5) == 'shutting down in 5s'\""
check "farewell works" bash -c "cd '$repo' && python3 -c \"from app import farewell; assert farewell('Ada') == 'bye, Ada'\""
check "the built TASK.md matches the resumed Task" bash -c "grep -q 'A02' '$repo/.agent/phases/A/history/TASK-A02.md'"
check "the Phase verification ran" grep -q 'PASS (exit 0)' "$repo/.agent/phases/A/PHASE_REVIEW.md"
check "RUN_STATE is awaiting_phase_review" bash -c "jq -e '.status == \"awaiting_phase_review\"' '$repo/.agent/RUN_STATE.json' >/dev/null"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    printf '\n--- loop log tail ---\n'
    tail -40 "$OUT_DIR/phase-${TEST_NAME}.log" || true
    printf '\n--- final queue ---\n'
    cat "$repo/.agent/phases/A/TASK_QUEUE.json" 2>/dev/null || true
fi

finish
