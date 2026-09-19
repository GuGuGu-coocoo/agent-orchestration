#!/usr/bin/env bash
# run-d-phase-runner.sh - LIVE tests D + E: phase queue execution and resume.
#
# D) A 3-Task phase queue (A01..A03, one file) is executed by a supervisor
#    driver: one Task at a time, review, ACCEPT, archive, next Task - without the
#    user ever typing "continue".
# E) The run starts with A01 already done and A02 pending (interrupted run), so
#    the driver must resume from TASK_QUEUE.json, never re-run A01.
#
# Usage: tests/smoke/run-d-phase-runner.sh [--rework]
#   --rework injects a deliberate REWORK on A02 (corrective REVIEW.md) before accept.

set -euo pipefail

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$SMOKE_DIR/helpers.sh"

REWORK_MODE=0
[[ "${1:-}" == "--rework" ]] && REWORK_MODE=1

require_live_env
TEST_NAME="D-phase-runner"
printf '== live test D+E: phase queue + resume (model: %s)%s ==\n' \
    "$SMOKE_MODEL" "$([[ $REWORK_MODE -eq 1 ]] && printf ' [rework mode]')"

repo="$(new_repo smoke-D)"
CLEANUP_DIRS+=("$repo")

# --- Phase A scaffolding -----------------------------------------------------
copy_asset "phase/app.py" "$repo"
copy_asset "phase/test_app.py" "$repo"
copy_asset "phase/ROADMAP.md" "$repo"
copy_asset "phase/pytest.ini" "$repo"

mkdir -p "$repo/.agent/phases/A/history" "$repo/.agent/current"
cp "$SMOKE_DIR/assets/phase/PHASE.md" "$repo/.agent/phases/A/PHASE.md"
cp "$SMOKE_DIR/assets/phase/RUN_STATE.json" "$repo/.agent/RUN_STATE.json"

# Resume scenario: A01 already done, A02 pending, nothing in progress.
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
      "history": [
        {"at": "2026-09-19T00:00:00Z", "decision": "ACCEPT", "note": "completed before this session"}
      ]
    },
    {
      "id": "A02",
      "title": "add shutdown(seconds)",
      "mode": "implement",
      "status": "pending",
      "acceptance_summary": "shutdown(5) == 'shutting down in 5s'",
      "depends_on": ["A01"],
      "history": []
    },
    {
      "id": "A03",
      "title": "add farewell(name)",
      "mode": "implement",
      "status": "pending",
      "acceptance_summary": "farewell('Ada') == 'bye, Ada'",
      "depends_on": [],
      "history": []
    }
  ],
  "adjustments": []
}
EOF

commit_all "$repo" "phase A scaffolding"

# --- Run the supervisor driver ------------------------------------------------
SMOKE_MODEL="$SMOKE_MODEL" \
SMOKE_DIR="$SMOKE_DIR" \
REPO="$repo" \
REWORK_MODE="$REWORK_MODE" \
bash "$SMOKE_DIR/lib/phase-driver.sh" >"$OUT_DIR/worker-${TEST_NAME}.log" 2>&1
driver_rc=$?

info "driver exit code: $driver_rc"

# --- Assertions ----------------------------------------------------------------
check_eq "driver completed the phase" "0" "$driver_rc"
check "all three tasks are done" bash -c \
    "jq -e '[.tasks[] | select(.status==\"done\")] | length == 3' '$repo/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "A01 history was not appended by this run" bash -c \
    "jq -e '[.tasks[] | select(.id==\"A01\")][0].history | length == 1' '$repo/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "A02 history has an ACCEPT" bash -c \
    "jq -e '[.tasks[] | select(.id==\"A02\")][0].history | map(.decision) | index(\"ACCEPT\") != null' '$repo/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "A03 history has an ACCEPT" bash -c \
    "jq -e '[.tasks[] | select(.id==\"A03\")][0].history | map(.decision) | index(\"ACCEPT\") != null' '$repo/.agent/phases/A/TASK_QUEUE.json' >/dev/null"

check "app.py implements uppercase" bash -c "cd '$repo' && python3 -c \"from app import uppercase; assert uppercase('abc') == 'ABC'\""
check "app.py implements shutdown" bash -c "cd '$repo' && python3 -c \"from app import shutdown; assert shutdown(5) == 'shutting down in 5s'\""
check "app.py implements farewell" bash -c "cd '$repo' && python3 -c \"from app import farewell; assert farewell('Ada') == 'bye, Ada'\""
check "the acceptance test suite passes" bash -c "cd '$repo' && python3 -m pytest -q test_app.py"
check "the worker added both test functions" bash -c "grep -q 'def test_shutdown' '$repo/test_app.py' && grep -q 'def test_farewell' '$repo/test_app.py'"
check "no existing assertion was weakened" bash -c "grep -q 'def test_uppercase' '$repo/test_app.py' && grep -q 'uppercase(\"abc\") == \"ABC\"' '$repo/test_app.py'"

check "phase status is done" bash -c "jq -e '.status == \"done\"' '$repo/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "RUN_STATE is awaiting_human_qa" bash -c "jq -e '.status == \"awaiting_human_qa\"' '$repo/.agent/RUN_STATE.json' >/dev/null"
check "RUN_STATE current_phase is A" bash -c "jq -e '.current_phase == \"A\"' '$repo/.agent/RUN_STATE.json' >/dev/null"
check "no ESCALATION.md remains" bash -c "! test -s '$repo/.agent/current/ESCALATION.md'"

archived_count="$(ls -d "$repo"/.agent/history/*A0[23] 2>/dev/null | wc -l | tr -d ' ')"
expected_archives=2
[[ "$REWORK_MODE" -eq 1 ]] && expected_archives=3  # A02 archived twice in rework mode
check_eq "A02 and A03 archives recorded" "$expected_archives" "$archived_count"
check "A02 archive recorded ACCEPT" grep -q 'Decision: ACCEPT' "$repo"/.agent/history/*A02/REVIEW_DECISION.md
check "A03 archive recorded ACCEPT" grep -q 'Decision: ACCEPT' "$repo"/.agent/history/*A03/REVIEW_DECISION.md
check "A01 was never re-run (no worker log for it)" bash -c "! ls '$repo'/.agent/history/A01/logs/worker-*.jsonl >/dev/null 2>&1"

if [[ "$REWORK_MODE" -eq 1 ]]; then
    check "the REWORK was recorded" bash -c \
        "jq -e '[.tasks[] | select(.id==\"A02\")][0].history | map(.decision) | index(\"REWORK\") != null' '$repo/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
    check "a REWORK review was archived" bash -c "grep -l 'Decision' '$repo'/.agent/history/*A02/REVIEW_DECISION.md | xargs grep -l 'REWORK' >/dev/null"
    check "the edge-case test survived the rework" bash -c "grep -q 'def test_shutdown_zero' '$repo/test_app.py'"
fi

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    printf '\n--- driver log tail ---\n'
    tail -40 "$OUT_DIR/worker-${TEST_NAME}.log" || true
    printf '\n--- final queue ---\n'
    cat "$repo/.agent/phases/A/TASK_QUEUE.json" 2>/dev/null || true
fi

finish
