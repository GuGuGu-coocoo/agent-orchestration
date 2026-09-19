#!/usr/bin/env bash
# run-d-phase-runner.sh - LIVE tests A + D + E: the Phase loop with a real model.
#
# A) Three bounded, low-risk Tasks are declared in TASK_QUEUE.json. The loop runs
#    them one OpenCode session at a time, re-runs each Task's verification itself
#    (the evidence gate), auto-accepts and continues - the user never types
#    "continue" and Codex is not asked to review a single Task.
# D) When the last Task is done the loop STOPS at awaiting_phase_review.
# E) `phase-gate.sh review-pass` re-runs the Phase verification and moves to
#    awaiting_human_qa; the loop then refuses to run (exit 4) and `qa-pass`
#    records the human verdict.
#
# Usage: tests/smoke/run-d-phase-runner.sh

set -euo pipefail

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$SMOKE_DIR/helpers.sh"

require_live_env
TEST_NAME="D-phase-runner"
printf '== live test D: phase loop, auto-continue + review gates (OpenCode default model) ==\n'

repo="$(new_repo smoke-D)"
CLEANUP_DIRS+=("$repo")

# --- Phase A scaffolding -----------------------------------------------------
copy_asset "phase/app.py" "$repo"
copy_asset "phase/test_app.py" "$repo"
copy_asset "phase/ROADMAP.md" "$repo"
copy_asset "phase/pytest.ini" "$repo"

mkdir -p "$repo/.agent/phases/A/history" "$repo/.agent/current"
cp "$SMOKE_DIR/assets/phase/PHASE.md" "$repo/.agent/phases/A/PHASE.md"
write_run_state "$repo" "A" "idle" >/dev/null

TASKS="$OUT_DIR/.d-tasks.$$"
queue_task_json D01 "add shutdown(seconds)" low pending \
    "grep -q 'def test_shutdown' test_app.py && python3 -m pytest -q test_app.py" \
    "app.py, test_app.py" \
    "" \
    "shutdown(5) == 'shutting down in 5s' and test_shutdown() exists" >>"$TASKS"
queue_task_json D02 "add farewell(name)" low pending \
    "grep -q 'def test_farewell' test_app.py && python3 -m pytest -q test_app.py" \
    "app.py, test_app.py" \
    "" \
    "farewell('Ada') == 'bye, Ada' and test_farewell() exists" >>"$TASKS"
queue_task_json D03 "document the utilities" low pending \
    "grep -q 'farewell' README.md && python3 -m pytest -q test_app.py" \
    "README.md, app.py" \
    "" \
    "README documents uppercase/shutdown/farewell and the suite still passes" >>"$TASKS"
write_queue "$repo" "A" "$TASKS" "python3 -m pytest -q test_app.py"

# The tasks must be explicit about the test functions the phase verification checks.
python3 - "$repo/.agent/phases/A/TASK_QUEUE.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
texts = {
    "D01": "Add shutdown(seconds) to app.py returning exactly 'shutting down in <N>s' for an integer N. Append a test function named test_shutdown to test_app.py asserting shutdown(5) == 'shutting down in 5s'. Do not change test_uppercase or anything else.",
    "D02": "Add farewell(name) to app.py returning exactly 'bye, <name>'. Append a test function named test_farewell to test_app.py asserting farewell('Ada') == 'bye, Ada'. Do not change test_uppercase/test_shutdown or anything else.",
    "D03": "Append a short '## Utilities' section to README.md documenting uppercase(s), shutdown(seconds) and farewell(name) in one line each. Do not change any behavior: app.py may only get docstring-level edits if you touch it at all.",
}
for t in d["tasks"]:
    t["objective"] = texts[t["id"]]
    t["desired_behavior"] = texts[t["id"]]
    t["context"] = "Smoke-test Phase A: one bounded change, verified by the loop."
    t["existing_behavior"] = "app.py has uppercase(); test_app.py has test_uppercase(); README.md has no Utilities section."
    t["escalation_conditions"] = ["needs a public API or schema change", "two genuinely different attempts failed"]
json.dump(d, open(p, "w"), indent=2)
PY

commit_all "$repo" "phase A scaffolding"

# --- Run the loop -------------------------------------------------------------
info "running the phase loop in $repo"
run_phase_live "$repo"

check_eq "the loop completed the phase -> exit 0" "0" "$LAST_EXIT"
check "all three Tasks are done" bash -c \
    "jq -e '[.tasks[] | select(.status==\"done\")] | length == 3' '$repo/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "every Task carries an ACCEPT history entry" bash -c \
    "jq -e '[.tasks[] | select((.history | map(.decision) | index(\"ACCEPT\")) == null)] | length == 0' '$repo/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "app.py implements shutdown" bash -c "cd '$repo' && python3 -c \"from app import shutdown; assert shutdown(5) == 'shutting down in 5s'\""
check "app.py implements farewell" bash -c "cd '$repo' && python3 -c \"from app import farewell; assert farewell('Ada') == 'bye, Ada'\""
check "the acceptance test suite passes" bash -c "cd '$repo' && python3 -m pytest -q test_app.py"
check "the worker added both test functions" bash -c "grep -q 'def test_shutdown' '$repo/test_app.py' && grep -q 'def test_farewell' '$repo/test_app.py'"
check "no existing assertion was weakened" bash -c "grep -q 'def test_uppercase' '$repo/test_app.py'"
check "README documents the utilities" bash -c "grep -q 'farewell' '$repo/README.md'"

check "the loop never stopped mid-phase" bash -c "! grep -q 'STOP (' '$OUT_DIR/phase-${TEST_NAME}.log'"
check "three worker sessions ran" bash -c "[ \"\$(grep -c 'worker exit=0' '$OUT_DIR/phase-${TEST_NAME}.log')\" = 3 ]"
check "the sessions used the cheap-worker naming" grep -q 'session title=cheap-worker · D01' "$OUT_DIR/phase-${TEST_NAME}.log"

check "evidence per Task was kept" bash -c "test -s '$repo/.agent/phases/A/history/VERIFY-D01.md'"
check "the rendered Task was kept" bash -c "test -s '$repo/.agent/phases/A/history/TASK-D02.md'"
archived_count="$(ls -d "$repo"/.agent/history/*D0[123] 2>/dev/null | wc -l | tr -d ' ')"
check_eq "each Task was archived once" "3" "$archived_count"
check "the archive recorded ACCEPT" bash -c "grep -q 'Decision: ACCEPT' '$repo'/.agent/history/*D01/REVIEW_DECISION.md"

# --- D: stop at awaiting_phase_review ----------------------------------------
check "phase status is done" bash -c "jq -e '.status == \"done\"' '$repo/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "RUN_STATE is awaiting_phase_review" bash -c "jq -e '.status == \"awaiting_phase_review\"' '$repo/.agent/RUN_STATE.json' >/dev/null"
check "stop_reason says the phase completed" bash -c "jq -e '.stop_reason == \"phase_complete\"' '$repo/.agent/RUN_STATE.json' >/dev/null"
check "no next Phase was started" bash -c "! test -d '$repo/.agent/phases/B'"
check "the loop refuses to run at the review gate" bash -c \
    "cd '$repo' && '$RUN_PHASE' >/dev/null 2>&1; [ \$? -eq 4 ]"
check "the Phase verification ran for real" grep -q 'PASS (exit 0)' "$repo/.agent/phases/A/PHASE_REVIEW.md"

# --- E: the phase review -> awaiting_human_qa --------------------------------
RG_RC=0
(cd "$repo" && "$PHASE_GATE" review-pass --summary "reviewed the D01-D03 diffs, the archived VERIFY files and re-ran the suite") \
    >"$OUT_DIR/gate-d.log" 2>&1 || RG_RC=$?
check_eq "review-pass exits 0" "0" "$RG_RC"
check "RUN_STATE is awaiting_human_qa" bash -c "jq -e '.status == \"awaiting_human_qa\"' '$repo/.agent/RUN_STATE.json' >/dev/null"
check "the review is recorded" bash -c "jq -e '.phase_review == \"passed\"' '$repo/.agent/RUN_STATE.json' >/dev/null"
check "PHASE.md has the Result section" grep -q 'Reviewed by: Codex phase review' "$repo/.agent/phases/A/PHASE.md"
check "the review re-ran the phase verification" grep -q 'Phase review run' "$repo/.agent/phases/A/PHASE_REVIEW.md"
check "the loop refuses to run while the human decides" bash -c \
    "cd '$repo' && '$RUN_PHASE' >/dev/null 2>&1; [ \$? -eq 4 ]"

# review-fail on a Phase that already moved on must be refused
RF_RC=0
(cd "$repo" && "$PHASE_GATE" review-fail --reason "should not apply now") >"$OUT_DIR/gate-d-fail.log" 2>&1 || RF_RC=$?
check_eq "review-fail in the wrong state -> exit 1" "1" "$RF_RC"

# the human confirms
QA_RC=0
(cd "$repo" && "$PHASE_GATE" qa-pass --note "the human ran the suite manually") >"$OUT_DIR/gate-d-qa.log" 2>&1 || QA_RC=$?
check_eq "qa-pass exits 0" "0" "$QA_RC"
check "the human verdict is recorded" bash -c "jq -e '.human_qa == \"passed\"' '$repo/.agent/RUN_STATE.json' >/dev/null"
check "the state is idle after the human confirmed" bash -c "jq -e '.status == \"idle\"' '$repo/.agent/RUN_STATE.json' >/dev/null"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    printf '\n--- loop log tail ---\n'
    tail -40 "$OUT_DIR/phase-${TEST_NAME}.log" || true
    printf '\n--- final RUN_STATE ---\n'
    cat "$repo/.agent/RUN_STATE.json" 2>/dev/null || true
    printf '\n--- final queue ---\n'
    cat "$repo/.agent/phases/A/TASK_QUEUE.json" 2>/dev/null || true
fi

finish
