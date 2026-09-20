#!/usr/bin/env bash
# run-offline.sh - script-level smoke tests. No model calls, nothing is installed.
#
# Runs the scripts from THIS repository (skills/*/scripts), so a development
# checkout is verified before it is installed and ~/.agents/skills is never
# modified.
#
# Verifies:
#   - doctor.sh passes, checks the shared service and the phase loop flags
#   - SKILL.md frontmatter is valid for both skills
#   - run-worker.sh / run-phase.sh / worker-notify.sh never pass --model or
#     --standalone (no model layer, shared service only)
#   - run-worker.sh fails fast without a Task and rejects --model
#   - the run-worker safety harness (fake opencode): report validation, stale
#     report quarantine, lock identity, SIGTERM keeps the lock, TASK.md checks,
#     dirty baseline, cwd pinning
#   - the phase loop end to end against a fake worker:
#       A: low-risk Tasks auto-continue (C01 -> C02 -> C03, one session each)
#       B: a guarded Task / a worker CHECKPOINT stops the loop
#       C: an ESCALATE stops the loop and blocks further runs
#       D: the last Task enters awaiting_phase_review (never the next Phase)
#       E: phase-gate review-pass -> awaiting_human_qa; run-phase refuses to run
#       F: resume of an in_progress Task (never re-running the done ones)
#     plus the evidence gate (verification, diff scope, ticked criteria,
#     Supervisor-artifact tampering) and plan validation
#   - check-state fail-closed matrix for the new states
#   - phase-gate refusals (wrong state, missing summary/reason)
#   - install/uninstall boundaries (fresh HOME, symlink escape, source copy)
#
# Usage: tests/smoke/run-offline.sh

set -euo pipefail

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$SMOKE_DIR/helpers.sh"

TEST_NAME="offline"
printf '== offline smoke tests ==\n'

# ---------------------------------------------------------------------------
# 1. builder and installer invariants
# ---------------------------------------------------------------------------
info "source tree: $PROJECT_ROOT"

for s in cheap-worker phase-runner; do
    src="$PROJECT_ROOT/skills/$s/SKILL.md"
    check "SKILL.md exists for $s" test -f "$src"
    check "SKILL.md frontmatter has name" bash -c "head -20 '$src' | grep -q '^name: $s$'"
    check "SKILL.md frontmatter has description" bash -c "head -20 '$src' | grep -q '^description: '"
done

# The installed copy is a separate, deliberate install step: this repo must never
# assume it is in sync (and the tests never install it).
if [[ -f "$HOME/.agents/skills/cheap-worker/SKILL.md" ]]; then
    if [[ "$(shasum "$PROJECT_ROOT/skills/cheap-worker/SKILL.md" | awk '{print $1}')" == \
          "$(shasum "$HOME/.agents/skills/cheap-worker/SKILL.md" | awk '{print $1}')" ]]; then
        pass "installed cheap-worker SKILL.md matches source"
    else
        info "installed ~/.agents/skills/cheap-worker differs from this source tree (run scripts/install-skills.sh to sync; the tests never do)"
        pass "installed copy exists (not modified by tests)"
    fi
else
    info "cheap-worker is not installed globally (fine for development)"
fi

check "other skills still present (docx)" test -f "$HOME/.agents/skills/docx/SKILL.md"
check "other skills still present (pdf)" test -f "$HOME/.agents/skills/pdf/SKILL.md"

# ---------------------------------------------------------------------------
# 2. doctor
# ---------------------------------------------------------------------------
if "$DOCTOR" --root "$SMOKE_DIR" >"$OUT_DIR/doctor.log" 2>&1; then
    pass "doctor.sh exits 0"
else
    fail "doctor.sh exited non-zero (see $OUT_DIR/doctor.log)"
fi
check "doctor.sh reports no problems" grep -q 'result: 0 problem' "$OUT_DIR/doctor.log"
check "doctor.sh checks the shared background service" grep -q 'background service' "$OUT_DIR/doctor.log"
check "doctor.sh verifies no --model is passed" grep -q 'never passes --model' "$OUT_DIR/doctor.log"
check "doctor.sh verifies no --standalone is used" grep -q 'never uses --standalone' "$OUT_DIR/doctor.log"
check "doctor.sh checks the phase loop" grep -q 'phase loop' "$OUT_DIR/doctor.log"

# ---------------------------------------------------------------------------
# 3. run-worker.sh preconditions
# ---------------------------------------------------------------------------
repo="$(new_repo smoke-offline)"
CLEANUP_DIRS+=("$repo")

if (cd "$repo" && "$WORKER" --mode implement) >"$OUT_DIR/no-task.log" 2>&1; then
    fail "run-worker.sh should fail without TASK.md"
else
    pass "run-worker.sh fails without TASK.md"
fi
check "failure message is clear" grep -q 'no Task found' "$OUT_DIR/no-task.log"

if (cd "$repo" && "$RUN_PHASE") >"$OUT_DIR/phase-no-state.log" 2>&1; then
    fail "run-phase.sh should fail without RUN_STATE.json"
else
    pass "run-phase.sh fails without RUN_STATE.json"
fi
check "run-phase failure message is clear" grep -q 'no ' "$OUT_DIR/phase-no-state.log"

write_task "$repo" "OFF1" "implement" "objective" "existing" "desired" \
    "- app.py" "- app.py" "- everything else" \
    "- [ ] done" '`python3 app.py` exits 0' "none"

# ---------------------------------------------------------------------------
# 3b. no model configuration layer, shared service only
# ---------------------------------------------------------------------------
for script in "$WORKER" "$RUN_PHASE" "$PHASE_GATE" "$NOTIFY"; do
    name="$(basename "$script")"
    code="$(grep -v '^[[:space:]]*#' "$script")"
    if printf '%s\n' "$code" | grep -q -- '--model'; then
        fail "$name must not pass --model"
    else
        pass "$name never passes --model"
    fi
    if printf '%s\n' "$code" | grep -q -- '--standalone'; then
        fail "$name must not use --standalone"
    else
        pass "$name never uses --standalone"
    fi
done

if (cd "$repo" && "$WORKER" --mode implement --model foo/bar) >"$OUT_DIR/model-flag.log" 2>&1; then
    fail "run-worker.sh should reject an unknown --model flag"
else
    pass "run-worker.sh rejects --model (no model layer in V1)"
fi
check "rejection message names the unknown argument" grep -q "unknown argument '--model'" "$OUT_DIR/model-flag.log"

if (cd "$repo" && "$RUN_PHASE" --model foo/bar) >"$OUT_DIR/phase-model-flag.log" 2>&1; then
    fail "run-phase.sh should reject an unknown --model flag"
else
    pass "run-phase.sh rejects --model"
fi

# the loop must drive the worker through run-worker.sh (no private opencode call)
check "run-phase.sh calls run-worker.sh" grep -q 'run-worker.sh' "$RUN_PHASE"
if grep -v '^[[:space:]]*#' "$RUN_PHASE" | grep -q 'opencode run'; then
    fail "run-phase.sh must not call opencode directly"
else
    pass "run-phase.sh never calls opencode directly (one Task = one session via run-worker.sh)"
fi

# ---------------------------------------------------------------------------
# 4. dry-run
# ---------------------------------------------------------------------------
if (cd "$repo" && "$WORKER" --mode implement --dry-run) >"$OUT_DIR/dryrun.log" 2>&1; then
    pass "dry-run exits 0"
else
    fail "dry-run failed"
fi
check "dry-run reports the task" grep -q 'task         : OFF1' "$OUT_DIR/dryrun.log"
check "dry-run reports a session title" grep -q 'session title: cheap-worker · OFF1' "$OUT_DIR/dryrun.log"
check "dry-run reports the opencode command" grep -q 'opencode run --agent' "$OUT_DIR/dryrun.log"
if grep -q -- '--model' "$OUT_DIR/dryrun.log" 2>/dev/null; then
    fail "dry-run must not mention --model"
else
    pass "dry-run command has no --model"
fi

# ---------------------------------------------------------------------------
# 5. status / collect-result
# ---------------------------------------------------------------------------
if (cd "$repo" && "$STATUS") >"$OUT_DIR/status.log" 2>&1; then
    pass "status.sh exits 0"
else
    fail "status.sh failed"
fi
check "status.sh shows the task id" grep -q 'task id      : OFF1' "$OUT_DIR/status.log"
check "status.sh shows the loop state" grep -q 'loop state   :' "$OUT_DIR/status.log"

if (cd "$repo" && "$COLLECT") >/dev/null 2>&1; then
    fail "collect-result.sh should fail with no report"
else
    pass "collect-result.sh fails with no report"
fi

cat >"$repo/.agent/current/RESULT.md" <<'EOF'
# Result

## Task ID
OFF1

## Status
DONE

## Summary
Offline fixture.
EOF

if (cd "$repo" && "$COLLECT") >"$OUT_DIR/collect.log" 2>&1; then
    pass "collect-result.sh succeeds with a report"
else
    fail "collect-result.sh failed with a report present"
fi
check "collect-result.sh prints the report" grep -q 'Offline fixture' "$OUT_DIR/collect.log"

cat >"$repo/.agent/current/VERIFY.md" <<'EOF'
# Task verification (evidence gate)
- result: PASS
EOF
(cd "$repo" && "$COLLECT") >"$OUT_DIR/collect-verify.log" 2>&1 || true
check "collect-result.sh prints the evidence gate result" grep -q 'evidence gate' "$OUT_DIR/collect-verify.log"
rm -f "$repo/.agent/current/VERIFY.md"

# ---------------------------------------------------------------------------
# 6. archive-task.sh
# ---------------------------------------------------------------------------
if (cd "$repo" && "$ARCHIVER" --decision ACCEPT) >/dev/null 2>&1; then
    fail "archive-task.sh without --yes should refuse"
else
    pass "archive-task.sh refuses without --yes"
fi

mkdir -p "$repo/.agent/history"
cat >"$repo/.agent/current/VERIFY.md" <<'EOF'
# Task verification (evidence gate)
- result: PASS
EOF
if (cd "$repo" && "$ARCHIVER" --yes --decision ACCEPT) >"$OUT_DIR/archive.log" 2>&1; then
    pass "archive-task.sh archives with --yes"
else
    fail "archive-task.sh failed with --yes (see $OUT_DIR/archive.log)"
fi
check "TASK.md was archived" bash -c "ls '$repo'/\.agent/history/*OFF1/TASK.md >/dev/null 2>&1"
check "RESULT.md was archived" bash -c "ls '$repo'/\.agent/history/*OFF1/RESULT.md >/dev/null 2>&1"
check "VERIFY.md was archived" bash -c "ls '$repo'/\.agent/history/*OFF1/VERIFY.md >/dev/null 2>&1"
check "decision record written" bash -c "grep -q 'Decision: ACCEPT' '$repo'/\.agent/history/*OFF1/REVIEW_DECISION.md"
check "current workspace re-seeded with blank TASK.md" bash -c "grep -q '<PHASE>-<NN>' '$repo/.agent/current/TASK.md'"
check "current RESULT.md cleared" bash -c "! test -e '$repo/.agent/current/RESULT.md'"

# ---------------------------------------------------------------------------
# 6b. worker-notify.sh (one Task)
# ---------------------------------------------------------------------------
if "$NOTIFY" --help >"$OUT_DIR/notify-help.log" 2>&1; then
    pass "worker-notify.sh --help exits 0"
else
    fail "worker-notify.sh --help failed"
fi

# fake worker + fake codex: exercise the notify path offline
cat >"$repo/.fake-worker.sh" <<'FAKEEOF'
#!/usr/bin/env bash
echo "fake-worker: $*"
exit 0
FAKEEOF
cat >"$repo/.fake-codex" <<FAKEEOF
#!/usr/bin/env bash
echo "\$*" >>"$OUT_DIR/fake-codex-calls.log"
exit 0
FAKEEOF
chmod +x "$repo/.fake-worker.sh" "$repo/.fake-codex"
rm -f "$OUT_DIR/fake-codex-calls.log"

if (cd "$repo" && WORKER_NOTIFY_RUN_WORKER="$repo/.fake-worker.sh" "$NOTIFY" \
        --no-notify --foreground --mode implement) >"$OUT_DIR/notify-no-thread.log" 2>&1; then
    pass "worker-notify.sh runs with --no-notify"
else
    fail "worker-notify.sh --no-notify run failed"
fi

if (cd "$repo" && WORKER_NOTIFY_RUN_WORKER="$repo/.fake-worker.sh" "$NOTIFY" \
        --foreground --codex-thread "smoke-thread" --codex-bin "$repo/.fake-codex" \
        --mode implement --task-id OFF2) >"$OUT_DIR/notify-foreground.log" 2>&1; then
    pass "worker-notify.sh foreground run exits 0"
else
    fail "worker-notify.sh foreground run failed (see $OUT_DIR/notify-foreground.log)"
fi
check "fake codex received a queue call" grep -q '^queue --thread smoke-thread --message' "$OUT_DIR/fake-codex-calls.log"
check "queued message mentions the task" grep -q 'OFF2' "$OUT_DIR/fake-codex-calls.log"

# unreachable session -> NOTIFY_FAILED.md + non-zero worker code propagates
cat >"$repo/.fake-codex-fail" <<'FAKEEOF'
#!/usr/bin/env bash
exit 1
FAKEEOF
chmod +x "$repo/.fake-codex-fail"
rm -f "$repo/.agent/current/NOTIFY_FAILED.md"
NF_RC=0
(cd "$repo" && WORKER_NOTIFY_RUN_WORKER="$repo/.fake-worker.sh" "$NOTIFY" \
    --foreground --codex-thread "smoke-thread" --codex-bin "$repo/.fake-codex-fail" \
    --mode implement --task-id OFF2) >"$OUT_DIR/notify-fail.log" 2>&1 || NF_RC=$?
check_eq "undelivered wake-up -> exit 15" "15" "$NF_RC"
check "failed wake-up writes NOTIFY_FAILED.md" test -s "$repo/.agent/current/NOTIFY_FAILED.md"
check "NOTIFY_FAILED.md contains the message" grep -q '\[worker-notify\]' "$repo/.agent/current/NOTIFY_FAILED.md"

# archived/failed queue output must add a remediation hint
cat >"$repo/.fake-codex-archived" <<'FAKEEOF'
#!/usr/bin/env bash
echo "Error: failed to queue session message: session abc is archived. Run 'codex unarchive abc' first." >&2
exit 1
FAKEEOF
chmod +x "$repo/.fake-codex-archived"
rm -f "$repo/.agent/current/NOTIFY_FAILED.md"
(cd "$repo" && WORKER_NOTIFY_RUN_WORKER="$repo/.fake-worker.sh" "$NOTIFY" \
    --foreground --codex-thread "smoke-thread" --codex-bin "$repo/.fake-codex-archived" \
    --mode implement --task-id OFF2) >"$OUT_DIR/notify-archived.log" 2>&1 || true
check "archived session produces a hint" grep -q 'hint: .*archived' "$repo/.agent/current/NOTIFY_FAILED.md"

# detached launch returns immediately and the background job still notifies
rm -f "$OUT_DIR/fake-codex-calls.log"
if (cd "$repo" && WORKER_NOTIFY_RUN_WORKER="$repo/.fake-worker.sh" "$NOTIFY" \
        --codex-thread "smoke-thread" --codex-bin "$repo/.fake-codex" \
        --mode implement --task-id OFF2) >"$OUT_DIR/notify-detach.log" 2>&1; then
    pass "worker-notify.sh detached launch exits 0"
else
    fail "worker-notify.sh detached launch failed"
fi
check "detached launch reports a pid" grep -q 'background worker started (pid' "$OUT_DIR/notify-detach.log"
detached_ok=0
i=0
while [[ "$i" -lt 10 ]]; do
    if grep -q '^queue --thread smoke-thread' "$OUT_DIR/fake-codex-calls.log" 2>/dev/null; then detached_ok=1; break; fi
    sleep 1
    i=$((i + 1))
done
if [[ "$detached_ok" -eq 1 ]]; then
    pass "detached worker notified Codex in the background"
else
    fail "detached worker did not notify within 10s"
fi

# --- 6c. worker-notify.sh --phase message wording ---------------------------------
phase_msg() {  # phase_msg <exit-code> -> file
    local rc="$1"
    (cd "$repo" && WORKER_NOTIFY_RUN_PHASE="$RUN_PHASE" "$NOTIFY" --phase --print-message --simulate-exit "$rc") \
        >"$OUT_DIR/notify-phase-msg-${rc}.log" 2>&1 || true
}
phase_msg 0
phase_msg 2
phase_msg 3
phase_msg 4
phase_msg 99
check "phase wake-up: phase-review wording" grep -q 'awaiting_phase_review' "$OUT_DIR/notify-phase-msg-0.log"
check "phase wake-up: review is Phase-level" grep -q 'Phase 级 integration review' "$OUT_DIR/notify-phase-msg-0.log"
check "phase wake-up: checkpoint wording" grep -q 'checkpoint' "$OUT_DIR/notify-phase-msg-2.log"
check "phase wake-up: escalation wording" grep -q 'escalation' "$OUT_DIR/notify-phase-msg-3.log"
check "phase wake-up: human gate wording" grep -q 'awaiting_human_qa' "$OUT_DIR/notify-phase-msg-4.log"
check "phase wake-up: does not ask for a per-Task review" bash -c "! grep -q '下一个 Task' '$OUT_DIR/notify-phase-msg-0.log'"
check "phase wake-up: says no polling is needed" grep -q '无需轮询' "$OUT_DIR/notify-phase-msg-0.log"
check "phase wake-up: an unexpected exit still produces a message" grep -q 'exit=99' "$OUT_DIR/notify-phase-msg-99.log"
check "phase wake-up: the unexpected branch names the state file" grep -q 'RUN_STATE.json' "$OUT_DIR/notify-phase-msg-99.log"
check "task wake-up: points a whole-Phase user at --phase" grep -q -- '--phase' "$OUT_DIR/notify-msg-0.log"

# ---------------------------------------------------------------------------
# 6d. session identity: explicit only, fail closed
# ---------------------------------------------------------------------------
FAKE_HOME="$repo/.fake-codex-home"
mkdir -p "$FAKE_HOME"
sqlite3 "$FAKE_HOME/state_5.sqlite" \
    "CREATE TABLE threads(id TEXT, archived INTEGER, cwd TEXT, title TEXT, updated_at INTEGER);"
sqlite3 "$FAKE_HOME/state_5.sqlite" \
    "INSERT INTO threads VALUES ('sess-ok',0,'/tmp/p','ok',1), ('sess-archived',1,'/tmp/a','arch',2);"

NOTIFY_HOME_TEST() {
    (cd "$repo" && WORKER_NOTIFY_CODEX_HOME="$FAKE_HOME" "$@")
}

N_RC=0
NOTIFY_HOME_TEST env -u CODEX_THREAD_ID "$NOTIFY" --print-target >"$OUT_DIR/target-none.log" 2>&1 || N_RC=$?
check_eq "identity: no CODEX_THREAD_ID and no flag -> exit 1" "1" "$N_RC"
check "identity: refusal message is explicit" grep -q 'no target' "$OUT_DIR/target-none.log"

N_RC=0
NOTIFY_HOME_TEST "$NOTIFY" --print-target --codex-thread sess-ok >"$OUT_DIR/target-flag.log" 2>&1 || N_RC=$?
check_eq "identity: explicit --codex-thread is used" "0" "$N_RC"
check "identity: prints the explicit target" grep -q '^sess-ok' "$OUT_DIR/target-flag.log"

N_RC=0
NOTIFY_HOME_TEST env CODEX_THREAD_ID=sess-ok "$NOTIFY" --print-target >"$OUT_DIR/target-env.log" 2>&1 || N_RC=$?
check_eq "identity: CODEX_THREAD_ID is honored" "0" "$N_RC"

N_RC=0
NOTIFY_HOME_TEST "$NOTIFY" --print-target --codex-thread sess-archived >"$OUT_DIR/target-arch.log" 2>&1 || N_RC=$?
check_eq "identity: archived target -> exit 3" "3" "$N_RC"
check "identity: archived hint present" grep -q 'ARCHIVED' "$OUT_DIR/target-arch.log"

rm -f "$repo/.agent/current/RESULT.md"
N_RC=0
NOTIFY_HOME_TEST env -u CODEX_THREAD_ID "$NOTIFY" --mode implement --task-id OFF2 >"$OUT_DIR/notify-no-target.log" 2>&1 || N_RC=$?
check_eq "worker-notify: no target -> exit 14 (refusing to guess)" "14" "$N_RC"
check "worker-notify: refusal is explicit" grep -q 'refusing to guess' "$OUT_DIR/notify-no-target.log"

(NOTIFY_HOME_TEST "$NOTIFY" --print-message --simulate-exit 0 --task-id OFF2) >"$OUT_DIR/notify-msg-0.log" 2>&1 || true
(NOTIFY_HOME_TEST "$NOTIFY" --print-message --simulate-exit 0 --task-id OFF2) >"$OUT_DIR/notify-msg-0.log" 2>&1 || true
(NOTIFY_HOME_TEST "$NOTIFY" --print-message --simulate-exit 5 --task-id OFF2) >"$OUT_DIR/notify-msg-5.log" 2>&1 || true
(NOTIFY_HOME_TEST "$NOTIFY" --print-message --simulate-exit 6 --task-id OFF2) >"$OUT_DIR/notify-msg-6.log" 2>&1 || true
(NOTIFY_HOME_TEST "$NOTIFY" --print-message --simulate-exit 7 --task-id OFF2) >"$OUT_DIR/notify-msg-7.log" 2>&1 || true
(NOTIFY_HOME_TEST "$NOTIFY" --print-message --simulate-exit 10 --task-id OFF2) >"$OUT_DIR/notify-msg-10.log" 2>&1 || true
(NOTIFY_HOME_TEST "$NOTIFY" --print-message --simulate-exit 2 --task-id OFF2) >"$OUT_DIR/notify-msg-2.log" 2>&1 || true
check "task wake-up: mentions the evidence gate" grep -q 'VERIFY.md' "$OUT_DIR/notify-msg-0.log"
check "exit 5 asks to read the existing RESULT" grep -q '有 RESULT.md' "$OUT_DIR/notify-msg-5.log"
check "exit 6 asks to inspect current/ and attempts/" grep -q 'attempts' "$OUT_DIR/notify-msg-6.log"
check "exit 7 says a worker is already running" grep -q '已有 worker' "$OUT_DIR/notify-msg-7.log"
check "escalation message asks for a decision" grep -q '决策' "$OUT_DIR/notify-msg-10.log"
check "escalation message names the Class" grep -q 'Class' "$OUT_DIR/notify-msg-10.log"
check "failure (no report) message says so" grep -q '无报告' "$OUT_DIR/notify-msg-2.log"

# ---------------------------------------------------------------------------
# 6e. run-worker.sh safety harness (fake opencode, offline)
# ---------------------------------------------------------------------------
HARNESS="$repo/.harness"
make_fake_bin "$HARNESS/bin" >/dev/null

hrepo="$(new_repo smoke-harness)"
CLEANUP_DIRS+=("$hrepo")
write_task "$hrepo" "H01" "implement" "harness objective" "existing behavior" "desired behavior" \
    "- app.py" "- app.py" "- any other file" "- [ ] works" '`python3 app.py` exits 0' "none"
printf 'print("hi")\n' >"$hrepo/app.py"
commit_all "$hrepo" "harness baseline"
HROOT="$(cd "$hrepo" && pwd -P)"
HRUN="$WORKER"

run_fake() {  # run_fake <mode> <exit> [args...] -> sets FAKE_RC
    local mode="$1" xc="$2"; shift 2
    FAKE_RC=0
    ( cd "$hrepo" && PATH="$HARNESS/bin:$PATH" \
        FAKE_OPENCODE_MODE="$mode" FAKE_OPENCODE_EXIT="$xc" \
        FAKE_TASK_ID="H01" FAKE_OPENCODE_CWD_LOG="$HARNESS/cwd.log" \
        "$HRUN" "$@" ) >"$OUT_DIR/fake-run.log" 2>&1 || FAKE_RC=$?
}

run_fake result 0 --allow-dirty --mode implement
check_eq "harness: valid RESULT -> exit 0" "0" "$FAKE_RC"
check "harness: STATE says result_written" grep -q '"status": "result_written"' "$hrepo/.agent/current/STATE.json"
check "harness: report is kept in current/" test -s "$hrepo/.agent/current/RESULT.md"
check "harness: BASELINE.md written" test -s "$hrepo/.agent/current/BASELINE.md"
check_eq "harness: opencode ran with cwd = project root" "$HROOT" "$(tail -1 "$HARNESS/cwd.log")"

run_fake wrong-id 0 --allow-dirty --mode implement
check_eq "harness: RESULT for another Task -> exit 6" "6" "$FAKE_RC"

run_fake invalid 0 --allow-dirty --mode implement
check_eq "harness: RESULT without Status -> exit 6" "6" "$FAKE_RC"

run_fake escalation 0 --allow-dirty --mode implement
check_eq "harness: valid ESCALATION -> exit 10" "10" "$FAKE_RC"

run_fake both 0 --allow-dirty --mode implement
check_eq "harness: both reports -> exit 4" "4" "$FAKE_RC"

run_fake result 9 --allow-dirty --mode implement
check_eq "harness: RESULT after opencode failure -> exit 5" "5" "$FAKE_RC"

# a pre-existing report must be quarantined, never accepted
cat >"$hrepo/.agent/current/RESULT.md" <<'EOF'
# Result

## Task ID
H01

## Status
DONE

## Summary
stale report from an earlier attempt
EOF
touch -t 202001010000 "$hrepo/.agent/current/RESULT.md"
run_fake none 0 --allow-dirty --mode implement
check_eq "harness: stale report quarantined, no report -> exit 3" "3" "$FAKE_RC"
check "harness: stale report moved to attempts/" bash -c "grep -rl 'stale report from an earlier attempt' '$hrepo/.agent/history/attempts' >/dev/null 2>&1"
check "harness: current/RESULT.md is gone" bash -c "! test -e '$hrepo/.agent/current/RESULT.md'"

# single-run lock identity
sleep 30 &
LOCKER=$!
mkdir -p "$hrepo/.agent/current/.worker.lock"
printf 'pid=%s\nworker_pid=\nrun_id=live\n' "$LOCKER" >"$hrepo/.agent/current/.worker.lock/info"
run_fake result 0 --allow-dirty --mode implement
check_eq "harness: live wrapper lock refuses a second worker -> exit 7" "7" "$FAKE_RC"
kill "$LOCKER" 2>/dev/null || true
wait "$LOCKER" 2>/dev/null || true

# dead wrapper but a recorded live worker pid must still refuse
sleep 30 &
SURVIVOR=$!
printf 'pid=999999\nworker_pid=%s\nrun_id=survivor\n' "$SURVIVOR" >"$hrepo/.agent/current/.worker.lock/info"
run_fake result 0 --allow-dirty --mode implement
check_eq "harness: dead wrapper + live worker pid -> exit 7" "7" "$FAKE_RC"
kill "$SURVIVOR" 2>/dev/null || true
wait "$SURVIVOR" 2>/dev/null || true

# no live pid at all: never taken over automatically (fail closed)
printf 'pid=999999\nworker_pid=999998\nrun_id=dead\n' >"$hrepo/.agent/current/.worker.lock/info"
run_fake result 0 --allow-dirty --mode implement
check_eq "harness: unprovable stale lock -> exit 8" "8" "$FAKE_RC"
check "harness: exit 8 explains --break-lock" grep -q -- '--break-lock' "$OUT_DIR/fake-run.log"

# cancellation must KEEP the lock until execution is proven stopped
SLOWBIN="$HARNESS/slowbin"
make_fake_bin "$SLOWBIN" >/dev/null
PIDLOG="$HARNESS/slow.pids"
RELEASE="$HARNESS/slow.release"
rm -f "$PIDLOG" "$RELEASE"
rm -rf "$hrepo/.agent/current/.worker.lock"
( cd "$hrepo" && exec env PATH="$SLOWBIN:$PATH" FAKE_OPENCODE_MODE=result FAKE_TASK_ID=H01 \
    FAKE_OPENCODE_PID_LOG="$PIDLOG" FAKE_OPENCODE_WAIT_FILE="$RELEASE" \
    "$HRUN" --allow-dirty --mode implement ) >"$OUT_DIR/sigterm-first.log" 2>&1 &
WRAPPER=$!
i=0
while [[ ! -s "$PIDLOG" && "$i" -lt 100 ]]; do sleep 0.1; i=$((i + 1)); done
if [[ -s "$PIDLOG" ]]; then
    pass "SIGTERM fixture: the slow worker actually started"
else
    fail "SIGTERM fixture: the slow worker never started"
fi
kill -TERM "$WRAPPER" 2>/dev/null || true
SIGRC=0
wait "$WRAPPER" || SIGRC=$?
check_eq "wrapper exits 130 after SIGTERM" "130" "$SIGRC"
check "the lock is RETAINED after SIGTERM" test -d "$hrepo/.agent/current/.worker.lock"
check "lock info records the cancellation" grep -q '^cancelled_by=TERM' "$hrepo/.agent/current/.worker.lock/info"
run_fake result 0 --allow-dirty --mode implement
check_eq "run after SIGTERM refuses without --break-lock -> exit 8" "8" "$FAKE_RC"
run_fake result 0 --allow-dirty --mode implement --break-lock
check_eq "--break-lock after verification proceeds -> exit 0" "0" "$FAKE_RC"
check "stale lock moved aside" bash -c "ls -d '$hrepo'/.agent/history/attempts/stale-locks/* >/dev/null 2>&1"
check "lock released after a normal run" bash -c "! test -e '$hrepo/.agent/current/.worker.lock'"
touch "$RELEASE" 2>/dev/null || true
if [[ -s "$PIDLOG" ]]; then
    while IFS= read -r p; do kill -TERM "$p" 2>/dev/null || true; done <"$PIDLOG"
fi

# TASK.md validation
cp "$hrepo/.agent/current/TASK.md" "$HARNESS/TASK.good"
printf '# Task\n\n## Task ID\nH01\n\n## Mode\nimplement\n' >"$hrepo/.agent/current/TASK.md"
run_fake result 0 --allow-dirty --mode implement
check_eq "harness: incomplete TASK.md -> exit 1" "1" "$FAKE_RC"
cp "$HARNESS/TASK.good" "$hrepo/.agent/current/TASK.md"
run_fake result 0 --allow-dirty --mode implement --task-id OTHER
check_eq "harness: --task-id mismatch -> exit 1" "1" "$FAKE_RC"
run_fake result 0 --allow-dirty --mode verify
check_eq "harness: --mode mismatch -> exit 1" "1" "$FAKE_RC"

# template list placeholders are still placeholders
cp "$HARNESS/TASK.good" "$hrepo/.agent/current/TASK.md"
sed -i '' 's/^- \[ \] works$/- [ ] <observable, checkable criterion>/' "$hrepo/.agent/current/TASK.md"
run_fake result 0 --allow-dirty --mode implement
check_eq "harness: list placeholders rejected -> exit 1" "1" "$FAKE_RC"
check "harness: placeholder message names the section" grep -q 'placeholder' "$OUT_DIR/fake-run.log"
cp "$HARNESS/TASK.good" "$hrepo/.agent/current/TASK.md"

# REVIEW.md without a Task ID is rejected
cat >"$hrepo/.agent/current/REVIEW.md" <<'EOF'
# Review

## Decision
REWORK

## Required Corrections
- fix it
EOF
run_fake result 0 --allow-dirty --mode implement
check_eq "harness: REVIEW.md without Task ID -> exit 1" "1" "$FAKE_RC"
check "harness: REVIEW message is explicit" grep -q 'REVIEW.md has no' "$OUT_DIR/fake-run.log"
rm -f "$hrepo/.agent/current/REVIEW.md"

# dirty tree handling + baseline evidence
printf 'print("local change")\n' >>"$hrepo/app.py"
run_fake result 0 --mode implement
check_eq "harness: dirty tree without --allow-dirty -> exit 1" "1" "$FAKE_RC"
run_fake result 0 --allow-dirty --mode implement
check_eq "harness: dirty tree with --allow-dirty -> exit 0" "0" "$FAKE_RC"
check "harness: BASELINE.md lists the dirty file" grep -q 'M app.py' "$hrepo/.agent/current/BASELINE.md"
check_commit "harness: BASELINE.patch holds the full pre-run patch" grep -q 'local change' "$hrepo/.agent/current/BASELINE.patch"

# cwd pinning when invoked from elsewhere
OTHER="$(new_repo smoke-caller)"
CLEANUP_DIRS+=("$OTHER")
rm -f "$HARNESS/cwd.log"
FAKE_RC=0
( cd "$OTHER" && PATH="$HARNESS/bin:$PATH" \
    FAKE_OPENCODE_MODE="result" FAKE_OPENCODE_EXIT=0 \
    FAKE_TASK_ID="H01" FAKE_OPENCODE_CWD_LOG="$HARNESS/cwd.log" \
    "$HRUN" --root "$hrepo" --allow-dirty --mode implement ) >"$OUT_DIR/fake-run2.log" 2>&1 || FAKE_RC=$?
check_eq "harness: --root run succeeds from another directory" "0" "$FAKE_RC"
check_eq "harness: opencode still ran in the project root" "$HROOT" "$(tail -1 "$HARNESS/cwd.log")"

# ---------------------------------------------------------------------------
# 7. THE PHASE LOOP (offline, fake worker): scenarios A-F
# ---------------------------------------------------------------------------
FAKEBIN="$repo/.fakebin"
make_fake_bin "$FAKEBIN" >/dev/null

# --- A: three low-risk Tasks auto-continue, one session per Task -------------
info "phase loop A: auto-continue over three Tasks"
AREPO="$(new_repo smoke-loop-a)"
CLEANUP_DIRS+=("$AREPO")
AFIX="$(mktemp -d "$TMP_BASE/smoke-fix-a.XXXXXX")"
CLEANUP_DIRS+=("$AFIX")
printf 'def uppercase(s):\n    return s.upper()\n' >"$AREPO/app.py"
write_phase_md "$AREPO" "A"
write_run_state "$AREPO" "A" "idle" >/dev/null
Q="$AFIX/tasks.jsonl"
queue_task_json A01 "add shutdown" low pending "grep -q 'def shutdown' app.py" "app.py" >>"$Q"
queue_task_json A02 "add farewell" low pending "grep -q 'def farewell' app.py" "app.py" >>"$Q"
queue_task_json A03 "add docs" low pending "grep -q 'def farewell' app.py" "app.py, README.md" >>"$Q"
write_queue "$AREPO" "A" "$Q" "grep -q 'def shutdown' app.py && grep -q 'def farewell' app.py"
cat >"$AFIX/A01.sh" <<'EOF'
printf '\n\ndef shutdown(seconds):\n    return "bye"\n' >> app.py
EOF
cat >"$AFIX/A02.sh" <<'EOF'
printf '\n\ndef farewell(name):\n    return "bye, %s" % name\n' >> app.py
EOF
cat >"$AFIX/A03.sh" <<'EOF'
printf '# Fixture docs\n' >> README.md
EOF
commit_all "$AREPO" "loop A fixture"
CWDLOG="$OUT_DIR/loop-a-cwd.log"
: >"$CWDLOG"
LAST_EXIT=0
( cd "$AREPO" && PATH="$FAKEBIN:$PATH" FAKE_OPENCODE_MODE=script \
    FAKE_OPENCODE_SCRIPT="$SMOKE_DIR/assets/fake-task.sh" \
    FAKE_TASK_DIR="$AFIX" FAKE_OPENCODE_CWD_LOG="$CWDLOG" \
    "$RUN_PHASE" ) >"$OUT_DIR/loop-a.log" 2>&1 || LAST_EXIT=$?
check_eq "A: loop completed the phase -> exit 0" "0" "$LAST_EXIT"
check_eq "A: one OpenCode session per Task" "3" "$(grep -c . "$CWDLOG")"
check "A: all three Tasks are done" bash -c \
    "jq -e '[.tasks[] | select(.status==\"done\")] | length == 3' '$AREPO/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "A: every Task has an ACCEPT history entry" bash -c \
    "jq -e '[.tasks[] | select((.history | map(.decision) | index(\"ACCEPT\")) == null)] | length == 0' '$AREPO/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "A: three archives exist" bash -c "[ \"\$(ls -d '$AREPO'/.agent/history/*A0[0-9] 2>/dev/null | wc -l | tr -d ' ')\" = 3 ]"
check "A: the loop never stopped mid-phase" bash -c "! grep -q 'STOP (' '$OUT_DIR/loop-a.log'"
check "A: three worker runs finished cleanly" bash -c "[ \"\$(grep -c 'worker exit=0' '$OUT_DIR/loop-a.log')\" = 3 ]"
check "A: the Phase verification ran for real" grep -q 'PASS (exit 0)' "$AREPO/.agent/phases/A/PHASE_REVIEW.md"
check "A: evidence per Task was kept in the phase history" bash -c "test -s '$AREPO/.agent/phases/A/history/VERIFY-A02.md'"
check "A: the rendered Task was kept in the phase history" bash -c "test -s '$AREPO/.agent/phases/A/history/TASK-A01.md'"
check "A: state is awaiting_phase_review (D)" bash -c "jq -e '.status == \"awaiting_phase_review\"' '$AREPO/.agent/RUN_STATE.json' >/dev/null"
check "A: stop_reason is phase_complete" bash -c "jq -e '.stop_reason == \"phase_complete\"' '$AREPO/.agent/RUN_STATE.json' >/dev/null"
check "A: the queue is done" bash -c "jq -e '.status == \"done\"' '$AREPO/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "A: no phase lock is left behind" bash -c "! test -e '$AREPO/.agent/current/.phase.lock'"
check "A: no ESCALATION stays behind" bash -c "! test -s '$AREPO/.agent/current/ESCALATION.md'"
check "A: the Phase was NOT followed by another phase" bash -c "! test -d '$AREPO/.agent/phases/B'"

# --- B: a guarded Task stops the loop ----------------------------------------
info "phase loop B: checkpoint (guarded Task and worker CHECKPOINT)"
BREPO="$(new_repo smoke-loop-b)"
CLEANUP_DIRS+=("$BREPO")
BFIX="$(mktemp -d "$TMP_BASE/smoke-fix-b.XXXXXX")"
CLEANUP_DIRS+=("$BFIX")
printf 'def uppercase(s):\n    return s.upper()\n' >"$BREPO/app.py"
write_phase_md "$BREPO" "A"
write_run_state "$BREPO" "A" "idle" >/dev/null
QB="$BFIX/tasks.jsonl"
queue_task_json B01 "change the public API" guarded pending "grep -q 'def api2' app.py" "app.py" >>"$QB"
queue_task_json B02 "must not run yet" low pending "grep -q 'def b02' app.py" "app.py" >>"$QB"
write_queue "$BREPO" "A" "$QB" "grep -q 'def api2' app.py"
cat >"$BFIX/B01.sh" <<'EOF'
printf '\n\ndef api2():\n    return 2\n' >> app.py
EOF
cat >"$BFIX/B02.sh" <<'EOF'
printf '\n\ndef b02():\n    return 2\n' >> app.py
EOF
commit_all "$BREPO" "loop B fixture"
LAST_EXIT=0
( cd "$BREPO" && PATH="$FAKEBIN:$PATH" FAKE_OPENCODE_MODE=script \
    FAKE_OPENCODE_SCRIPT="$SMOKE_DIR/assets/fake-task.sh" FAKE_TASK_DIR="$BFIX" \
    "$RUN_PHASE" ) >"$OUT_DIR/loop-b-guarded.log" 2>&1 || LAST_EXIT=$?
check_eq "B: guarded Task stops the loop -> exit 2" "2" "$LAST_EXIT"
check "B: the guarded Task was accepted and archived" bash -c \
    "jq -e '[.tasks[] | select(.id==\"B01\")][0].status == \"done\"' '$BREPO/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "B: the NEXT Task was NOT started" bash -c \
    "jq -e '[.tasks[] | select(.id==\"B02\")][0].status == \"pending\"' '$BREPO/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "B: state is checkpoint" bash -c "jq -e '.status == \"checkpoint\"' '$BREPO/.agent/RUN_STATE.json' >/dev/null"
check "B: stop_reason names the guarded Task" bash -c "jq -e '.stop_reason == \"guarded_task_review\"' '$BREPO/.agent/RUN_STATE.json' >/dev/null"

# worker CHECKPOINT: the loop stops and the Task stays in_progress
CFIX2="$(mktemp -d "$TMP_BASE/smoke-fix-b2.XXXXXX")"
CLEANUP_DIRS+=("$CFIX2")
printf 'CHECKPOINT\n' >"$CFIX2/B02.escalation"
LAST_EXIT=0
( cd "$BREPO" && PATH="$FAKEBIN:$PATH" FAKE_OPENCODE_MODE=script \
    FAKE_OPENCODE_SCRIPT="$SMOKE_DIR/assets/fake-task.sh" FAKE_TASK_DIR="$CFIX2" \
    "$RUN_PHASE" ) >"$OUT_DIR/loop-b-checkpoint.log" 2>&1 || LAST_EXIT=$?
check_eq "B: worker CHECKPOINT stops the loop -> exit 2" "2" "$LAST_EXIT"
check "B: state is checkpoint" bash -c "jq -e '.status == \"checkpoint\"' '$BREPO/.agent/RUN_STATE.json' >/dev/null"
check "B: stop_reason is worker_checkpoint" bash -c "jq -e '.stop_reason == \"worker_checkpoint\"' '$BREPO/.agent/RUN_STATE.json' >/dev/null"
check "B: the Task stays in_progress for the resume" bash -c \
    "jq -e '[.tasks[] | select(.id==\"B02\")][0].status == \"in_progress\"' '$BREPO/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "B: the worker report is kept for Codex" test -s "$BREPO/.agent/current/ESCALATION.md"
(cd "$BREPO" && "$CHECK_STATE") >"$OUT_DIR/cs-loop-b.log" 2>&1 || true
check "B: check-state verdict is CHECKPOINT" grep -q 'verdict: CHECKPOINT' "$OUT_DIR/cs-loop-b.log"
check "B: check-state points at the decision" grep -q 'Codex decision needed' "$OUT_DIR/cs-loop-b.log"

# --- C: an ESCALATE stops the loop and blocks further runs -------------------
info "phase loop C: escalation"
DREPO="$(new_repo smoke-loop-c)"
CLEANUP_DIRS+=("$DREPO")
DFIX="$(mktemp -d "$TMP_BASE/smoke-fix-c.XXXXXX")"
CLEANUP_DIRS+=("$DFIX")
printf 'def uppercase(s):\n    return s.upper()\n' >"$DREPO/app.py"
write_phase_md "$DREPO" "A"
write_run_state "$DREPO" "A" "idle" >/dev/null
QD="$DFIX/tasks.jsonl"
queue_task_json C01 "contradictory Task" low pending "grep -q 'def c01' app.py" "app.py" >>"$QD"
queue_task_json C02 "must not run" low pending "grep -q 'def c02' app.py" "app.py" >>"$QD"
write_queue "$DREPO" "A" "$QD" "grep -q 'def c01' app.py"
printf 'ESCALATE\n' >"$DFIX/C01.escalation"
commit_all "$DREPO" "loop C fixture"
LAST_EXIT=0
( cd "$DREPO" && PATH="$FAKEBIN:$PATH" FAKE_OPENCODE_MODE=script \
    FAKE_OPENCODE_SCRIPT="$SMOKE_DIR/assets/fake-task.sh" FAKE_TASK_DIR="$DFIX" \
    "$RUN_PHASE" ) >"$OUT_DIR/loop-c.log" 2>&1 || LAST_EXIT=$?
check_eq "C: escalation stops the loop -> exit 3" "3" "$LAST_EXIT"
check "C: state is escalated" bash -c "jq -e '.status == \"escalated\"' '$DREPO/.agent/RUN_STATE.json' >/dev/null"
check "C: stop_reason is worker_escalation" bash -c "jq -e '.stop_reason == \"worker_escalation\"' '$DREPO/.agent/RUN_STATE.json' >/dev/null"
check "C: the Task is escalated in the queue" bash -c \
    "jq -e '[.tasks[] | select(.id==\"C01\")][0].status == \"escalated\"' '$DREPO/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "C: the next Task was not started" bash -c \
    "jq -e '[.tasks[] | select(.id==\"C02\")][0].status == \"pending\"' '$DREPO/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
LAST_EXIT=0
( cd "$DREPO" && PATH="$FAKEBIN:$PATH" FAKE_OPENCODE_MODE=script \
    FAKE_OPENCODE_SCRIPT="$SMOKE_DIR/assets/fake-task.sh" FAKE_TASK_DIR="$DFIX" \
    "$RUN_PHASE" ) >"$OUT_DIR/loop-c-rerun.log" 2>&1 || LAST_EXIT=$?
check_eq "C: an escalated Task blocks the loop -> exit 3" "3" "$LAST_EXIT"
check "C: the refusal names the escalated Task" grep -q 'escalated' "$OUT_DIR/loop-c-rerun.log"
check "C: check-state also says ESCALATED" bash -c "cd '$DREPO' && '$CHECK_STATE' 2>&1 | grep -q 'verdict: ESCALATED'"

# --- D: a failing Phase verification is a checkpoint, not a pass --------------
info "phase loop D: failing Phase verification"
EREPO="$(new_repo smoke-loop-d)"
CLEANUP_DIRS+=("$EREPO")
EFIX="$(mktemp -d "$TMP_BASE/smoke-fix-d.XXXXXX")"
CLEANUP_DIRS+=("$EFIX")
printf 'def uppercase(s):\n    return s.upper()\n' >"$EREPO/app.py"
write_phase_md "$EREPO" "A"
write_run_state "$EREPO" "A" "idle" >/dev/null
QE="$EFIX/tasks.jsonl"
queue_task_json D01 "add a helper" low pending "grep -q 'def helper' app.py" "app.py" >>"$QE"
write_queue "$EREPO" "A" "$QE" "grep -q 'def never_added' app.py"
cat >"$EFIX/D01.sh" <<'EOF'
printf '\n\ndef helper():\n    return 1\n' >> app.py
EOF
commit_all "$EREPO" "loop D fixture"
LAST_EXIT=0
( cd "$EREPO" && PATH="$FAKEBIN:$PATH" FAKE_OPENCODE_MODE=script \
    FAKE_OPENCODE_SCRIPT="$SMOKE_DIR/assets/fake-task.sh" FAKE_TASK_DIR="$EFIX" \
    "$RUN_PHASE" ) >"$OUT_DIR/loop-d.log" 2>&1 || LAST_EXIT=$?
check_eq "D: failing Phase verification -> exit 2 (checkpoint)" "2" "$LAST_EXIT"
check "D: state is checkpoint, not phase review" bash -c "jq -e '.status == \"checkpoint\"' '$EREPO/.agent/RUN_STATE.json' >/dev/null"
check "D: stop_reason is phase_verification_failed" bash -c "jq -e '.stop_reason == \"phase_verification_failed\"' '$EREPO/.agent/RUN_STATE.json' >/dev/null"
check "D: the Phase verification evidence records the FAIL" grep -q '^FAIL' "$EREPO/.agent/phases/A/PHASE_REVIEW.md"
check "D: the Task itself was accepted" bash -c \
    "jq -e '[.tasks[] | select(.id==\"D01\")][0].status == \"done\"' '$EREPO/.agent/phases/A/TASK_QUEUE.json' >/dev/null"

# --- E: the review gate and the human gate -----------------------------------
info "phase loop E: phase review + human QA gates"
LAST_EXIT=0
( cd "$AREPO" && "$RUN_PHASE" ) >"$OUT_DIR/loop-e-refuse.log" 2>&1 || LAST_EXIT=$?
check_eq "E: the loop refuses to run at awaiting_phase_review -> exit 4" "4" "$LAST_EXIT"
check "E: the refusal explains the review gate" grep -q 'phase review' "$OUT_DIR/loop-e-refuse.log"
check "E: no Task ran again" bash -c "[ \"\$(ls -d '$AREPO'/.agent/history/*A0[0-9] 2>/dev/null | wc -l | tr -d ' ')\" = 3 ]"

# review-pass without a summary is refused
RG_RC=0
(cd "$AREPO" && "$PHASE_GATE" review-pass) >"$OUT_DIR/gate-no-summary.log" 2>&1 || RG_RC=$?
check_eq "E: review-pass without --summary -> exit 1" "1" "$RG_RC"
check "E: the refusal names the missing summary" grep -q 'summary' "$OUT_DIR/gate-no-summary.log"

# a review-pass with a failing phase verification must refuse and change nothing
jq '.phase_verification = [{"cmd":"grep -q def_never_there app.py","expect":"exit 0"}]' \
    "$AREPO/.agent/phases/A/TASK_QUEUE.json" >"$AREPO/.agent/phases/A/q.json" \
    && mv "$AREPO/.agent/phases/A/q.json" "$AREPO/.agent/phases/A/TASK_QUEUE.json"
RG_RC=0
(cd "$AREPO" && "$PHASE_GATE" review-pass --summary "fixture review") >"$OUT_DIR/gate-fail-verify.log" 2>&1 || RG_RC=$?
check_eq "E: review-pass with a failing verification -> exit 1" "1" "$RG_RC"
check "E: the state did not move to human QA" bash -c "jq -e '.status == \"awaiting_phase_review\"' '$AREPO/.agent/RUN_STATE.json' >/dev/null"
check "E: PHASE.md has no review Result yet" bash -c "! grep -q 'Reviewed by:' '$AREPO/.agent/phases/A/PHASE.md'"
jq '.phase_verification = [{"cmd":"grep -Eq \"def +farewell\" app.py","expect":"exit 0"}]' \
    "$AREPO/.agent/phases/A/TASK_QUEUE.json" >"$AREPO/.agent/phases/A/q.json" \
    && mv "$AREPO/.agent/phases/A/q.json" "$AREPO/.agent/phases/A/TASK_QUEUE.json"

# review-fail reopens the queue; the corrective Task runs; the Phase comes back
(cd "$AREPO" && "$PHASE_GATE" review-fail --reason "one criterion is not covered by a test") \
    >"$OUT_DIR/gate-review-fail.log" 2>&1 || fail "E: review-fail failed"
check "E: review-fail reopens the queue" bash -c "jq -e '.status == \"running\"' '$AREPO/.agent/RUN_STATE.json' >/dev/null"
check "E: review-fail records an adjustment" bash -c \
    "jq -e '[.adjustments[] | select(.reason | test(\"not covered\"))] | length == 1' '$AREPO/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "E: check-state reports the queue is complete" bash -c "cd '$AREPO' && '$CHECK_STATE' 2>&1 | grep -q 'verdict: QUEUE_COMPLETE'"

# Codex appends the corrective Task to the queue (the queue is Codex-owned)
FIX2="$(mktemp -d "$TMP_BASE/smoke-fix-e2.XXXXXX")"
CLEANUP_DIRS+=("$FIX2")
cat >"$FIX2/E01.sh" <<'EOF'
printf '\n\ndef e01()\n    return 1\n' >> app.py
EOF
jq '.tasks += [{
      "id": "E01", "title": "add the missing coverage", "mode": "implement", "risk": "low",
      "status": "pending", "objective": "add e01() and cover it", "context": "corrective Task after review-fail",
      "existing_behavior": "no e01()", "desired_behavior": "e01() exists",
      "relevant_files": ["app.py - fixture"], "allowed_changes": ["app.py"], "forbidden_changes": [],
      "acceptance_criteria": ["e01() exists"],
      "verification": [{"cmd": "grep -q \"def e01\" app.py", "expect": "exit 0"}],
      "escalation_conditions": [], "depends_on": [], "history": []
    }]' "$AREPO/.agent/phases/A/TASK_QUEUE.json" >"$AREPO/.agent/phases/A/q.json" \
    && mv "$AREPO/.agent/phases/A/q.json" "$AREPO/.agent/phases/A/TASK_QUEUE.json"
LAST_EXIT=0
( cd "$AREPO" && PATH="$FAKEBIN:$PATH" FAKE_OPENCODE_MODE=script \
    FAKE_OPENCODE_SCRIPT="$SMOKE_DIR/assets/fake-task.sh" FAKE_TASK_DIR="$FIX2" \
    "$RUN_PHASE" ) >"$OUT_DIR/loop-e-corrective.log" 2>&1 || LAST_EXIT=$?
check_eq "E: the corrective Task ran and the Phase returned to review -> exit 0" "0" "$LAST_EXIT"
check "E: the corrective Task is done" bash -c \
    "jq -e '[.tasks[] | select(.id==\"E01\")][0].status == \"done\"' '$AREPO/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "E: it stopped at the review gate again" bash -c "jq -e '.status == \"awaiting_phase_review\"' '$AREPO/.agent/RUN_STATE.json' >/dev/null"

(cd "$AREPO" && "$PHASE_GATE" review-pass --summary "reviewed the diff and re-ran the phase verification") \
    >"$OUT_DIR/gate-pass.log" 2>&1 || fail "E: review-pass failed (see $OUT_DIR/gate-pass.log)"
check "E: review-pass moved the state to awaiting_human_qa" bash -c "jq -e '.status == \"awaiting_human_qa\"' '$AREPO/.agent/RUN_STATE.json' >/dev/null"
check "E: the review is recorded" bash -c "jq -e '.phase_review == \"passed\"' '$AREPO/.agent/RUN_STATE.json' >/dev/null"
check "E: PHASE.md got the Result section" grep -q '^## Result' "$AREPO/.agent/phases/A/PHASE.md"
check "E: the review re-ran the phase verification" grep -q 'Phase review run' "$AREPO/.agent/phases/A/PHASE_REVIEW.md"

LAST_EXIT=0
( cd "$AREPO" && "$RUN_PHASE" ) >"$OUT_DIR/loop-e-human-gate.log" 2>&1 || LAST_EXIT=$?
check_eq "E: the loop refuses to run at awaiting_human_qa -> exit 4" "4" "$LAST_EXIT"
check "E: the refusal explains the human gate" grep -q 'human' "$OUT_DIR/loop-e-human-gate.log"
check "E: check-state says AWAITING_HUMAN_QA" bash -c "cd '$AREPO' && '$CHECK_STATE' 2>&1 | grep -q 'verdict: AWAITING_HUMAN_QA'"

# qa-fail reopens the queue; qa-pass (human confirmed) clears the gate
(cd "$AREPO" && "$PHASE_GATE" qa-fail --note "the human found a defect") >"$OUT_DIR/gate-qa-fail.log" 2>&1 \
    || fail "E: qa-fail failed"
check "E: qa-fail reopens the queue" bash -c "jq -e '.status == \"running\"' '$AREPO/.agent/RUN_STATE.json' >/dev/null"
check "E: qa-fail records an adjustment" bash -c \
    "jq -e '[.adjustments[] | select(.change | test(\"human QA\"))] | length == 1' '$AREPO/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
# the loop re-runs the Phase verification after a qa-fail and stops at the review gate
LAST_EXIT=0
( cd "$AREPO" && PATH="$FAKEBIN:$PATH" FAKE_OPENCODE_MODE=script \
    FAKE_OPENCODE_SCRIPT="$SMOKE_DIR/assets/fake-task.sh" FAKE_TASK_DIR="$FIX2" \
    "$RUN_PHASE" ) >"$OUT_DIR/loop-e-qafail.log" 2>&1 || LAST_EXIT=$?
check_eq "E: after qa-fail the loop returns to the review gate -> exit 0" "0" "$LAST_EXIT"
check "E: it is awaiting_phase_review again" bash -c "jq -e '.status == \"awaiting_phase_review\"' '$AREPO/.agent/RUN_STATE.json' >/dev/null"
(cd "$AREPO" && "$PHASE_GATE" review-pass --summary "re-reviewed after the human QA round") \
    >"$OUT_DIR/gate-pass2.log" 2>&1 || fail "E: the second review-pass failed"
(cd "$AREPO" && "$PHASE_GATE" qa-pass --note "the human confirmed") >"$OUT_DIR/gate-qa-pass.log" 2>&1 \
    || fail "E: qa-pass failed"
check "E: qa-pass records the verdict" bash -c "jq -e '.human_qa == \"passed\"' '$AREPO/.agent/RUN_STATE.json' >/dev/null"
check "E: qa-pass leaves the state idle (the next Phase is a new decision)" bash -c "jq -e '.status == \"idle\"' '$AREPO/.agent/RUN_STATE.json' >/dev/null"

# --- F: resume --------------------------------------------------------------
info "phase loop F: resume an interrupted Phase"
FREPO="$(new_repo smoke-loop-f)"
CLEANUP_DIRS+=("$FREPO")
FFIX="$(mktemp -d "$TMP_BASE/smoke-fix-f.XXXXXX")"
CLEANUP_DIRS+=("$FFIX")
printf 'def uppercase(s):\n    return s.upper()\n' >"$FREPO/app.py"
write_phase_md "$FREPO" "A"
write_run_state "$FREPO" "A" "running" >/dev/null
QF="$FFIX/tasks.jsonl"
queue_task_json F01 "already done" low done "grep -q 'def uppercase' app.py" "app.py" >>"$QF"
queue_task_json F02 "was interrupted" low in_progress "grep -q 'def f02' app.py" "app.py" >>"$QF"
write_queue "$FREPO" "A" "$QF" "grep -q 'def f02' app.py"
# The M03 window: the queue says in_progress but TASK.md is still the blank template.
mkdir -p "$FREPO/.agent/current"
cp "$PROJECT_ROOT/skills/cheap-worker/assets/templates/TASK.md" "$FREPO/.agent/current/TASK.md"
printf '{"task_id":"F02","run_id":"r1","status":"running"}' >"$FREPO/.agent/current/STATE.json"
# ... and a stale report left over from an older Task must not block the resume.
mkdir -p "$FREPO/.agent/phases/A/history"
cat >"$FREPO/.agent/current/ESCALATION.md" <<'EOF'
# Escalation

## Task ID
F00

## Class
CHECKPOINT

## Current Blocker
stale report from an earlier Task
EOF
cat >"$FFIX/F02.sh" <<'EOF'
printf '\n\ndef f02():\n    return 2\n' >> app.py
EOF
commit_all "$FREPO" "loop F fixture"
LAST_EXIT=0
( cd "$FREPO" && PATH="$FAKEBIN:$PATH" FAKE_OPENCODE_MODE=script \
    FAKE_OPENCODE_SCRIPT="$SMOKE_DIR/assets/fake-task.sh" FAKE_TASK_DIR="$FFIX" \
    "$RUN_PHASE" ) >"$OUT_DIR/loop-f.log" 2>&1 || LAST_EXIT=$?
check_eq "F: the loop resumed and finished -> exit 0" "0" "$LAST_EXIT"
check "F: it logged the resume" grep -q 'resumed=yes' "$OUT_DIR/loop-f.log"
check "F: F01 was never re-run" bash -c "! ls -d '$FREPO'/.agent/history/*F01 >/dev/null 2>&1"
check "F: F02 is done" bash -c \
    "jq -e '[.tasks[] | select(.id==\"F02\")][0].status == \"done\"' '$FREPO/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "F: the rebuilt TASK.md was archived in the phase history" bash -c "grep -q 'F02' '$FREPO/.agent/phases/A/history/TASK-F02.md'"
check "F: the stale report was quarantined" bash -c "grep -rl 'stale report from an earlier Task' '$FREPO/.agent/history/attempts' >/dev/null 2>&1"
check "F: state is awaiting_phase_review" bash -c "jq -e '.status == \"awaiting_phase_review\"' '$FREPO/.agent/RUN_STATE.json' >/dev/null"

# ---------------------------------------------------------------------------
# 7b. plan validation and the evidence gate
# ---------------------------------------------------------------------------
info "phase loop: plan validation and evidence gate"

# a Task without a verification command is not runnable
GREPO="$(new_repo smoke-loop-plan)"
CLEANUP_DIRS+=("$GREPO")
GFIX="$(mktemp -d "$TMP_BASE/smoke-fix-plan.XXXXXX")"
CLEANUP_DIRS+=("$GFIX")
printf 'def uppercase(s):\n    return s.upper()\n' >"$GREPO/app.py"
write_phase_md "$GREPO" "A"
write_run_state "$GREPO" "A" "idle" >/dev/null
QG="$GFIX/tasks.jsonl"
jq -nc '{id:"G01",title:"no verification",mode:"implement",risk:"low",status:"pending",
         objective:"x",context:"",existing_behavior:"",desired_behavior:"x",
         relevant_files:[],allowed_changes:["app.py"],forbidden_changes:[],
         acceptance_criteria:["must be observable"],verification:[],
         escalation_conditions:[],depends_on:[],history:[]}' >>"$QG"
write_queue "$GREPO" "A" "$QG" "true"
commit_all "$GREPO" "plan fixture"
LAST_EXIT=0
( cd "$GREPO" && PATH="$FAKEBIN:$PATH" FAKE_OPENCODE_MODE=script \
    FAKE_OPENCODE_SCRIPT="$SMOKE_DIR/assets/fake-task.sh" FAKE_TASK_DIR="$GFIX" \
    "$RUN_PHASE" ) >"$OUT_DIR/loop-plan.log" 2>&1 || LAST_EXIT=$?
check_eq "plan: a Task without verification -> exit 2 (checkpoint)" "2" "$LAST_EXIT"
check "plan: the reason names the verification requirement" grep -q 'verification' "$OUT_DIR/loop-plan.log"
check "plan: nothing ran" bash -c "! ls -d '$GREPO'/.agent/history/*G01 >/dev/null 2>&1"
check "plan: no log from a worker run" bash -c "! ls '$GREPO'/.agent/current/logs/worker-* >/dev/null 2>&1"

# evidence gate: an unticked criterion fails the Task
HREPO="$(new_repo smoke-loop-gate)"
CLEANUP_DIRS+=("$HREPO")
HFIX="$(mktemp -d "$TMP_BASE/smoke-fix-gate.XXXXXX")"
CLEANUP_DIRS+=("$HFIX")
printf 'def uppercase(s):\n    return s.upper()\n' >"$HREPO/app.py"
write_phase_md "$HREPO" "A"
write_run_state "$HREPO" "A" "idle" >/dev/null
QH="$HFIX/tasks.jsonl"
queue_task_json H01 "unticked criterion" low pending "grep -q 'def h01' app.py" "app.py" >>"$QH"
write_queue "$HREPO" "A" "$QH" "grep -q 'def h01' app.py"
cat >"$HFIX/H01.sh" <<'EOF'
printf '\n\ndef h01():\n    return 1\n' >> app.py
cat > .agent/current/RESULT.md <<'RESULT'
# Result

## Task ID
H01

## Status
DONE

## Summary
claims done but leaves a criterion unticked

## Acceptance Criteria
- [x] one thing - checked
- [ ] the other thing - not done

## Verification Performed
- `true` -> exit 0
RESULT
EOF
commit_all "$HREPO" "gate fixture"
LAST_EXIT=0
( cd "$HREPO" && PATH="$FAKEBIN:$PATH" FAKE_OPENCODE_MODE=script \
    FAKE_OPENCODE_SCRIPT="$SMOKE_DIR/assets/fake-task.sh" FAKE_TASK_DIR="$HFIX" \
    "$RUN_PHASE" ) >"$OUT_DIR/loop-gate-unticked.log" 2>&1 || LAST_EXIT=$?
check_eq "gate: an unticked criterion -> exit 3 (escalate)" "3" "$LAST_EXIT"
check "gate: VERIFY.md records the FAIL" grep -q '^FAIL' "$HREPO/.agent/current/VERIFY.md"
check "gate: the unticked criterion is named" grep -q 'unticked' "$HREPO/.agent/current/VERIFY.md"
check "gate: the Task was not archived" bash -c "! ls -d '$HREPO'/.agent/history/*H01 >/dev/null 2>&1"

# evidence gate: the re-run verification command fails
IREPO="$(new_repo smoke-loop-verify)"
CLEANUP_DIRS+=("$IREPO")
IFIX="$(mktemp -d "$TMP_BASE/smoke-fix-verify.XXXXXX")"
CLEANUP_DIRS+=("$IFIX")
printf 'def uppercase(s):\n    return s.upper()\n' >"$IREPO/app.py"
write_phase_md "$IREPO" "A"
write_run_state "$IREPO" "A" "idle" >/dev/null
QI="$IFIX/tasks.jsonl"
queue_task_json I01 "claims success without doing the work" low pending "grep -q 'def i01' app.py" "app.py" >>"$QI"
write_queue "$IREPO" "A" "$QI" "grep -q 'def i01' app.py"
commit_all "$IREPO" "verify fixture"
LAST_EXIT=0
( cd "$IREPO" && PATH="$FAKEBIN:$PATH" FAKE_OPENCODE_MODE=script \
    FAKE_OPENCODE_SCRIPT="$SMOKE_DIR/assets/fake-task.sh" FAKE_TASK_DIR="$IFIX" \
    "$RUN_PHASE" ) >"$OUT_DIR/loop-gate-verify.log" 2>&1 || LAST_EXIT=$?
check_eq "gate: a failing verification -> exit 3" "3" "$LAST_EXIT"
check "gate: the failing command is named" grep -q 'verification 1' "$IREPO/.agent/current/VERIFY.md"

# evidence gate: a change outside Allowed Changes
JREPO="$(new_repo smoke-loop-scope)"
CLEANUP_DIRS+=("$JREPO")
JFIX="$(mktemp -d "$TMP_BASE/smoke-fix-scope.XXXXXX")"
CLEANUP_DIRS+=("$JFIX")
printf 'def uppercase(s):\n    return s.upper()\n' >"$JREPO/app.py"
printf 'secret = 1\n' >"$JREPO/other.py"
write_phase_md "$JREPO" "A"
write_run_state "$JREPO" "A" "idle" >/dev/null
QJ="$JFIX/tasks.jsonl"
queue_task_json J01 "stay inside allowed changes" low pending "true" "app.py" "other.py" >>"$QJ"
write_queue "$JREPO" "A" "$QJ" "true"
cat >"$JFIX/J01.sh" <<'EOF'
printf 'secret = 2\n' > other.py
EOF
commit_all "$JREPO" "scope fixture"
LAST_EXIT=0
( cd "$JREPO" && PATH="$FAKEBIN:$PATH" FAKE_OPENCODE_MODE=script \
    FAKE_OPENCODE_SCRIPT="$SMOKE_DIR/assets/fake-task.sh" FAKE_TASK_DIR="$JFIX" \
    "$RUN_PHASE" ) >"$OUT_DIR/loop-gate-scope.log" 2>&1 || LAST_EXIT=$?
check_eq "gate: a change outside Allowed Changes -> exit 3" "3" "$LAST_EXIT"
check "gate: the forbidden file is named" grep -q 'other.py' "$JREPO/.agent/current/VERIFY.md"
check "gate: the reason mentions Forbidden" grep -q 'Forbidden' "$JREPO/.agent/current/VERIFY.md"

# evidence gate: the worker must not edit the Supervisor artifacts
KREPO="$(new_repo smoke-loop-tamper)"
CLEANUP_DIRS+=("$KREPO")
KFIX="$(mktemp -d "$TMP_BASE/smoke-fix-tamper.XXXXXX")"
CLEANUP_DIRS+=("$KFIX")
printf 'def uppercase(s):\n    return s.upper()\n' >"$KREPO/app.py"
write_phase_md "$KREPO" "A"
write_run_state "$KREPO" "A" "idle" >/dev/null
QK="$KFIX/tasks.jsonl"
queue_task_json K01 "tamper with the queue" low pending "true" "app.py" >>"$QK"
write_queue "$KREPO" "A" "$QK" "true"
cat >"$KFIX/K01.sh" <<'EOF'
python3 - <<'PY'
import json, io
p = ".agent/phases/A/TASK_QUEUE.json"
d = json.load(open(p))
d["tasks"][0]["status"] = "done"
json.dump(d, open(p, "w"), indent=2)
PY
EOF
commit_all "$KREPO" "tamper fixture"
LAST_EXIT=0
( cd "$KREPO" && PATH="$FAKEBIN:$PATH" FAKE_OPENCODE_MODE=script \
    FAKE_OPENCODE_SCRIPT="$SMOKE_DIR/assets/fake-task.sh" FAKE_TASK_DIR="$KFIX" \
    "$RUN_PHASE" ) >"$OUT_DIR/loop-gate-tamper.log" 2>&1 || LAST_EXIT=$?
check_eq "gate: a worker edit of the queue -> exit 3" "3" "$LAST_EXIT"
check "gate: the tampering is named" grep -q 'Supervisor artifact' "$KREPO/.agent/current/VERIFY.md"

# ---------------------------------------------------------------------------
# 7c. the diff-scope gate must catch changes to ALREADY DIRTY files
#     (review finding HIGH: a forbidden tracked file that was dirty before the
#     Task, then overwritten by it, used to be auto-accepted)
# ---------------------------------------------------------------------------
info "scope gate: already-dirty files (regression)"

# G1: no-HEAD repo, forbidden file already dirty (untracked) and overwritten
G1="$(new_repo smoke-scope-g1)"
CLEANUP_DIRS+=("$G1")
G1FIX="$(mktemp -d "$TMP_BASE/smoke-fix-g1.XXXXXX")"
CLEANUP_DIRS+=("$G1FIX")
printf 'existing user work\n' >"$G1/forbidden.txt"
printf 'old\n' >"$G1/allowed.txt"
write_phase_md "$G1" "A"
write_run_state "$G1" "A" "idle" >/dev/null
G1Q="$G1FIX/tasks.jsonl"
queue_task_json A01 "edit allowed" low pending 'test "$(cat allowed.txt)" = ok' \
    "allowed.txt" "forbidden.txt" >>"$G1Q"
write_queue "$G1" "A" "$G1Q" 'test "$(cat allowed.txt)" = ok'
cat >"$G1FIX/A01.sh" <<'EOF'
printf 'ok\n' > allowed.txt
printf 'overwritten\n' > forbidden.txt
EOF
FAKE_TASK_DIR="$G1FIX" run_phase_fake "$G1" "$FAKEBIN"
check_eq "G1: overwriting an already-dirty forbidden file -> exit 3" "3" "$LAST_EXIT"
check "G1: the Task was NOT auto-accepted" bash -c "! ls -d '$G1'/.agent/history/*A01 >/dev/null 2>&1"
check "G1: the queue did not mark it done" bash -c \
    "jq -e '[.tasks[] | select(.id==\"A01\")][0].status != \"done\"' '$G1/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "G1: VERIFY.md names the forbidden file" grep -q 'forbidden.txt' "$G1/.agent/current/VERIFY.md"
check "G1: VERIFY.md records the FAIL" grep -q '^FAIL' "$G1/.agent/current/VERIFY.md"

# G2: same with a HEAD and a tracked, already-dirty forbidden file
G2="$(new_repo smoke-scope-g2)"
CLEANUP_DIRS+=("$G2")
G2FIX="$(mktemp -d "$TMP_BASE/smoke-fix-g2.XXXXXX")"
CLEANUP_DIRS+=("$G2FIX")
printf 'existing user work\n' >"$G2/forbidden.txt"
printf 'old\n' >"$G2/allowed.txt"
write_phase_md "$G2" "A"
write_run_state "$G2" "A" "idle" >/dev/null
G2Q="$G2FIX/tasks.jsonl"
queue_task_json A01 "edit allowed" low pending 'test "$(cat allowed.txt)" = ok' \
    "allowed.txt" "forbidden.txt" >>"$G2Q"
write_queue "$G2" "A" "$G2Q" 'test "$(cat allowed.txt)" = ok'
commit_all "$G2" "baseline"
printf 'local uncommitted user work\n' >"$G2/forbidden.txt"
check_commit "G2: fixture really has a HEAD and a dirty forbidden file" bash -c \
    "git -C '$G2' rev-parse -q --verify HEAD >/dev/null && ! git -C '$G2' diff --quiet -- forbidden.txt"
cat >"$G2FIX/A01.sh" <<'EOF'
printf 'ok\n' > allowed.txt
printf 'overwritten\n' > forbidden.txt
EOF
FAKE_TASK_DIR="$G2FIX" run_phase_fake "$G2" "$FAKEBIN"
check_eq "G2: tracked+dirty forbidden file overwritten -> exit 3" "3" "$LAST_EXIT"
check "G2: the Task was NOT auto-accepted" bash -c "! ls -d '$G2'/.agent/history/*A01 >/dev/null 2>&1"
check "G2: VERIFY.md names the forbidden file" grep -q 'forbidden.txt' "$G2/.agent/current/VERIFY.md"

# G3: an already-dirty file that IS allowed may be edited again (no over-blocking)
G3="$(new_repo smoke-scope-g3)"
CLEANUP_DIRS+=("$G3")
G3FIX="$(mktemp -d "$TMP_BASE/smoke-fix-g3.XXXXXX")"
CLEANUP_DIRS+=("$G3FIX")
printf 'old\n' >"$G3/allowed.txt"
printf 'untouched user work\n' >"$G3/unrelated.txt"
write_phase_md "$G3" "A"
write_run_state "$G3" "A" "idle" >/dev/null
G3Q="$G3FIX/tasks.jsonl"
queue_task_json A01 "edit allowed" low pending 'test "$(cat allowed.txt)" = ok' \
    "allowed.txt" "" >>"$G3Q"
write_queue "$G3" "A" "$G3Q" 'test "$(cat allowed.txt)" = ok'
cat >"$G3FIX/A01.sh" <<'EOF'
printf 'ok\n' > allowed.txt
EOF
commit_all "$G3" "baseline"
FAKE_TASK_DIR="$G3FIX" run_phase_fake "$G3" "$FAKEBIN"
check_eq "G3: re-editing an already-dirty ALLOWED file -> exit 0" "0" "$LAST_EXIT"
check "G3: the Task was accepted" bash -c \
    "jq -e '[.tasks[] | select(.id==\"A01\")][0].status == \"done\"' '$G3/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "G3: the untouched dirty file was not blamed on the Task" bash -c \
    "! grep -q 'unrelated.txt' '$G3/.agent/current/VERIFY.md'"

# G4: deleting a tracked file outside Allowed Changes is a scope violation
G4="$(new_repo smoke-scope-g4)"
CLEANUP_DIRS+=("$G4")
G4FIX="$(mktemp -d "$TMP_BASE/smoke-fix-g4.XXXXXX")"
CLEANUP_DIRS+=("$G4FIX")
printf 'old\n' >"$G4/allowed.txt"
printf 'keep me\n' >"$G4/keep.txt"
write_phase_md "$G4" "A"
write_run_state "$G4" "A" "idle" >/dev/null
G4Q="$G4FIX/tasks.jsonl"
queue_task_json A01 "edit allowed" low pending 'test "$(cat allowed.txt)" = ok' \
    "allowed.txt" "" >>"$G4Q"
write_queue "$G4" "A" "$G4Q" 'test "$(cat allowed.txt)" = ok'
cat >"$G4FIX/A01.sh" <<'EOF'
printf 'ok\n' > allowed.txt
rm -f keep.txt
EOF
commit_all "$G4" "baseline"
FAKE_TASK_DIR="$G4FIX" run_phase_fake "$G4" "$FAKEBIN"
check_eq "G4: deleting a file outside Allowed Changes -> exit 3" "3" "$LAST_EXIT"
check "G4: VERIFY.md names the deleted file" grep -q 'keep.txt' "$G4/.agent/current/VERIFY.md"

# G5: deleting a tracked file that IS allowed is fine
G5="$(new_repo smoke-scope-g5)"
CLEANUP_DIRS+=("$G5")
G5FIX="$(mktemp -d "$TMP_BASE/smoke-fix-g5.XXXXXX")"
CLEANUP_DIRS+=("$G5FIX")
printf 'old\n' >"$G5/obsolete.txt"
write_phase_md "$G5" "A"
write_run_state "$G5" "A" "idle" >/dev/null
G5Q="$G5FIX/tasks.jsonl"
queue_task_json A01 "remove the obsolete file" low pending 'test ! -e obsolete.txt' \
    "obsolete.txt" "" >>"$G5Q"
write_queue "$G5" "A" "$G5Q" 'test ! -e obsolete.txt'
cat >"$G5FIX/A01.sh" <<'EOF'
rm -f obsolete.txt
EOF
commit_all "$G5" "baseline"
FAKE_TASK_DIR="$G5FIX" run_phase_fake "$G5" "$FAKEBIN"
check_eq "G5: deleting an ALLOWED tracked file -> exit 0" "0" "$LAST_EXIT"
check "G5: the Task was accepted" bash -c \
    "jq -e '[.tasks[] | select(.id==\"A01\")][0].status == \"done\"' '$G5/.agent/phases/A/TASK_QUEUE.json' >/dev/null"

# ---------------------------------------------------------------------------
# 7d. a live run is never disturbed: refusal is read-only
#     (review finding HIGH: startup rewrote TASK.md and RUN_STATE while a worker
#     was still live)
# ---------------------------------------------------------------------------
info "startup: read-only refusal while a run is live (regression)"

H1="$(new_repo smoke-live-h1)"
CLEANUP_DIRS+=("$H1")
H1FIX="$(mktemp -d "$TMP_BASE/smoke-fix-h1.XXXXXX")"
CLEANUP_DIRS+=("$H1FIX")
printf 'old\n' >"$H1/allowed.txt"
write_phase_md "$H1" "A"
write_run_state "$H1" "A" "running" >/dev/null
H1Q="$H1FIX/tasks.jsonl"
queue_task_json A01 "edit allowed" low pending 'test "$(cat allowed.txt)" = ok' "allowed.txt" "" >>"$H1Q"
write_queue "$H1" "A" "$H1Q" 'test "$(cat allowed.txt)" = ok'
mkdir -p "$H1/.agent/current"
cat >"$H1/.agent/current/TASK.md" <<'EOF'
# Task

## Task ID
A01

## Marker
AUDIT ORIGINAL DEFINITION
EOF
printf '%s' '{"task_id":"A01","run_id":"r1","status":"running"}' >"$H1/.agent/current/STATE.json"
commit_all "$H1" "live fixture"
sleep 30 &
H1PID=$!
mkdir -p "$H1/.agent/current/.worker.lock"
printf 'pid=%s\nworker_pid=\nrun_id=live\n' "$H1PID" >"$H1/.agent/current/.worker.lock/info"
H1_MANIFEST="$(agent_manifest "$H1")"
H1_BEFORE_TASK="$(shasum "$H1/.agent/current/TASK.md" | awk '{print $1}')"
H1_BEFORE_RS="$(shasum "$H1/.agent/RUN_STATE.json" | awk '{print $1}')"
H1_BEFORE_Q="$(shasum "$H1/.agent/phases/A/TASK_QUEUE.json" | awk '{print $1}')"
run_phase_fake "$H1" "$FAKEBIN"
check_eq "H1: a live worker lock refuses the loop -> exit 5" "5" "$LAST_EXIT"
check "H1: the refusal says a worker is running" grep -q 'worker is still running' "$OUT_DIR/phase-${TEST_NAME}.log"
check_eq "H1: TASK.md is byte-identical after the refusal" "$H1_BEFORE_TASK" \
    "$(shasum "$H1/.agent/current/TASK.md" | awk '{print $1}')"
check "H1: the original Task definition survived" grep -q 'AUDIT ORIGINAL DEFINITION' "$H1/.agent/current/TASK.md"
check_eq "H1: RUN_STATE.json is byte-identical after the refusal" "$H1_BEFORE_RS" \
    "$(shasum "$H1/.agent/RUN_STATE.json" | awk '{print $1}')"
check_eq "H1: TASK_QUEUE.json is byte-identical after the refusal" "$H1_BEFORE_Q" \
    "$(shasum "$H1/.agent/phases/A/TASK_QUEUE.json" | awk '{print $1}')"
check "H1: RUN_STATE still says running" bash -c "jq -e '.status == \"running\"' '$H1/.agent/RUN_STATE.json' >/dev/null"
check_eq "H1: the whole .agent tree is byte-identical after the refusal" "$H1_MANIFEST" "$(agent_manifest "$H1")"
check "H1: no phase log directory was created" bash -c "! test -d '$H1/.agent/current/logs'"
check "H1: no phase lock was left behind" bash -c "! test -e '$H1/.agent/current/.phase.lock'"
kill "$H1PID" 2>/dev/null || true
wait "$H1PID" 2>/dev/null || true
rm -rf "$H1/.agent/current/.worker.lock"

# H2: a live phase loop (another run-phase) refuses without touching anything
H2="$(new_repo smoke-live-h2)"
CLEANUP_DIRS+=("$H2")
H2FIX="$(mktemp -d "$TMP_BASE/smoke-fix-h2.XXXXXX")"
CLEANUP_DIRS+=("$H2FIX")
printf 'old\n' >"$H2/allowed.txt"
write_phase_md "$H2" "A"
write_run_state "$H2" "A" "running" >/dev/null
H2Q="$H2FIX/tasks.jsonl"
queue_task_json A01 "edit allowed" low pending 'test "$(cat allowed.txt)" = ok' "allowed.txt" "" >>"$H2Q"
write_queue "$H2" "A" "$H2Q" 'test "$(cat allowed.txt)" = ok'
cat >"$H2FIX/A01.sh" <<'EOF'
printf 'ok\n' > allowed.txt
EOF
commit_all "$H2" "live loop fixture"
sleep 30 &
H2PID=$!
mkdir -p "$H2/.agent/current/.phase.lock"
printf 'pid=%s\nrun_id=other\nphase=A\n' "$H2PID" >"$H2/.agent/current/.phase.lock/info"
H2_BEFORE_RS="$(shasum "$H2/.agent/RUN_STATE.json" | awk '{print $1}')"
H2_MANIFEST="$(agent_manifest "$H2")"
run_phase_fake "$H2" "$FAKEBIN"
check_eq "H2: a live phase loop refuses a second loop -> exit 5" "5" "$LAST_EXIT"
check_eq "H2: RUN_STATE.json is byte-identical" "$H2_BEFORE_RS" \
    "$(shasum "$H2/.agent/RUN_STATE.json" | awk '{print $1}')"
check_eq "H2: the whole .agent tree is byte-identical" "$H2_MANIFEST" "$(agent_manifest "$H2")"
check "H2: the other loop's lock was left in place" test -d "$H2/.agent/current/.phase.lock"
kill "$H2PID" 2>/dev/null || true
wait "$H2PID" 2>/dev/null || true

# H3: a stale phase lock refuses read-only, and --break-lock is the way out
H3_BEFORE_RS="$(shasum "$H2/.agent/RUN_STATE.json" | awk '{print $1}')"
printf 'pid=999999\nrun_id=dead\nphase=A\n' >"$H2/.agent/current/.phase.lock/info"
run_phase_fake "$H2" "$FAKEBIN"
check_eq "H3: an unprovable stale phase lock -> exit 5" "5" "$LAST_EXIT"
check_eq "H3: RUN_STATE.json is byte-identical" "$H3_BEFORE_RS" \
    "$(shasum "$H2/.agent/RUN_STATE.json" | awk '{print $1}')"
check "H3: the stale lock is still there" test -d "$H2/.agent/current/.phase.lock"
FAKE_TASK_DIR="$H2FIX" run_phase_fake "$H2" "$FAKEBIN" --break-lock
check_eq "H3: --break-lock lets the loop proceed -> exit 0" "0" "$LAST_EXIT"
check "H3: the stale lock was archived" bash -c "ls -d '$H2'/.agent/history/attempts/stale-locks/* >/dev/null 2>&1"

# ---------------------------------------------------------------------------
# 7d-2. stale WORKER lock: refuse before any project write, then recover only
#       with an explicit --break-lock (review finding MEDIUM). H3 covers the
#       stale PHASE lock only; a stale worker lock is a separate case.
# ---------------------------------------------------------------------------
info "startup: stale WORKER lock (regression)"

stale_worker_fixture() {  # <repo> <fixdir> <lock-info-text>
    local repo="$1" fix="$2" info="$3" q
    printf 'old\n' >"$repo/allowed.txt"
    write_phase_md "$repo" "A"
    write_run_state "$repo" "A" "running" >/dev/null
    q="$fix/tasks.jsonl"
    queue_task_json A01 "edit allowed" low pending 'test "$(cat allowed.txt)" = ok' "allowed.txt" "" >>"$q"
    write_queue "$repo" "A" "$q" 'test "$(cat allowed.txt)" = ok'
    printf 'printf "ok\\n" > allowed.txt\n' >"$fix/A01.sh"
    mkdir -p "$repo/.agent/current"
    printf '# Task\n\n## Task ID\nA01\n\n## Marker\nORIGINAL DEFINITION\n' >"$repo/.agent/current/TASK.md"
    commit_all "$repo" "stale worker lock fixture"
    mkdir -p "$repo/.agent/current/.worker.lock"
    printf '%s' "$info" >"$repo/.agent/current/.worker.lock/info"
}

# J1: cancelled worker lock, no --break-lock -> refuse, whole .agent byte-identical
J1="$(new_repo smoke-stale-j1)"
CLEANUP_DIRS+=("$J1")
J1FIX="$(mktemp -d "$TMP_BASE/smoke-fix-j1.XXXXXX")"
CLEANUP_DIRS+=("$J1FIX")
stale_worker_fixture "$J1" "$J1FIX" 'pid=999999
worker_pid=999998
run_id=cancelled
cancelled_by=TERM
'
J1_MANIFEST="$(agent_manifest "$J1")"
FAKE_TASK_DIR="$J1FIX" run_phase_fake "$J1" "$FAKEBIN"
check_eq "J1: unconfirmed stale worker lock -> exit 5" "5" "$LAST_EXIT"
check_eq "J1: the whole .agent tree is byte-identical after the refusal" "$J1_MANIFEST" "$(agent_manifest "$J1")"
check "J1: no worker was started" bash -c "! test -d '$J1/.agent/current/logs'"
check "J1: the original TASK.md survived" grep -q 'ORIGINAL DEFINITION' "$J1/.agent/current/TASK.md"
check "J1: the stale lock was NOT moved" test -d "$J1/.agent/current/.worker.lock"
check "J1: the refusal explains the pid is not proof" grep -qi 'not proof' "$OUT_DIR/phase-${TEST_NAME}.log"
check "J1: the refusal names the recovery flag" grep -q -- '--break-lock' "$OUT_DIR/phase-${TEST_NAME}.log"
check "J1: the refusal says nothing was changed" grep -q 'no project file was changed' "$OUT_DIR/phase-${TEST_NAME}.log"
check "J1: no checkpoint was written to RUN_STATE" bash -c "jq -e '.status == \"running\"' '$J1/.agent/RUN_STATE.json' >/dev/null"
check "J1: the task is still pending in the queue" bash -c \
    "jq -e '[.tasks[] | select(.id==\"A01\")][0].status == \"pending\"' '$J1/.agent/phases/A/TASK_QUEUE.json' >/dev/null"

# J2: same lock, explicit --break-lock -> run-worker moves it aside and the Task runs
FAKE_TASK_DIR="$J1FIX" run_phase_fake "$J1" "$FAKEBIN" --break-lock
check_eq "J2: --break-lock recovers the stale worker lock -> exit 0" "0" "$LAST_EXIT"
check "J2: the Task was accepted" bash -c \
    "jq -e '[.tasks[] | select(.id==\"A01\")][0].status == \"done\"' '$J1/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "J2: the worker really ran" bash -c "[ \"\$(cat '$J1/allowed.txt')\" = ok ]"
check "J2: the stale lock was archived, not deleted" bash -c \
    "ls -d '$J1'/.agent/history/attempts/stale-locks/*-999999 >/dev/null 2>&1"
check "J2: the worker lock is gone after the run" bash -c "! test -e '$J1/.agent/current/.worker.lock'"
check "J2: it stopped at the phase review, not mid-phase" bash -c \
    "jq -e '.status == \"awaiting_phase_review\"' '$J1/.agent/RUN_STATE.json' >/dev/null"

# J3: a lock directory with no info at all cannot be proven dead either
J3="$(new_repo smoke-stale-j3)"
CLEANUP_DIRS+=("$J3")
J3FIX="$(mktemp -d "$TMP_BASE/smoke-fix-j3.XXXXXX")"
CLEANUP_DIRS+=("$J3FIX")
stale_worker_fixture "$J3" "$J3FIX" ''
rm -f "$J3/.agent/current/.worker.lock/info"
J3_MANIFEST="$(agent_manifest "$J3")"
FAKE_TASK_DIR="$J3FIX" run_phase_fake "$J3" "$FAKEBIN"
check_eq "J3: a worker lock with no info -> exit 5" "5" "$LAST_EXIT"
check_eq "J3: the whole .agent tree is byte-identical" "$J3_MANIFEST" "$(agent_manifest "$J3")"

# J4: check-state reports STALE_LOCK for a stale WORKER lock (not WORKER_RUNNING)
J4="$(new_repo smoke-stale-j4)"
CLEANUP_DIRS+=("$J4")
J4FIX="$(mktemp -d "$TMP_BASE/smoke-fix-j4.XXXXXX")"
CLEANUP_DIRS+=("$J4FIX")
stale_worker_fixture "$J4" "$J4FIX" 'pid=999999
worker_pid=999998
run_id=cancelled
cancelled_by=TERM
'
(cd "$J4" && "$CHECK_STATE") >"$OUT_DIR/cs-stale-worker.log" 2>&1 || true
check "J4: check-state verdict is STALE_LOCK" grep -q 'verdict: STALE_LOCK' "$OUT_DIR/cs-stale-worker.log"
check "J4: it names the WORKER lock" grep -q 'stale WORKER lock' "$OUT_DIR/cs-stale-worker.log"
check "J4: it warns a pid is not proof" grep -qi 'not proof' "$OUT_DIR/cs-stale-worker.log"
check "J4: check-state is a stop verdict (exit 1)" bash -c \
    "cd '$J4' && '$CHECK_STATE' >/dev/null 2>&1; [ \$? -eq 1 ]"

# J5: check-state reports STALE_LOCK for a stale PHASE lock, and distinguishes it
J5="$(new_repo smoke-stale-j5)"
CLEANUP_DIRS+=("$J5")
J5FIX="$(mktemp -d "$TMP_BASE/smoke-fix-j5.XXXXXX")"
CLEANUP_DIRS+=("$J5FIX")
stale_worker_fixture "$J5" "$J5FIX" ''
rm -rf "$J5/.agent/current/.worker.lock"
mkdir -p "$J5/.agent/current/.phase.lock"
printf 'pid=999999\nrun_id=dead\nphase=A\n' >"$J5/.agent/current/.phase.lock/info"
(cd "$J5" && "$CHECK_STATE") >"$OUT_DIR/cs-stale-phase.log" 2>&1 || true
check "J5: check-state verdict is STALE_LOCK" grep -q 'verdict: STALE_LOCK' "$OUT_DIR/cs-stale-phase.log"
check "J5: it names the PHASE lock (not the worker lock)" grep -q 'stale PHASE lock' "$OUT_DIR/cs-stale-phase.log"

# J6: a live worker pid still wins over --break-lock (never overridden)
J6="$(new_repo smoke-stale-j6)"
CLEANUP_DIRS+=("$J6")
J6FIX="$(mktemp -d "$TMP_BASE/smoke-fix-j6.XXXXXX")"
CLEANUP_DIRS+=("$J6FIX")
stale_worker_fixture "$J6" "$J6FIX" ''
sleep 30 &
J6PID=$!
printf 'pid=%s\nworker_pid=\nrun_id=live\n' "$J6PID" >"$J6/.agent/current/.worker.lock/info"
J6_MANIFEST="$(agent_manifest "$J6")"
FAKE_TASK_DIR="$J6FIX" run_phase_fake "$J6" "$FAKEBIN" --break-lock
check_eq "J6: --break-lock never overrides a live worker pid -> exit 5" "5" "$LAST_EXIT"
check_eq "J6: the whole .agent tree is byte-identical" "$J6_MANIFEST" "$(agent_manifest "$J6")"
kill "$J6PID" 2>/dev/null || true
wait "$J6PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 7d-3. a confirmed stale lock must NOT bypass non-lock state validation
#       (review finding MEDIUM: STALE_LOCK masked INCONSISTENT, so --break-lock
#        ran the loop with an invalid current/STATE.json)
# ---------------------------------------------------------------------------
info "lock confirmation vs non-lock issues (regression)"

# helper: add an unrepairable issue the loop must refuse on
break_state_json() { printf '{invalid json' >"$1/.agent/current/STATE.json"; }

# K1: invalid STATE, no lock at all, --break-lock -> refuse, tree unchanged
K1="$(new_repo smoke-issue-k1)"
CLEANUP_DIRS+=("$K1")
K1FIX="$(mktemp -d "$TMP_BASE/smoke-fix-k1.XXXXXX")"
CLEANUP_DIRS+=("$K1FIX")
stale_worker_fixture "$K1" "$K1FIX" 'pid=999999
'
rm -rf "$K1/.agent/current/.worker.lock"
break_state_json "$K1"
K1_MANIFEST="$(agent_manifest "$K1")"
FAKE_TASK_DIR="$K1FIX" run_phase_fake "$K1" "$FAKEBIN" --break-lock
check_eq "K1: invalid STATE (+no lock) -> exit 5" "5" "$LAST_EXIT"
check_eq "K1: the whole .agent tree is byte-identical" "$K1_MANIFEST" "$(agent_manifest "$K1")"
check "K1: the invalid STATE was not overwritten" grep -q 'invalid json' "$K1/.agent/current/STATE.json"

# K2: invalid STATE + stale WORKER lock, --break-lock -> still refuse (the regression)
K2="$(new_repo smoke-issue-k2)"
CLEANUP_DIRS+=("$K2")
K2FIX="$(mktemp -d "$TMP_BASE/smoke-fix-k2.XXXXXX")"
CLEANUP_DIRS+=("$K2FIX")
stale_worker_fixture "$K2" "$K2FIX" 'pid=999999
worker_pid=999998
run_id=cancelled
cancelled_by=TERM
'
break_state_json "$K2"
K2_MANIFEST="$(agent_manifest "$K2")"
FAKE_TASK_DIR="$K2FIX" run_phase_fake "$K2" "$FAKEBIN" --break-lock
check_eq "K2: invalid STATE + stale worker lock + --break-lock -> exit 5" "5" "$LAST_EXIT"
check_eq "K2: the whole .agent tree is byte-identical" "$K2_MANIFEST" "$(agent_manifest "$K2")"
check "K2: the stale worker lock was NOT moved" test -d "$K2/.agent/current/.worker.lock"
check "K2: no worker ran" bash -c "! test -d '$K2/.agent/current/logs'"
check "K2: the task is still pending" bash -c \
    "jq -e '[.tasks[] | select(.id==\"A01\")][0].status == \"pending\"' '$K2/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "K2: check-state says INCONSISTENT, not STALE_LOCK" bash -c \
    "cd '$K2' && '$CHECK_STATE' 2>&1 | grep -q 'verdict: INCONSISTENT'"
check "K2: the verdict says --break-lock does not bypass issues" bash -c \
    "cd '$K2' && '$CHECK_STATE' 2>&1 | grep -q 'does not bypass'"

# K3: invalid STATE + stale PHASE lock, --break-lock -> still refuse
K3="$(new_repo smoke-issue-k3)"
CLEANUP_DIRS+=("$K3")
K3FIX="$(mktemp -d "$TMP_BASE/smoke-fix-k3.XXXXXX")"
CLEANUP_DIRS+=("$K3FIX")
stale_worker_fixture "$K3" "$K3FIX" ''
rm -rf "$K3/.agent/current/.worker.lock"
mkdir -p "$K3/.agent/current/.phase.lock"
printf 'pid=999999\nrun_id=dead\nphase=A\n' >"$K3/.agent/current/.phase.lock/info"
break_state_json "$K3"
K3_MANIFEST="$(agent_manifest "$K3")"
FAKE_TASK_DIR="$K3FIX" run_phase_fake "$K3" "$FAKEBIN" --break-lock
check_eq "K3: invalid STATE + stale phase lock + --break-lock -> exit 5" "5" "$LAST_EXIT"
check_eq "K3: the whole .agent tree is byte-identical" "$K3_MANIFEST" "$(agent_manifest "$K3")"
check "K3: the stale phase lock was NOT moved" test -d "$K3/.agent/current/.phase.lock"

# K4: conflicting reports (RESULT + ESCALATION for the same Task) + stale worker lock
K4="$(new_repo smoke-issue-k4)"
CLEANUP_DIRS+=("$K4")
K4FIX="$(mktemp -d "$TMP_BASE/smoke-fix-k4.XXXXXX")"
CLEANUP_DIRS+=("$K4FIX")
stale_worker_fixture "$K4" "$K4FIX" 'pid=999999
worker_pid=999998
run_id=cancelled
'
printf '# Result\n\n## Task ID\nA01\n\n## Status\nDONE\n' >"$K4/.agent/current/RESULT.md"
printf '# Escalation\n\n## Task ID\nA01\n\n## Class\nESCALATE\n\n## Current Blocker\nfixture\n' >"$K4/.agent/current/ESCALATION.md"
K4_MANIFEST="$(agent_manifest "$K4")"
FAKE_TASK_DIR="$K4FIX" run_phase_fake "$K4" "$FAKEBIN" --break-lock
check_eq "K4: conflicting reports + stale worker lock -> exit 5" "5" "$LAST_EXIT"
check_eq "K4: the whole .agent tree is byte-identical" "$K4_MANIFEST" "$(agent_manifest "$K4")"
check "K4: both reports were left in place" bash -c \
    "test -s '$K4/.agent/current/RESULT.md' && test -s '$K4/.agent/current/ESCALATION.md'"

# K5: the allowed reconciliation still works together with a confirmed lock
K5="$(new_repo smoke-issue-k5)"
CLEANUP_DIRS+=("$K5")
K5FIX="$(mktemp -d "$TMP_BASE/smoke-fix-k5.XXXXXX")"
CLEANUP_DIRS+=("$K5FIX")
stale_worker_fixture "$K5" "$K5FIX" 'pid=999999
worker_pid=999998
run_id=cancelled
'
jq '(.tasks[0].status) = "in_progress"' "$K5/.agent/phases/A/TASK_QUEUE.json" >"$K5/.agent/phases/A/q.json" \
    && mv "$K5/.agent/phases/A/q.json" "$K5/.agent/phases/A/TASK_QUEUE.json"
printf '%s' '{"current_phase":"A","current_task":"A01","status":"running"}' >"$K5/.agent/RUN_STATE.json"
cp "$PROJECT_ROOT/skills/cheap-worker/assets/templates/TASK.md" "$K5/.agent/current/TASK.md"
printf '%s' '{"task_id":"A01","run_id":"r1","status":"running"}' >"$K5/.agent/current/STATE.json"
FAKE_TASK_DIR="$K5FIX" run_phase_fake "$K5" "$FAKEBIN" --break-lock
check_eq "K5: repairable TASK mismatch + stale worker lock -> exit 0" "0" "$LAST_EXIT"
check "K5: the Task ran and was accepted" bash -c \
    "jq -e '[.tasks[] | select(.id==\"A01\")][0].status == \"done\"' '$K5/.agent/phases/A/TASK_QUEUE.json' >/dev/null"
check "K5: TASK.md was rebuilt from the queue" bash -c "grep -q 'Risk' '$K5/.agent/current/TASK.md'"
check "K5: the stale lock was archived by run-worker" bash -c \
    "ls -d '$K5'/.agent/history/attempts/stale-locks/*-999999 >/dev/null 2>&1"

# ---------------------------------------------------------------------------
# 7e. gate text is data, never jq filter source
#     (review finding MEDIUM: a quoted --note broke the transition)
# ---------------------------------------------------------------------------
info "phase-gate: quoted notes/reasons (regression)"

I1="$(new_repo smoke-gate-i1)"
CLEANUP_DIRS+=("$I1")
write_phase_md "$I1" "A"
mkdir -p "$I1/.agent"
printf '%s' '{"current_phase":"A","status":"awaiting_human_qa"}' >"$I1/.agent/RUN_STATE.json"
I1_RC=0
(cd "$I1" && "$PHASE_GATE" qa-pass --note '确认 "登录" 正常') >"$OUT_DIR/gate-quoted-qa.log" 2>&1 || I1_RC=$?
check_eq "I1: qa-pass with a quoted note -> exit 0" "0" "$I1_RC"
check "I1: RUN_STATE is valid JSON" bash -c "jq empty '$I1/.agent/RUN_STATE.json'"
check "I1: the verdict was recorded" bash -c "jq -e '.human_qa == \"passed\"' '$I1/.agent/RUN_STATE.json' >/dev/null"
check "I1: the note text survived verbatim" bash -c "jq -r '.notes' '$I1/.agent/RUN_STATE.json' | grep -q '登录'"
check "I1: the quotes survived" bash -c "jq -r '.notes' '$I1/.agent/RUN_STATE.json' | grep -qF '\"登录\"'"

# review-pass with a summary that contains quotes and a newline
I2="$(new_repo smoke-gate-i2)"
CLEANUP_DIRS+=("$I2")
printf 'old\n' >"$I2/allowed.txt"
write_phase_md "$I2" "A"
write_run_state "$I2" "A" "idle" >/dev/null
I2Q="$I2/tasks.jsonl"
queue_task_json A01 "edit allowed" low pending 'test "$(cat allowed.txt)" = ok' "allowed.txt" "" >>"$I2Q"
write_queue "$I2" "A" "$I2Q" 'test "$(cat allowed.txt)" = ok'
I2FIX="$(mktemp -d "$TMP_BASE/smoke-fix-i2.XXXXXX")"
CLEANUP_DIRS+=("$I2FIX")
cat >"$I2FIX/A01.sh" <<'EOF'
printf 'ok\n' > allowed.txt
EOF
commit_all "$I2" "baseline"
FAKE_TASK_DIR="$I2FIX" run_phase_fake "$I2" "$FAKEBIN"
check_eq "I2: fixture reached awaiting_phase_review" "0" "$LAST_EXIT"
I2_RC=0
(cd "$I2" && "$PHASE_GATE" review-pass --summary 'reviewed "the diff"
and re-ran everything') >"$OUT_DIR/gate-quoted-review.log" 2>&1 || I2_RC=$?
check_eq "I2: review-pass with quotes and a newline -> exit 0" "0" "$I2_RC"
check "I2: RUN_STATE is valid JSON" bash -c "jq empty '$I2/.agent/RUN_STATE.json'"
check "I2: the state moved to human QA" bash -c "jq -e '.status == \"awaiting_human_qa\"' '$I2/.agent/RUN_STATE.json' >/dev/null"
check "I2: only the first summary line is in notes" bash -c \
    "jq -r '.notes' '$I2/.agent/RUN_STATE.json' | grep -qF 'reviewed \"the diff\"'"
check "I2: PHASE.md has the Result section" grep -q 'Reviewed by: Codex phase review' "$I2/.agent/phases/A/PHASE.md"

# review-fail with a quoted reason (adjustment + notes)
I3_RC=0
(cd "$I2" && "$PHASE_GATE" qa-fail --note 'defect: "export" button') >"$OUT_DIR/gate-quoted-qa-fail.log" 2>&1 || I3_RC=$?
check_eq "I3: qa-fail with a quoted note -> exit 0" "0" "$I3_RC"
check "I3: RUN_STATE is valid JSON" bash -c "jq empty '$I2/.agent/RUN_STATE.json'"
check "I3: the queue is valid JSON" bash -c "jq empty '$I2/.agent/phases/A/TASK_QUEUE.json'"
check "I3: the adjustment kept the text" bash -c \
    "jq -r '[.adjustments[] | .reason] | join(\" \")' '$I2/.agent/phases/A/TASK_QUEUE.json' | grep -qF '\"export\"'"
check "I3: the state was reopened" bash -c "jq -e '.status == \"running\"' '$I2/.agent/RUN_STATE.json' >/dev/null"
I4_RC=0
(cd "$I2" && "$PHASE_GATE" review-fail --reason 'needs "one" more Task') >"$OUT_DIR/gate-quoted-review-fail.log" 2>&1 || I4_RC=$?
check_eq "I4: review-fail in the wrong state -> exit 1" "1" "$I4_RC"


# ---------------------------------------------------------------------------
# 8. check-state fail-closed matrix (new states)
# ---------------------------------------------------------------------------
info "check-state matrix"
CSREPO="$(new_repo smoke-checkstate)"
CLEANUP_DIRS+=("$CSREPO")
mkdir -p "$CSREPO/.agent/phases/A" "$CSREPO/.agent/current"
sstate() {  # sstate <queue-json> <run-state-json> [<task-md>] [<state-json>]
    local q="$1" rs="$2" tmd="${3:-}" st="${4:-}"
    printf '%s' "$q" >"$CSREPO/.agent/phases/A/TASK_QUEUE.json"
    printf '%s' "$rs" >"$CSREPO/.agent/RUN_STATE.json"
    if [[ -n "$tmd" ]]; then
        printf '%s' "$tmd" >"$CSREPO/.agent/current/TASK.md"
    else
        rm -f "$CSREPO/.agent/current/TASK.md"
    fi
    if [[ -n "$st" ]]; then
        printf '%s' "$st" >"$CSREPO/.agent/current/STATE.json"
    else
        rm -f "$CSREPO/.agent/current/STATE.json"
    fi
    rm -f "$CSREPO/.agent/current/RESULT.md" "$CSREPO/.agent/current/ESCALATION.md"
    rm -rf "$CSREPO/.agent/current/.worker.lock" "$CSREPO/.agent/current/.phase.lock"
}
CS="$CHECK_STATE"
cstate() {  # cstate <name> [expected-exit]
    local name="$1" want="${2:-}"
    CS_RC=0
    (cd "$CSREPO" && "$CS") >"$OUT_DIR/cs-${name}.log" 2>&1 || CS_RC=$?
    [[ -z "$want" ]] || check_eq "check-state: $name -> exit $want" "$want" "$CS_RC"
}
Q_TASK='{"tasks":[{"id":"A02","status":"in_progress","verification":[{"cmd":"true"}]}]}'

sstate '{broken' '{"current_phase":"A","current_task":"A02","status":"running"}' '' '{}'
cstate badjson 1
check "check-state: broken JSON is reported" grep -qE 'not a JSON object|not valid JSON' "$OUT_DIR/cs-badjson.log"

sstate "$Q_TASK" '{"current_phase":"A","current_task":"WRONG","status":"running"}' \
    '# Task

## Task ID
A02' '{"task_id":"A02"}'
cstate runstate-mismatch 1
check "check-state: RUN_STATE mismatch reported" grep -q 'does not match the queue' "$OUT_DIR/cs-runstate-mismatch.log"

sstate '{"tasks":[{"id":"A02","status":"in_progress","verification":[{"cmd":"true"}]},{"id":"A03","status":"in_progress","verification":[{"cmd":"true"}]}]}' \
    '{"current_phase":"A","current_task":"A02","status":"running"}' \
    '# Task

## Task ID
A02' '{"task_id":"A02"}'
cstate two-inprogress 1
check "check-state: two in_progress reported" grep -q 'more than one Task is in_progress' "$OUT_DIR/cs-two-inprogress.log"

sstate '{"tasks":[{"id":"A02","status":"pending","verification":[{"cmd":"true"}]}]}' \
    '{"current_phase":"A","current_task":"","status":"running"}' '' '{"task_id":"","run_id":"","status":"idle"}'
cstate pending 0
check "check-state: pending -> RUNNING" grep -q 'verdict: RUNNING' "$OUT_DIR/cs-pending.log"

sstate "$Q_TASK" '{"current_phase":"A","current_task":"A02","status":"checkpoint","stop_reason":"worker_checkpoint"}' \
    '# Task

## Task ID
A02' '{"task_id":"A02"}'
cstate checkpoint 1
check "check-state: checkpoint verdict" grep -q 'verdict: CHECKPOINT' "$OUT_DIR/cs-checkpoint.log"
check "check-state: prints the stop_reason" grep -q 'worker_checkpoint' "$OUT_DIR/cs-checkpoint.log"

sstate '{"tasks":[{"id":"A02","status":"escalated","verification":[{"cmd":"true"}]}]}' \
    '{"current_phase":"A","current_task":"A02","status":"escalated"}' \
    '# Task

## Task ID
A02' '{"task_id":"A02"}'
cstate escalated 1
check "check-state: escalated verdict" grep -q 'verdict: ESCALATED' "$OUT_DIR/cs-escalated.log"

sstate '{"tasks":[{"id":"A02","status":"done","verification":[{"cmd":"true"}]}]}' \
    '{"current_phase":"A","current_task":"","status":"awaiting_phase_review"}' \
    '# Task

## Task ID
A02' '{"task_id":"A02"}'
cstate awaiting-review 1
check "check-state: awaiting phase review verdict" grep -q 'verdict: AWAITING_PHASE_REVIEW' "$OUT_DIR/cs-awaiting-review.log"

sstate '{"tasks":[{"id":"A02","status":"done","verification":[{"cmd":"true"}]}]}' \
    '{"current_phase":"A","current_task":"","status":"awaiting_human_qa"}' \
    '# Task

## Task ID
A02' '{"task_id":"A02"}'
cstate awaiting-human 1
check "check-state: awaiting human QA verdict" grep -q 'verdict: AWAITING_HUMAN_QA' "$OUT_DIR/cs-awaiting-human.log"

sstate '{"tasks":[{"id":"A02","status":"pending","verification":[{"cmd":"true"}]}]}' \
    '{"current_phase":"A","current_task":"","status":"awaiting_human_qa"}' \
    '# Task

## Task ID
A02' '{"task_id":"A02"}'
cstate human-with-pending 1
check "check-state: human QA with pending reported" grep -q 'still has pending' "$OUT_DIR/cs-human-with-pending.log"

mkdir -p "$CSREPO/.agent/history/20260101T000000Z-A02"
sstate "$Q_TASK" '{"current_phase":"A","current_task":"A02","status":"running"}' \
    '# Task

## Task ID
A02' '{"task_id":"A02"}'
cstate archived-not-done 1
check "check-state: suggests marking done" grep -q 'mark it done' "$OUT_DIR/cs-archived-not-done.log"
rm -rf "$CSREPO/.agent/history"

sstate "$Q_TASK" '{"current_phase":"A","current_task":"A02","status":"running"}' \
    '# Task

## Task ID
A02' '{"task_id":"A02"}'
printf '# Result\n\n## Task ID\nA02\n\n## Status\nFAILED\n' >"$CSREPO/.agent/current/RESULT.md"
cstate bad-result 1
check "check-state: unacceptable report reported" grep -q 'not acceptable' "$OUT_DIR/cs-bad-result.log"

sstate "$Q_TASK" '{"current_phase":"A","current_task":"A02","status":"running"}' \
    '# Task

## Task ID
A02' '{"task_id":"A02"}'
printf '# Escalation\n\n## Task ID\nA02\n' >"$CSREPO/.agent/current/ESCALATION.md"
cstate escalation-noblocker 1
check "check-state: missing blocker reported" grep -q 'no Current Blocker' "$OUT_DIR/cs-escalation-noblocker.log"

sstate '{"tasks":[{"id":42,"status":"pending"}]}' '{"current_phase":"A","status":"running"}'
cstate number-id 1
check "check-state: numeric id reported" grep -q 'missing/invalid id' "$OUT_DIR/cs-number-id.log"

sstate '{"tasks":[{"id":"A02","status":"pending","verification":[{"cmd":"true"}]},{"id":"A02","status":"pending","verification":[{"cmd":"true"}]}]}' \
    '{"current_phase":"A","status":"running"}'
cstate duplicate-id 1
check "check-state: duplicate ids reported" grep -q 'duplicate Task ids' "$OUT_DIR/cs-duplicate-id.log"

sstate '{"tasks":[{"id":"A02","status":"pending"}]}' '{"status":"running"}'
cstate no-phase 1
check "check-state: phase requirement reported" grep -q 'requires a current_phase' "$OUT_DIR/cs-no-phase.log"

sstate '{"tasks":[{"id":"A02","status":"pending","verification":[]}]}' \
    '{"current_phase":"A","status":"running"}'
cstate no-verification 1
check "check-state: a Task without verification is an ISSUE" grep -q 'no verification commands' "$OUT_DIR/cs-no-verification.log"

sstate '{"tasks":[{"id":"A02","status":"pending","verification":[{"cmd":"true"}]}]}' \
    '{"current_phase":"A","current_task":"","status":"nonsense"}' '' '{"task_id":"","run_id":"","status":"idle"}'
cstate unknown-status 1
check "check-state: unknown status reported" grep -q 'not a known state' "$OUT_DIR/cs-unknown-status.log"

rm -f "$CSREPO/.agent/phases/A/TASK_QUEUE.json"
printf '%s' '{"current_phase":"A","current_task":"A02","status":"running"}' >"$CSREPO/.agent/RUN_STATE.json"
cstate missing-queue 1
check "check-state: missing queue reported" grep -q 'is missing' "$OUT_DIR/cs-missing-queue.log"

# live locks -> WORKER_RUNNING
sstate "$Q_TASK" '{"current_phase":"A","current_task":"A02","status":"running"}' \
    '# Task

## Task ID
A02' '{"task_id":"A02"}'
sleep 30 &
SURV=$!
mkdir -p "$CSREPO/.agent/current/.worker.lock"
printf 'pid=999999\nworker_pid=%s\nrun_id=survivor\n' "$SURV" >"$CSREPO/.agent/current/.worker.lock/info"
cstate survivor-lock 1
check "check-state: live worker_pid verdict" grep -q 'verdict: WORKER_RUNNING' "$OUT_DIR/cs-survivor-lock.log"
rm -rf "$CSREPO/.agent/current/.worker.lock"
mkdir -p "$CSREPO/.agent/current/.phase.lock"
printf 'pid=%s\nrun_id=loop\nphase=A\n' "$SURV" >"$CSREPO/.agent/current/.phase.lock/info"
cstate live-phase-lock 1
check "check-state: live phase lock verdict" grep -q 'verdict: WORKER_RUNNING' "$OUT_DIR/cs-live-phase-lock.log"
rm -rf "$CSREPO/.agent/current/.phase.lock"
kill "$SURV" 2>/dev/null || true
wait "$SURV" 2>/dev/null || true

# empty project
EMPTYREPO="$(new_repo smoke-checkstate-empty)"
CLEANUP_DIRS+=("$EMPTYREPO")
CS_RC=0
(cd "$EMPTYREPO" && "$CS") >"$OUT_DIR/cs-empty.log" 2>&1 || CS_RC=$?
check_eq "check-state: fresh project -> EMPTY exit 0" "0" "$CS_RC"
check "check-state: empty verdict" grep -q 'verdict: EMPTY' "$OUT_DIR/cs-empty.log"

# ---------------------------------------------------------------------------
# 9. installer / uninstaller boundaries
# ---------------------------------------------------------------------------
if (AGENT_ORCHESTRATION_TEST_TARGET=0 "$PROJECT_ROOT/scripts/install-skills.sh" --target "$OUT_DIR/forbidden-target/skills" --quiet) >"$OUT_DIR/install-target-gate.log" 2>&1; then
    fail "installer --target must be refused without the test env var"
else
    pass "installer --target is refused without AGENT_ORCHESTRATION_TEST_TARGET=1"
fi
check "installer target gate message" grep -q 'test-only mechanism' "$OUT_DIR/install-target-gate.log"

FRESH_HOME="$(mktemp -d "$TMP_BASE/fresh-home.XXXXXX")"
CLEANUP_DIRS+=("$FRESH_HOME")
if HOME="$FRESH_HOME" "$PROJECT_ROOT/scripts/install-skills.sh" --quiet >"$OUT_DIR/install-fresh-home.log" 2>&1; then
    pass "installer works on a fresh HOME"
else
    fail "installer failed on a fresh HOME (see $OUT_DIR/install-fresh-home.log)"
fi
check "fresh HOME install created both skills" test -f "$FRESH_HOME/.agents/skills/phase-runner/SKILL.md"
check "fresh HOME install includes the loop script" test -x "$FRESH_HOME/.agents/skills/phase-runner/scripts/run-phase.sh"
check "fresh HOME install includes the gate script" test -x "$FRESH_HOME/.agents/skills/phase-runner/scripts/phase-gate.sh"

LINK_HOME="$(mktemp -d "$TMP_BASE/linkhome.XXXXXX")"
ALTERNATE="$(mktemp -d "$TMP_BASE/alternate.XXXXXX")"
CLEANUP_DIRS+=("$LINK_HOME" "$ALTERNATE")
mkdir -p "$ALTERNATE"
ln -s "$ALTERNATE" "$LINK_HOME/.agents"
if HOME="$LINK_HOME" "$PROJECT_ROOT/scripts/install-skills.sh" --quiet >"$OUT_DIR/install-symlink-escape.log" 2>&1; then
    fail "installer must refuse a parent symlink escaping HOME"
else
    pass "installer refuses a parent symlink escaping HOME"
fi
check "symlink-escape message" grep -q 'outside \$HOME' "$OUT_DIR/install-symlink-escape.log"

SRCCOPY="$(mktemp -d "$TMP_BASE/sourcecopy.XXXXXX")"
CLEANUP_DIRS+=("$SRCCOPY")
mkdir -p "$SRCCOPY/skills" "$SRCCOPY/scripts"
cp -R "$PROJECT_ROOT/skills/cheap-worker" "$SRCCOPY/skills/cheap-worker"
cp -R "$PROJECT_ROOT/skills/phase-runner" "$SRCCOPY/skills/phase-runner"
cp "$PROJECT_ROOT/scripts/uninstall-managed-skills.sh" "$SRCCOPY/scripts/"
printf 'installed\n' >"$SRCCOPY/skills/cheap-worker/.installed-by-agent-orchestration"
printf 'installed\n' >"$SRCCOPY/skills/phase-runner/.installed-by-agent-orchestration"
if AGENT_ORCHESTRATION_TEST_TARGET=1 "$SRCCOPY/scripts/uninstall-managed-skills.sh" \
        --target "$SRCCOPY/skills" --force --yes >"$OUT_DIR/uninstall-sourcecopy.log" 2>&1; then
    fail "uninstaller must refuse a source-copy target"
else
    pass "uninstaller refuses a source-copy target"
fi
check "source-copy refusal message" grep -q 'source repo' "$OUT_DIR/uninstall-sourcecopy.log"
check "source-copy skills survived" test -f "$SRCCOPY/skills/cheap-worker/SKILL.md"

ESCAPE_HOME="$(mktemp -d "$TMP_BASE/escape-home.XXXXXX")"
ESCAPE_OUT="$(mktemp -d "$TMP_BASE/escape-out.XXXXXX")"
CLEANUP_DIRS+=("$ESCAPE_HOME" "$ESCAPE_OUT")
ln -s "$ESCAPE_OUT" "$ESCAPE_HOME/.agents"
ES_RC=0
HOME="$ESCAPE_HOME" "$PROJECT_ROOT/scripts/install-skills.sh" --quiet >"$OUT_DIR/install-escape.log" 2>&1 || ES_RC=$?
check_eq "installer refuses a parent symlink escape" "1" "$ES_RC"
check "installer did not create the refused target" bash -c "! test -e '$ESCAPE_OUT/skills'"

if "$PROJECT_ROOT/scripts/uninstall-managed-skills.sh" --dry-run >"$OUT_DIR/uninstall-dry.log" 2>&1; then
    pass "uninstall --dry-run exits 0"
else
    fail "uninstall --dry-run failed"
fi
check "uninstall lists both managed skills" bash -c "grep -q 'cheap-worker' '$OUT_DIR/uninstall-dry.log' && grep -q 'phase-runner' '$OUT_DIR/uninstall-dry.log'"
check "uninstall did not delete anything" test -d "$HOME/.agents/skills/cheap-worker"

# ---------------------------------------------------------------------------
# 10. the installed skills were not touched by this test run
# ---------------------------------------------------------------------------
if [[ -f "$HOME/.agents/skills/cheap-worker/.installed-by-agent-orchestration" ]]; then
    pass "~/.agents/skills/cheap-worker is still the marked install (tests never install)"
fi

finish
