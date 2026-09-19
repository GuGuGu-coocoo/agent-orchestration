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
(cd "$repo" && "$NOTIFY" --print-message --simulate-exit 10 --task-id OFF2) >"$OUT_DIR/notify-msg-10.log" 2>&1 || true
(cd "$repo" && "$NOTIFY" --print-message --simulate-exit 2 --task-id OFF2) >"$OUT_DIR/notify-msg-2.log" 2>&1 || true
check "success message asks for review" grep -q '验收' "$OUT_DIR/notify-msg-0.log"
check "escalation message asks for a decision" grep -q '决策' "$OUT_DIR/notify-msg-10.log"
check "failure message names the exit code" grep -q 'exit=2' "$OUT_DIR/notify-msg-2.log"
check "message carries absolute paths" grep -q '/\.agent/current/RESULT.md' "$OUT_DIR/notify-msg-0.log"

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
(cd "$repo" && WORKER_NOTIFY_RUN_WORKER="$repo/.fake-worker.sh" "$NOTIFY" \
    --foreground --codex-thread "smoke-thread" --codex-bin "$repo/.fake-codex-fail" \
    --mode implement --task-id OFF2) >"$OUT_DIR/notify-fail.log" 2>&1 || true
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

# --- 6c. session auto-discovery (fixture Codex home, fail-safe) ------------------
FAKE_HOME="$repo/.fake-codex-home"
mkdir -p "$FAKE_HOME"
PROJ="$(cd "$repo" && pwd -P)"
NOW_MS="$(printf '%s' "$(date +%s)000")"
OLD_MS=$((NOW_MS - 3600000))

sqlite3 "$FAKE_HOME/thread_history_1.sqlite" \
    "CREATE TABLE thread_items(thread_id TEXT, created_at_ms INTEGER);"
sqlite3 "$FAKE_HOME/state_5.sqlite" \
    "CREATE TABLE threads(id TEXT, archived INTEGER, cwd TEXT, title TEXT, updated_at INTEGER);"

discover() {  # discover -> sets D_OUT / D_RC from --print-session
    D_OUT=""
    D_RC=0
    D_OUT="$(cd "$repo" && WORKER_NOTIFY_CODEX_HOME="$FAKE_HOME" "$NOTIFY" --print-session 2>/dev/null)" || D_RC=$?
}

# unique recent, non-archived session -> detected
sqlite3 "$FAKE_HOME/thread_history_1.sqlite" "INSERT INTO thread_items VALUES ('thread-solo', $NOW_MS);"
sqlite3 "$FAKE_HOME/state_5.sqlite" "INSERT INTO threads VALUES ('thread-solo',0,'/tmp/elsewhere','solo',1);"
discover
check_eq "discovery: unique recent session is detected" "0" "$D_RC"
check_eq "discovery: detected the right session" "thread-solo" "$(printf '%s' "$D_OUT" | cut -f1)"

# archived sessions are never returned
sqlite3 "$FAKE_HOME/state_5.sqlite" "UPDATE threads SET archived=1 WHERE id='thread-solo';"
discover
check_eq "discovery: archived-only -> exit 1" "1" "$D_RC"

# unique project-cwd match wins among several recent sessions
sqlite3 "$FAKE_HOME/thread_history_1.sqlite" \
    "INSERT INTO thread_items VALUES ('thread-other', $((NOW_MS + 1000))), ('thread-project', $((NOW_MS - 1000)));"
sqlite3 "$FAKE_HOME/state_5.sqlite" \
    "INSERT INTO threads VALUES ('thread-other',0,'/tmp/elsewhere','other',2),
                                ('thread-project',0,'$PROJ','project',3);"
discover
check_eq "discovery: unique project-cwd match wins" "0" "$D_RC"
check_eq "discovery: detected the project session" "thread-project" "$(printf '%s' "$D_OUT" | cut -f1)"

# two recent sessions for the same project -> refuse to guess (H04)
sqlite3 "$FAKE_HOME/state_5.sqlite" "UPDATE threads SET archived=0 WHERE id IN ('thread-solo','thread-other','thread-project');
                                      UPDATE threads SET cwd='$PROJ' WHERE id IN ('thread-other','thread-project');"
discover
check_eq "discovery: ambiguous sessions -> exit 3 (refuse to guess)" "3" "$D_RC"

# the handoff command must refuse to run on an ambiguous session
rm -f "$repo/.agent/current/RESULT.md"
NOTIFY_RC=0
(cd "$repo" && WORKER_NOTIFY_CODEX_HOME="$FAKE_HOME" "$NOTIFY" --mode implement --task-id OFF2) >"$OUT_DIR/notify-ambiguous.log" 2>&1 || NOTIFY_RC=$?
check_eq "worker-notify: ambiguous session -> exit 13" "13" "$NOTIFY_RC"
check "worker-notify: ambiguity message is explicit" grep -q 'refusing to guess' "$OUT_DIR/notify-ambiguous.log"

# old activity outside the window is not considered
sqlite3 "$FAKE_HOME/thread_history_1.sqlite" "DELETE FROM thread_items;"
sqlite3 "$FAKE_HOME/thread_history_1.sqlite" "INSERT INTO thread_items VALUES ('thread-old', $OLD_MS);"
discover
check_eq "discovery: stale activity -> exit 1" "1" "$D_RC"

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

# single-run lock (H03)
sleep 30 &
LOCKER=$!
mkdir -p "$hrepo/.agent/current/.worker.lock"
printf 'pid=%s\nrun_id=live\n' "$LOCKER" >"$hrepo/.agent/current/.worker.lock/info"
run_fake result 0 --allow-dirty --mode implement
check_eq "harness: live lock refuses a second worker -> exit 7" "7" "$FAKE_RC"
kill "$LOCKER" 2>/dev/null || true
wait "$LOCKER" 2>/dev/null || true
printf 'pid=999999\nrun_id=dead\n' >"$hrepo/.agent/current/.worker.lock/info"
run_fake result 0 --allow-dirty --mode implement
check_eq "harness: stale lock is taken over -> exit 0" "0" "$FAKE_RC"
check "harness: stale lock moved aside" bash -c "ls -d '$hrepo'/.agent/history/attempts/stale-locks/* >/dev/null 2>&1"
check "harness: lock released after the run" bash -c "! test -e '$hrepo/.agent/current/.worker.lock'"

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

# dirty tree handling + baseline evidence (M01)
printf 'print("local change")\n' >>"$hrepo/app.py"
run_fake result 0 --mode implement
check_eq "harness: dirty tree without --allow-dirty -> exit 1" "1" "$FAKE_RC"
run_fake result 0 --allow-dirty --mode implement
check_eq "harness: dirty tree with --allow-dirty -> exit 0" "0" "$FAKE_RC"
check "harness: BASELINE.md lists the dirty file" grep -q 'M app.py' "$hrepo/.agent/current/BASELINE.md"

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
