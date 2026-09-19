#!/usr/bin/env bash
# run-e-resume.sh - LIVE test E: resume an interrupted Phase without re-running.
#
# Scenario (the real window between "mark in_progress" and "report written"):
#   A01 done, A02 in_progress, no report for A02.
# The driver must resume A02 (never re-run A01), then finish the phase.
#
#   --template   also replaces .agent/current/TASK.md with the blank template
#                (the M03 window where the queue says in_progress but TASK.md was
#                never written / was already archived). The driver must rebuild
#                TASK.md from the saved definition before running.
#
# Usage: tests/smoke/run-e-resume.sh [--template]

set -euo pipefail

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$SMOKE_DIR/helpers.sh"

TEMPLATE_MODE=0
SUFFIX=""
NAME_SUFFIX=""
if [[ "${1:-}" == "--template" ]]; then
    TEMPLATE_MODE=1
    SUFFIX=" [template TASK.md]"
    NAME_SUFFIX="t"
fi

require_live_env
TEST_NAME="E-resume"
if [[ "$TEMPLATE_MODE" -eq 1 ]]; then
    TEST_NAME="E-resume-template"
fi
printf '== live test E: resume in_progress (OpenCode default model)%s ==\n' "$SUFFIX"

repo="$(new_repo "smoke-E${NAME_SUFFIX}")"
CLEANUP_DIRS+=("$repo")

copy_asset "phase/app.py" "$repo"
copy_asset "phase/test_app.py" "$repo"
copy_asset "phase/ROADMAP.md" "$repo"
copy_asset "phase/pytest.ini" "$repo"

mkdir -p "$repo/.agent/phases/A/history" "$repo/.agent/current"
cp "$SMOKE_DIR/assets/phase/PHASE.md" "$repo/.agent/phases/A/PHASE.md"

# A01 done before this session; A02 interrupted (in_progress, no report).
cat >"$repo/.agent/phases/A/TASK_QUEUE.json" <<'EOF'
{
  "phase": "A",
  "status": "running",
  "human_checkpoint_after": true,
  "created_at": "2026-09-19T00:00:00Z",
  "updated_at": "2026-09-19T00:00:00Z",
  "tasks": [
    {
      "id": "A01",
      "title": "add uppercase()",
      "mode": "implement",
      "status": "done",
      "acceptance_summary": "uppercase('abc') == 'ABC'",
      "depends_on": [],
      "history": [{"at": "2026-09-19T00:00:00Z", "decision": "ACCEPT", "note": "before this session"}]
    },
    {
      "id": "A02",
      "title": "add shutdown(seconds)",
      "mode": "implement",
      "status": "in_progress",
      "acceptance_summary": "shutdown(5) == 'shutting down in 5s'",
      "depends_on": ["A01"],
      "history": []
    }
  ],
  "adjustments": []
}
EOF

cat >"$repo/.agent/RUN_STATE.json" <<'EOF'
{
  "target_phase": "A",
  "current_phase": "A",
  "current_task": "A02",
  "status": "running",
  "human_checkpoint": "after_phase_A",
  "updated_at": "2026-09-19T00:00:00Z",
  "notes": "A02 interrupted before its report"
}
EOF

cat >"$repo/.agent/current/STATE.json" <<'EOF'
{
  "task_id": "A02",
  "mode": "implement",
  "run_id": "20260919T000000Z-0000",
  "status": "running",
  "session_id": "",
  "started_at": "2026-09-19T00:00:00Z",
  "log_file": ""
}
EOF

if [[ "$TEMPLATE_MODE" -eq 1 ]]; then
    # The M03 window: queue says in_progress, but current/TASK.md is the blank template.
    cp "$HOME/.agents/skills/cheap-worker/assets/templates/TASK.md" "$repo/.agent/current/TASK.md"
else
    cat >"$repo/.agent/current/TASK.md" <<'EOF'
# Task

## Task ID
A02

## Mode
implement

## Objective
Add shutdown(seconds) to app.py: it must return exactly 'shutting down in <N>s' for integer N. Also add a test function test_shutdown() to test_app.py asserting shutdown(5) == 'shutting down in 5s'.

## Existing Behavior
app.py defines uppercase() only. test_app.py has test_uppercase().

## Desired Behavior
python3 -m pytest -q test_app.py passes, including the new test_shutdown()

## Relevant Files
- app.py - the application module
- test_app.py - the acceptance test suite

## Allowed Changes
- app.py (append shutdown) and test_app.py (append test_shutdown)

## Forbidden Changes
- deleting or weakening test_uppercase; any other file

## Acceptance Criteria
- [ ] python3 -m pytest -q test_app.py passes, including the new test_shutdown()
- [ ] every Required Verification command passes

## Required Verification
- python3 -m pytest -q test_app.py

## Escalation Conditions
- none expected
EOF
fi

commit_all "$repo" "phase A interrupted resume scaffold"

SMOKE_MODEL_UNUSED=1 SMOKE_DIR="$SMOKE_DIR" REPO="$repo" REWORK_MODE=0 \
    bash "$SMOKE_DIR/lib/phase-driver.sh" >"$OUT_DIR/worker-${TEST_NAME}.log" 2>&1
driver_rc=$?

check_eq "driver resumed and finished" "0" "$driver_rc"
check "driver logged the resume" grep -q 'resuming in_progress task A02' "$OUT_DIR/worker-${TEST_NAME}.log"
check "A02 is done" bash -c "jq -e '[.tasks[] | select(.id==\"A02\")][0].status == \"done\"' '$repo/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "A01 history untouched" bash -c "jq -e '[.tasks[] | select(.id==\"A01\")][0].history | length == 1' '$repo/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "A01 was never re-run" bash -c "! ls -d '$repo'/.agent/history/*A01 >/dev/null 2>&1"
check "A02 archived" bash -c "ls -d '$repo'/.agent/history/*A02 >/dev/null 2>&1"
check "the rebuilt TASK.md was saved to history" test -s "$repo/.agent/phases/A/history/TASK-A02.md"

if [[ "$TEMPLATE_MODE" -eq 1 ]]; then
    # The run only succeeds because the driver rebuilt TASK.md from the queue
    # definition; the archived copy proves the render happened.
    check "the rebuilt TASK.md was archived" bash -c "grep -q '^A02$' '$repo/.agent/phases/A/history/TASK-A02.md'"
fi

check "shutdown works" bash -c "cd '$repo' && python3 -c \"from app import shutdown; assert shutdown(5) == 'shutting down in 5s'\""
check "phase review ran" bash -c "grep -q 'PASS (exit 0)' '$repo/.agent/phases/A/PHASE_REVIEW.md'"
check "RUN_STATE is awaiting_human_qa" bash -c "jq -e '.status == \"awaiting_human_qa\"' '$repo/.agent/RUN_STATE.json' >/dev/null"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    printf '\n--- driver log tail ---\n'
    tail -30 "$OUT_DIR/worker-${TEST_NAME}.log" || true
fi

finish
