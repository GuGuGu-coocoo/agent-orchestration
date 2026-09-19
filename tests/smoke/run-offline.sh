#!/usr/bin/env bash
# run-offline.sh - script-level smoke tests. No model calls, nothing is installed.
#
# Verifies:
#   - doctor.sh passes and checks the shared service
#   - SKILL.md frontmatter is valid for both skills
#   - run-worker.sh fails fast without a Task and has no --model flag
#   - run-worker.sh never passes --model or --standalone to opencode
#   - run-worker.sh --dry-run renders the prompt, session title and command
#   - status.sh, collect-result.sh, archive-task.sh behave as specified
#
# Usage: tests/smoke/run-offline.sh

set -euo pipefail

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$SMOKE_DIR/helpers.sh"

TEST_NAME="offline"
printf '== offline smoke tests ==\n'

# --- 1. builder and installer invariants -------------------------------------
info "source tree: $PROJECT_ROOT"

for s in cheap-worker phase-runner; do
    src="$PROJECT_ROOT/skills/$s/SKILL.md"
    check "SKILL.md exists for $s" test -f "$src"
    check "SKILL.md frontmatter has name" bash -c "head -20 '$src' | grep -q '^name: $s$'"
    check "SKILL.md frontmatter has description" bash -c "head -20 '$src' | grep -q '^description: '"
    check_eq "installed SKILL.md matches source for $s" \
        "$(shasum "$src" | awk '{print $1}')" \
        "$(shasum "$HOME/.agents/skills/$s/SKILL.md" | awk '{print $1}')"
done

check "other skills still present (docx)" test -f "$HOME/.agents/skills/docx/SKILL.md"
check "other skills still present (pdf)" test -f "$HOME/.agents/skills/pdf/SKILL.md"
check "other skills still present (pptx)" test -f "$HOME/.agents/skills/pptx/SKILL.md"
check "other skills still present (xlsx)" test -f "$HOME/.agents/skills/xlsx/SKILL.md"

# --- 2. doctor ----------------------------------------------------------------
if "$HOME/.agents/skills/cheap-worker/scripts/doctor.sh" --root "$SMOKE_DIR" >"$OUT_DIR/doctor.log" 2>&1; then
    pass "doctor.sh exits 0"
else
    fail "doctor.sh exited non-zero (see $OUT_DIR/doctor.log)"
fi
check "doctor.sh reports no problems" grep -q 'result: 0 problem' "$OUT_DIR/doctor.log"
check "doctor.sh checks the shared background service" grep -q 'background service' "$OUT_DIR/doctor.log"
check "doctor.sh verifies no --model is passed" grep -q 'never passes --model' "$OUT_DIR/doctor.log"
check "doctor.sh verifies no --standalone is used" grep -q 'never uses --standalone' "$OUT_DIR/doctor.log"

# --- 3. run-worker.sh precondition failures ------------------------------------
repo="$(new_repo smoke-offline)"
CLEANUP_DIRS+=("$repo")

if (cd "$repo" && "$WORKER" --mode implement) >"$OUT_DIR/no-task.log" 2>&1; then
    fail "run-worker.sh should fail without TASK.md"
else
    pass "run-worker.sh fails without TASK.md"
fi
check "failure message is clear" grep -q 'no Task found' "$OUT_DIR/no-task.log"

write_task "$repo" "OFF1" "implement" "objective" "existing" "desired" \
    "- app.py" "- app.py" "- everything else" \
    "- [ ] done" '`python3 app.py` exits 0' "none"

# --- 3b. no model configuration layer ------------------------------------------
worker_code="$(grep -v '^[[:space:]]*#' "$WORKER")"
if printf '%s\n' "$worker_code" | grep -q -- '--model'; then
    fail "run-worker.sh must not pass --model"
else
    pass "run-worker.sh never passes --model"
fi
if printf '%s\n' "$worker_code" | grep -q -- '--standalone'; then
    fail "run-worker.sh must not use --standalone"
else
    pass "run-worker.sh never uses --standalone"
fi

if (cd "$repo" && "$WORKER" --mode implement --model foo/bar) >"$OUT_DIR/model-flag.log" 2>&1; then
    fail "run-worker.sh should reject an unknown --model flag"
else
    pass "run-worker.sh rejects --model (no model layer in V1)"
fi
check "rejection message names the unknown argument" grep -q "unknown argument '--model'" "$OUT_DIR/model-flag.log"

# --- 4. dry-run ----------------------------------------------------------------
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

# --- 5. status / collect-result -------------------------------------------------
if (cd "$repo" && "$HOME/.agents/skills/cheap-worker/scripts/status.sh") >"$OUT_DIR/status.log" 2>&1; then
    pass "status.sh exits 0"
else
    fail "status.sh failed"
fi
check "status.sh shows the task id" grep -q 'task id      : OFF1' "$OUT_DIR/status.log"

if (cd "$repo" && "$HOME/.agents/skills/cheap-worker/scripts/collect-result.sh") >/dev/null 2>&1; then
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

if (cd "$repo" && "$HOME/.agents/skills/cheap-worker/scripts/collect-result.sh") >"$OUT_DIR/collect.log" 2>&1; then
    pass "collect-result.sh succeeds with a report"
else
    fail "collect-result.sh failed with a report present"
fi
check "collect-result.sh prints the report" grep -q 'Offline fixture' "$OUT_DIR/collect.log"

# --- 6. archive-task.sh ----------------------------------------------------------
ARCHIVER="$HOME/.agents/skills/cheap-worker/scripts/archive-task.sh"

if (cd "$repo" && "$ARCHIVER" --decision ACCEPT) >/dev/null 2>&1; then
    fail "archive-task.sh without --yes should refuse"
else
    pass "archive-task.sh refuses without --yes"
fi

mkdir -p "$repo/.agent/history"
if (cd "$repo" && "$ARCHIVER" --yes --decision ACCEPT) >"$OUT_DIR/archive.log" 2>&1; then
    pass "archive-task.sh archives with --yes"
else
    fail "archive-task.sh failed with --yes (see $OUT_DIR/archive.log)"
fi
check "TASK.md was archived" bash -c "ls '$repo'/\.agent/history/*OFF1/TASK.md >/dev/null 2>&1"
check "RESULT.md was archived" bash -c "ls '$repo'/\.agent/history/*OFF1/RESULT.md >/dev/null 2>&1"
check "decision record written" bash -c "grep -q 'Decision: ACCEPT' '$repo'/\.agent/history/*OFF1/REVIEW_DECISION.md"
check "current workspace re-seeded with blank TASK.md" bash -c "grep -q '<PHASE>-<NN>' '$repo/.agent/current/TASK.md'"
check "current RESULT.md cleared" bash -c "! test -e '$repo/.agent/current/RESULT.md'"

# --- 6b. worker-notify.sh --------------------------------------------------------
NOTIFY="$HOME/.agents/skills/cheap-worker/scripts/worker-notify.sh"

if "$NOTIFY" --help >"$OUT_DIR/notify-help.log" 2>&1; then
    pass "worker-notify.sh --help exits 0"
else
    fail "worker-notify.sh --help failed"
fi

(cd "$repo" && "$NOTIFY" --print-message --simulate-exit 0 --task-id OFF2) >"$OUT_DIR/notify-msg-0.log" 2>&1 || true

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
    pass "worker-notify.sh runs without --codex-thread (auto-discovery / no-notify)"
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

# --- 6c. session identity: explicit only, fail closed (H04) ----------------------
FAKE_HOME="$repo/.fake-codex-home"
mkdir -p "$FAKE_HOME"
sqlite3 "$FAKE_HOME/state_5.sqlite" \
    "CREATE TABLE threads(id TEXT, archived INTEGER, cwd TEXT, title TEXT, updated_at INTEGER);"
sqlite3 "$FAKE_HOME/state_5.sqlite" \
    "INSERT INTO threads VALUES ('sess-ok',0,'/tmp/p','ok',1), ('sess-archived',1,'/tmp/a','arch',2);"

NOTIFY_HOME_TEST() {
    (cd "$repo" && WORKER_NOTIFY_CODEX_HOME="$FAKE_HOME" "$@")
}

# no identity -> refuse (exit 1), never guess
N_RC=0
NOTIFY_HOME_TEST env -u CODEX_THREAD_ID "$NOTIFY" --print-target >"$OUT_DIR/target-none.log" 2>&1 || N_RC=$?
check_eq "identity: no CODEX_THREAD_ID and no flag -> exit 1" "1" "$N_RC"
check "identity: refusal message is explicit" grep -q 'no target' "$OUT_DIR/target-none.log"

# explicit flag wins
N_RC=0
NOTIFY_HOME_TEST "$NOTIFY" --print-target --codex-thread sess-ok >"$OUT_DIR/target-flag.log" 2>&1 || N_RC=$?
check_eq "identity: explicit --codex-thread is used" "0" "$N_RC"
check "identity: prints the explicit target" grep -q '^sess-ok' "$OUT_DIR/target-flag.log"

# CODEX_THREAD_ID from the calling runtime is honored
N_RC=0
NOTIFY_HOME_TEST env CODEX_THREAD_ID=sess-ok "$NOTIFY" --print-target >"$OUT_DIR/target-env.log" 2>&1 || N_RC=$?
check_eq "identity: CODEX_THREAD_ID is honored" "0" "$N_RC"

# archived target is refused with a hint
N_RC=0
NOTIFY_HOME_TEST "$NOTIFY" --print-target --codex-thread sess-archived >"$OUT_DIR/target-arch.log" 2>&1 || N_RC=$?
check_eq "identity: archived target -> exit 3" "3" "$N_RC"
check "identity: archived hint present" grep -q 'ARCHIVED' "$OUT_DIR/target-arch.log"

# handoff without an identity fails closed instead of guessing
rm -f "$repo/.agent/current/RESULT.md"
N_RC=0
NOTIFY_HOME_TEST env -u CODEX_THREAD_ID "$NOTIFY" --mode implement --task-id OFF2 >"$OUT_DIR/notify-no-target.log" 2>&1 || N_RC=$?
check_eq "worker-notify: no target -> exit 14 (refusing to guess)" "14" "$N_RC"
check "worker-notify: refusal is explicit" grep -q 'refusing to guess' "$OUT_DIR/notify-no-target.log"

# message wording for the new exit codes (N01)
(NOTIFY_HOME_TEST "$NOTIFY" --print-message --simulate-exit 0 --task-id OFF2) >"$OUT_DIR/notify-msg-0.log" 2>&1 || true
(NOTIFY_HOME_TEST "$NOTIFY" --print-message --simulate-exit 5 --task-id OFF2) >"$OUT_DIR/notify-msg-5.log" 2>&1 || true
(NOTIFY_HOME_TEST "$NOTIFY" --print-message --simulate-exit 6 --task-id OFF2) >"$OUT_DIR/notify-msg-6.log" 2>&1 || true
(NOTIFY_HOME_TEST "$NOTIFY" --print-message --simulate-exit 7 --task-id OFF2) >"$OUT_DIR/notify-msg-7.log" 2>&1 || true
(NOTIFY_HOME_TEST "$NOTIFY" --print-message --simulate-exit 10 --task-id OFF2) >"$OUT_DIR/notify-msg-10.log" 2>&1 || true
(NOTIFY_HOME_TEST "$NOTIFY" --print-message --simulate-exit 2 --task-id OFF2) >"$OUT_DIR/notify-msg-2.log" 2>&1 || true
check "success message asks for review" grep -q '验收' "$OUT_DIR/notify-msg-0.log"
check "exit 5 asks to read the existing RESULT" grep -q '有 RESULT.md' "$OUT_DIR/notify-msg-5.log"
check "exit 6 asks to inspect current/ and attempts/" grep -q 'attempts' "$OUT_DIR/notify-msg-6.log"
check "exit 7 says a worker is already running" grep -q '已有 worker' "$OUT_DIR/notify-msg-7.log"
check "escalation message asks for a decision" grep -q '决策' "$OUT_DIR/notify-msg-10.log"
check "failure (no report) message says so" grep -q '无报告' "$OUT_DIR/notify-msg-2.log"
check "message carries absolute paths" grep -q '/\.agent/current/RESULT.md' "$OUT_DIR/notify-msg-0.log"

# --- 6d. run-worker.sh safety harness (fake opencode, offline) --------------------
HARNESS="$repo/.harness"
rm -rf "$HARNESS"
mkdir -p "$HARNESS/bin"
cp "$SMOKE_DIR/assets/fake-opencode.sh" "$HARNESS/bin/opencode"
chmod +x "$HARNESS/bin/opencode"

hrepo="$(new_repo smoke-harness)"
CLEANUP_DIRS+=("$hrepo")
write_task "$hrepo" "H01" "implement" "harness objective" "existing behavior" "desired behavior" \
    "- app.py" "- app.py" "- any other file" "- [ ] works" '`python3 app.py` exits 0' "none"
printf 'print("hi")\n' >"$hrepo/app.py"
commit_all "$hrepo" "harness baseline"
HROOT="$(cd "$hrepo" && pwd -P)"
HRUN="$HOME/.agents/skills/cheap-worker/scripts/run-worker.sh"

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

# single-run lock identity (H03)
sleep 30 &
LOCKER=$!
mkdir -p "$hrepo/.agent/current/.worker.lock"
printf 'pid=%s\nworker_pid=\nrun_id=live\n' "$LOCKER" >"$hrepo/.agent/current/.worker.lock/info"
run_fake result 0 --allow-dirty --mode implement
check_eq "harness: live wrapper lock refuses a second worker -> exit 7" "7" "$FAKE_RC"
kill "$LOCKER" 2>/dev/null || true
wait "$LOCKER" 2>/dev/null || true

# dead wrapper but a recorded live worker pid must still refuse (H03 core case)
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

# cancellation must KEEP the lock until execution is proven stopped (H03)
SLOWBIN="$HARNESS/slowbin"
mkdir -p "$SLOWBIN"
cp "$SMOKE_DIR/assets/fake-opencode.sh" "$SLOWBIN/opencode"
chmod +x "$SLOWBIN/opencode"
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

# TASK.md validation (M02)
cp "$hrepo/.agent/current/TASK.md" "$HARNESS/TASK.good"
printf '# Task\n\n## Task ID\nH01\n\n## Mode\nimplement\n' >"$hrepo/.agent/current/TASK.md"
run_fake result 0 --allow-dirty --mode implement
check_eq "harness: incomplete TASK.md -> exit 1" "1" "$FAKE_RC"
cp "$HARNESS/TASK.good" "$hrepo/.agent/current/TASK.md"
run_fake result 0 --allow-dirty --mode implement --task-id OTHER
check_eq "harness: --task-id mismatch -> exit 1" "1" "$FAKE_RC"
run_fake result 0 --allow-dirty --mode verify
check_eq "harness: --mode mismatch -> exit 1" "1" "$FAKE_RC"

# template list placeholders are still placeholders (M02)
cp "$HARNESS/TASK.good" "$hrepo/.agent/current/TASK.md"
sed -i '' 's/^- \[ \] works$/- [ ] <observable, checkable criterion>/' "$hrepo/.agent/current/TASK.md"
sed -i '' 's/^- app\.py$/- <exact files>/' "$hrepo/.agent/current/TASK.md"
run_fake result 0 --allow-dirty --mode implement
check_eq "harness: list placeholders rejected -> exit 1" "1" "$FAKE_RC"
check "harness: placeholder message names the section" grep -q 'placeholder' "$OUT_DIR/fake-run.log"
cp "$HARNESS/TASK.good" "$hrepo/.agent/current/TASK.md"

# REVIEW.md without a Task ID is rejected (M02)
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

# dirty tree handling + baseline evidence (M01)
printf 'print("local change")\n' >>"$hrepo/app.py"
run_fake result 0 --mode implement
check_eq "harness: dirty tree without --allow-dirty -> exit 1" "1" "$FAKE_RC"
run_fake result 0 --allow-dirty --mode implement
check_eq "harness: dirty tree with --allow-dirty -> exit 0" "0" "$FAKE_RC"
check "harness: BASELINE.md lists the dirty file" grep -q 'M app.py' "$hrepo/.agent/current/BASELINE.md"
check "harness: BASELINE.patch holds the full pre-run patch" grep -q 'local change' "$hrepo/.agent/current/BASELINE.patch"

# cwd pinning when invoked from elsewhere (H02)
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

# --- 7. collect-result conflict + installer boundaries -----------------------------
cat >"$repo/.agent/current/RESULT.md" <<'EOF'
# Result

## Task ID
OFF3

## Status
DONE
EOF
cat >"$repo/.agent/current/ESCALATION.md" <<'EOF'
# Escalation

## Task ID
OFF3

## Current Blocker
fixture
EOF
CR_RC=0
(cd "$repo" && "$HOME/.agents/skills/cheap-worker/scripts/collect-result.sh") >"$OUT_DIR/collect-both.log" 2>&1 || CR_RC=$?
check_eq "collect-result: both reports -> exit 4" "4" "$CR_RC"
check "collect-result: prints the RESULT body" grep -q 'Status' "$OUT_DIR/collect-both.log"
check "collect-result: prints the ESCALATION body" grep -q 'Current Blocker' "$OUT_DIR/collect-both.log"
rm -f "$repo/.agent/current/RESULT.md" "$repo/.agent/current/ESCALATION.md"

# --target is a test-only mechanism
if (AGENT_ORCHESTRATION_TEST_TARGET=0 "$PROJECT_ROOT/scripts/install-skills.sh" --target "$OUT_DIR/forbidden-target/skills" --quiet) >"$OUT_DIR/install-target-gate.log" 2>&1; then
    fail "installer --target must be refused without the test env var"
else
    pass "installer --target is refused without AGENT_ORCHESTRATION_TEST_TARGET=1"
fi
check "installer target gate message" grep -q 'test-only mechanism' "$OUT_DIR/install-target-gate.log"

# a fresh HOME must install (L01)
FRESH_HOME="$(mktemp -d "$TMP_BASE/fresh-home.XXXXXX")"
CLEANUP_DIRS+=("$FRESH_HOME")
if HOME="$FRESH_HOME" "$PROJECT_ROOT/scripts/install-skills.sh" --quiet >"$OUT_DIR/install-fresh-home.log" 2>&1; then
    pass "installer works on a fresh HOME"
else
    fail "installer failed on a fresh HOME (see $OUT_DIR/install-fresh-home.log)"
fi
check "fresh HOME install created both skills" test -f "$FRESH_HOME/.agents/skills/phase-runner/SKILL.md"

# physical-target policy: a parent symlink escaping $HOME is refused (M05)
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

# uninstaller must refuse a source-tree target even with the test gate (M05)
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

# no-HEAD repository: BASELINE.patch explains itself instead of being silently empty
NOHREPO="$(new_repo smoke-no-head)"
CLEANUP_DIRS+=("$NOHREPO")
write_task "$NOHREPO" "N01" "implement" "no-head objective" "none" "something" \
    "- app.py" "- app.py" "- any other file" "- [ ] works" '`python3 app.py` exits 0' "none"
printf 'print("hi")\n' >"$NOHREPO/app.py"
NOH_RC=0
( cd "$NOHREPO" && PATH="$HARNESS/bin:$PATH" FAKE_OPENCODE_MODE=result FAKE_TASK_ID=N01 \
    "$HRUN" --allow-dirty --mode implement ) >"$OUT_DIR/no-head.log" 2>&1 || NOH_RC=$?
check_eq "no-HEAD repo runs with --allow-dirty -> exit 0" "0" "$NOH_RC"
check "no-HEAD BASELINE.patch explains the limitation" grep -q 'no HEAD yet' "$NOHREPO/.agent/current/BASELINE.patch"

# --- 7b. check-state fail-closed cases (M03) ----------------------------------------
CSREPO="$(new_repo smoke-checkstate)"
CLEANUP_DIRS+=("$CSREPO")
mkdir -p "$CSREPO/.agent/phases/A" "$CSREPO/.agent/current"
sstate() {  # sstate <queue-json> <run-state-json> <task-md> <state-json>
    printf '%s' "$1" >"$CSREPO/.agent/phases/A/TASK_QUEUE.json"
    printf '%s' "$2" >"$CSREPO/.agent/RUN_STATE.json"
    printf '%s' "$3" >"$CSREPO/.agent/current/TASK.md"
    printf '%s' "$4" >"$CSREPO/.agent/current/STATE.json"
    rm -f "$CSREPO/.agent/current/RESULT.md" "$CSREPO/.agent/current/ESCALATION.md"
}
CS="$HOME/.agents/skills/cheap-worker/scripts/check-state.sh"

sstate '{broken' '{"current_phase":"A","current_task":"A02","status":"running"}' '' '{}'
CS_RC=0
(cd "$CSREPO" && "$CS") >"$OUT_DIR/cs-badjson.log" 2>&1 || CS_RC=$?
check_eq "check-state: broken queue JSON -> exit 1" "1" "$CS_RC"
check "check-state: broken JSON is reported" grep -qE 'not a JSON object|not valid JSON' "$OUT_DIR/cs-badjson.log"

sstate '{"tasks":[{"id":"A02","status":"in_progress"}]}' \
       '{"current_phase":"A","current_task":"WRONG","status":"running"}' \
       '# Task

## Task ID
A02' '{"task_id":"A02"}'
CS_RC=0
(cd "$CSREPO" && "$CS") >"$OUT_DIR/cs-runstate.log" 2>&1 || CS_RC=$?
check_eq "check-state: RUN_STATE task mismatch -> exit 1" "1" "$CS_RC"
check "check-state: mismatch is reported" grep -q 'does not match the queue' "$OUT_DIR/cs-runstate.log"

sstate '{"tasks":[{"id":"A02","status":"in_progress"},{"id":"A03","status":"in_progress"}]}' \
       '{"current_phase":"A","current_task":"A02","status":"running"}' \
       '# Task

## Task ID
A02' '{"task_id":"A02"}'
CS_RC=0
(cd "$CSREPO" && "$CS") >"$OUT_DIR/cs-two-inprogress.log" 2>&1 || CS_RC=$?
check_eq "check-state: two in_progress -> exit 1" "1" "$CS_RC"
check "check-state: two in_progress reported" grep -q 'more than one Task is in_progress' "$OUT_DIR/cs-two-inprogress.log"

mkdir -p "$CSREPO/.agent/history/20260101T000000Z-A02"
sstate '{"tasks":[{"id":"A02","status":"in_progress"}]}' \
       '{"current_phase":"A","current_task":"A02","status":"running"}' \
       '# Task

## Task ID
A02' '{"task_id":"A02"}'
CS_RC=0
(cd "$CSREPO" && "$CS") >"$OUT_DIR/cs-archived-not-done.log" 2>&1 || CS_RC=$?
check_eq "check-state: archive without done -> exit 1" "1" "$CS_RC"
check "check-state: suggests marking done" grep -q 'mark it done' "$OUT_DIR/cs-archived-not-done.log"

# --- 7c. check-state fail-closed matrix (round-3 M03) ------------------------------
cs_case() {  # cs_case <name> <queue-content> <runstate-content> [result-content] [state-content]
    local name="$1" q="$2" rs="$3" res="${4:-}" st="${5:-}"
    printf '%s' "$q" >"$CSREPO/.agent/phases/A/TASK_QUEUE.json"
    printf '%s' "$rs" >"$CSREPO/.agent/RUN_STATE.json"
    printf '# Task\n\n## Task ID\nA02\n' >"$CSREPO/.agent/current/TASK.md"
    if [[ -n "$st" ]]; then
        printf '%s' "$st" >"$CSREPO/.agent/current/STATE.json"
    else
        printf '%s' '{"task_id":"A02","run_id":"r1","status":"running"}' >"$CSREPO/.agent/current/STATE.json"
    fi
    rm -f "$CSREPO/.agent/current/RESULT.md" "$CSREPO/.agent/current/ESCALATION.md"
    rm -rf "$CSREPO/.agent/history" "$CSREPO/.agent/current/.worker.lock"
    [[ -n "$res" ]] && printf '%s' "$res" >"$CSREPO/.agent/current/RESULT.md"
    CS_RC=0
    (cd "$CSREPO" && "$CS") >"$OUT_DIR/cs-${name}.log" 2>&1 || CS_RC=$?
}

cs_case empty-runstate '{"tasks":[{"id":"A02","status":"in_progress"}]}' ''
check_eq "check-state: empty RUN_STATE -> exit 1" "1" "$CS_RC"
check "check-state: empty RUN_STATE reported" grep -q 'empty or not a JSON object' "$OUT_DIR/cs-empty-runstate.log"

cs_case null-queue 'null' '{"current_phase":"A","current_task":"A02","status":"running"}'
check_eq "check-state: null queue -> exit 1" "1" "$CS_RC"
check "check-state: null queue reported" grep -q 'not a JSON object' "$OUT_DIR/cs-null-queue.log"

rm -f "$CSREPO/.agent/phases/A/TASK_QUEUE.json"
printf '%s' '{"current_phase":"A","current_task":"A02","status":"running"}' >"$CSREPO/.agent/RUN_STATE.json"
CS_RC=0
(cd "$CSREPO" && "$CS") >"$OUT_DIR/cs-missing-queue.log" 2>&1 || CS_RC=$?
check_eq "check-state: missing queue while running -> exit 1" "1" "$CS_RC"
check "check-state: missing queue reported" grep -q 'is missing' "$OUT_DIR/cs-missing-queue.log"

cs_case escalated '{"tasks":[{"id":"A02","status":"escalated"}]}' '{"current_phase":"A","current_task":"A02","status":"running"}'
check_eq "check-state: escalated task -> exit 1" "1" "$CS_RC"
check "check-state: escalated verdict" grep -q 'verdict: ESCALATED' "$OUT_DIR/cs-escalated.log"

cs_case checkpoint '{"tasks":[{"id":"A02","status":"pending"}]}' '{"current_phase":"A","current_task":"","status":"awaiting_human_qa"}'
check_eq "check-state: checkpoint with pending -> exit 1" "1" "$CS_RC"
check "check-state: checkpoint verdict" grep -q 'verdict: CHECKPOINT' "$OUT_DIR/cs-checkpoint.log"
check "check-state: checkpoint contradiction reported" grep -q 'still has pending' "$OUT_DIR/cs-checkpoint.log"

cs_case bad-result '{"tasks":[{"id":"A02","status":"in_progress"}]}' \
    '{"current_phase":"A","current_task":"A02","status":"running"}' \
    '# Result

## Task ID
A02

## Status
FAILED'
check_eq "check-state: RESULT not DONE -> exit 1" "1" "$CS_RC"
check "check-state: unacceptable report reported" grep -q 'not acceptable' "$OUT_DIR/cs-bad-result.log"

# survivor lock: a live worker_pid must produce WORKER_RUNNING, not "stale"
sleep 30 &
SURV=$!
cs_case survivor-lock '{"tasks":[{"id":"A02","status":"in_progress"}]}' '{"current_phase":"A","current_task":"A02","status":"running"}'
mkdir -p "$CSREPO/.agent/current/.worker.lock"
printf 'pid=999999\nworker_pid=%s\nrun_id=survivor\n' "$SURV" >"$CSREPO/.agent/current/.worker.lock/info"
CS_RC=0
(cd "$CSREPO" && "$CS") >"$OUT_DIR/cs-survivor-lock.log" 2>&1 || CS_RC=$?
check_eq "check-state: live worker_pid -> exit 1" "1" "$CS_RC"
check "check-state: live worker_pid verdict" grep -q 'verdict: WORKER_RUNNING' "$OUT_DIR/cs-survivor-lock.log"
rm -rf "$CSREPO/.agent/current/.worker.lock"
kill "$SURV" 2>/dev/null || true
wait "$SURV" 2>/dev/null || true

# --- 7c-2. schema matrix from round 4 (M03) ----------------------------------------
cs_case number-id '{"tasks":[{"id":42,"status":"pending"}]}' '{"current_phase":"A","status":"running"}'
check_eq "check-state: numeric Task id -> exit 1" "1" "$CS_RC"
check "check-state: numeric id reported" grep -q 'missing/empty/non-string id' "$OUT_DIR/cs-number-id.log"

cs_case missing-id '{"tasks":[{"status":"pending"}]}' '{"current_phase":"A","status":"running"}'
check_eq "check-state: missing Task id -> exit 1" "1" "$CS_RC"

cs_case empty-id '{"tasks":[{"id":"","status":"pending"}]}' '{"current_phase":"A","status":"running"}'
check_eq "check-state: empty Task id -> exit 1" "1" "$CS_RC"

cs_case missing-status '{"tasks":[{"id":"A02"}]}' '{"current_phase":"A","status":"running"}'
check_eq "check-state: missing Task status -> exit 1" "1" "$CS_RC"

cs_case duplicate-id '{"tasks":[{"id":"A02","status":"pending"},{"id":"A02","status":"pending"}]}' \
    '{"current_phase":"A","current_task":"A02","status":"running"}'
check_eq "check-state: duplicate Task ids -> exit 1" "1" "$CS_RC"
check "check-state: duplicate ids reported" grep -q 'duplicate Task ids' "$OUT_DIR/cs-duplicate-id.log"

cs_case no-phase '{"tasks":[{"id":"A02","status":"pending"}]}' '{"status":"running"}'
check_eq "check-state: running without a phase -> exit 1" "1" "$CS_RC"
check "check-state: phase requirement reported" grep -q 'requires a current_phase' "$OUT_DIR/cs-no-phase.log"

cs_case broken-state '{"tasks":[{"id":"A02","status":"in_progress"}]}' \
    '{"current_phase":"A","current_task":"A02","status":"running"}' '' '{broken'
check_eq "check-state: broken STATE.json -> exit 1" "1" "$CS_RC"
check "check-state: broken STATE reported" grep -q 'STATE.json exists but is empty or not a JSON object' "$OUT_DIR/cs-broken-state.log"

# positive controls: the fixes must not block legitimate states
cs_case valid-pending '{"tasks":[{"id":"A02","status":"pending"}]}' \
    '{"current_phase":"A","current_task":"","status":"running"}' '' '{"task_id":"","run_id":"","status":"idle"}'
check_eq "check-state: valid pending -> exit 0" "0" "$CS_RC"
check "check-state: valid pending verdict" grep -q 'verdict: NEXT' "$OUT_DIR/cs-valid-pending.log"

cs_case idle-empty '{"tasks":[]}' '{"status":"idle"}' '' '{"task_id":"","run_id":"","status":"idle"}'
check_eq "check-state: idle intake -> exit 0" "0" "$CS_RC"
check "check-state: idle verdict stays EMPTY" grep -q 'verdict: EMPTY' "$OUT_DIR/cs-idle-empty.log"

# --- 7d. phase-driver obeys check-state (offline, no model calls) -------------------
DREPO="$(new_repo smoke-driver-gate)"
CLEANUP_DIRS+=("$DREPO")
mkdir -p "$DREPO/.agent/phases/A/history" "$DREPO/.agent/current"
printf '%s' '{"tasks":[{"id":"A02","status":"pending"}]}' >"$DREPO/.agent/phases/A/TASK_QUEUE.json"
printf '%s' '{"current_phase":"A","current_task":"","status":"awaiting_human_qa"}' >"$DREPO/.agent/RUN_STATE.json"
printf '# Phase A\n' >"$DREPO/.agent/phases/A/PHASE.md"
DG_RC=0
REPO="$DREPO" SMOKE_DIR="$SMOKE_DIR" REWORK_MODE=0 \
    bash "$SMOKE_DIR/lib/phase-driver.sh" >"$OUT_DIR/driver-gate.log" 2>&1 || DG_RC=$?
check_eq "driver stops on a checkpoint verdict -> exit 2" "2" "$DG_RC"
check "driver logged the stop verdict" grep -q 'stop verdict CHECKPOINT' "$OUT_DIR/driver-gate.log"

# a WORKER_RUNNING verdict must stop WITHOUT rewriting TASK.md (round-4 M04)
LLREPO="$(new_repo smoke-driver-live-lock)"
CLEANUP_DIRS+=("$LLREPO")
mkdir -p "$LLREPO/.agent/phases/A/history" "$LLREPO/.agent/current"
printf '%s' '{"phase":"A","status":"running","tasks":[{"id":"A02","title":"add shutdown(seconds)","mode":"implement","status":"in_progress","history":[]}]}' >"$LLREPO/.agent/phases/A/TASK_QUEUE.json"
printf '%s' '{"current_phase":"A","current_task":"A02","status":"running"}' >"$LLREPO/.agent/RUN_STATE.json"
printf '# Task\n\n## Task ID\nA02\n\n## Mode\nimplement\n\n## Marker\nAUDIT ORIGINAL DEFINITION\n' >"$LLREPO/.agent/current/TASK.md"
printf '%s' '{"task_id":"A02","run_id":"r1","status":"running"}' >"$LLREPO/.agent/current/STATE.json"
sleep 30 &
SURV2=$!
mkdir -p "$LLREPO/.agent/current/.worker.lock"
printf 'pid=999999\nworker_pid=%s\nrun_id=live\n' "$SURV2" >"$LLREPO/.agent/current/.worker.lock/info"
LL_RC=0
REPO="$LLREPO" SMOKE_DIR="$SMOKE_DIR" REWORK_MODE=0 \
    bash "$SMOKE_DIR/lib/phase-driver.sh" >"$OUT_DIR/driver-live-lock.log" 2>&1 || LL_RC=$?
check_eq "driver stops on WORKER_RUNNING -> exit 2" "2" "$LL_RC"
check "driver wrote no worker log" bash -c "[ ! -d '$LLREPO/.agent/current/logs' ] || [ -z \"\$(ls -A '$LLREPO/.agent/current/logs')\" ]"
check "TASK.md was NOT rewritten" grep -q 'AUDIT ORIGINAL DEFINITION' "$LLREPO/.agent/current/TASK.md"
check "the phase history copy was not created" bash -c "! test -e '$LLREPO/.agent/phases/A/history/TASK-A02.md'"
rm -rf "$LLREPO/.agent/current/.worker.lock"
kill "$SURV2" 2>/dev/null || true
wait "$SURV2" 2>/dev/null || true

# --- 7e. installer must not create a target it will refuse (M05 LOW) ----------------
ESCAPE_HOME="$(mktemp -d "$TMP_BASE/escape-home.XXXXXX")"
ESCAPE_OUT="$(mktemp -d "$TMP_BASE/escape-out.XXXXXX")"
CLEANUP_DIRS+=("$ESCAPE_HOME" "$ESCAPE_OUT")
ln -s "$ESCAPE_OUT" "$ESCAPE_HOME/.agents"
ES_RC=0
HOME="$ESCAPE_HOME" "$PROJECT_ROOT/scripts/install-skills.sh" --quiet >"$OUT_DIR/install-escape.log" 2>&1 || ES_RC=$?
check_eq "installer refuses a parent symlink escape" "1" "$ES_RC"
check "installer did not create the refused target" bash -c "! test -e '$ESCAPE_OUT/skills'"

# --- 8. uninstall safety (dry-run only) -------------------------------------------
if "$PROJECT_ROOT/scripts/uninstall-managed-skills.sh" --dry-run >"$OUT_DIR/uninstall-dry.log" 2>&1; then
    pass "uninstall --dry-run exits 0"
else
    fail "uninstall --dry-run failed"
fi
check "uninstall lists both managed skills" bash -c "grep -q 'cheap-worker' '$OUT_DIR/uninstall-dry.log' && grep -q 'phase-runner' '$OUT_DIR/uninstall-dry.log'"
check "uninstall keeps siblings" bash -c "grep -q 'keep: .*docx' '$OUT_DIR/uninstall-dry.log'"
check "uninstall did not delete anything" test -d "$HOME/.agents/skills/cheap-worker"

finish
