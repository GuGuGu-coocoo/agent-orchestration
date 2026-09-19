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

if (cd "$repo" && "$NOTIFY" --mode implement) >"$OUT_DIR/notify-no-thread.log" 2>&1; then
    fail "worker-notify.sh should require --codex-thread"
else
    pass "worker-notify.sh requires --codex-thread"
fi
check "requirement message is clear" grep -q 'codex-thread NAME is required' "$OUT_DIR/notify-no-thread.log"

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

# --- 7. uninstall safety (dry-run only) -------------------------------------------
if "$PROJECT_ROOT/scripts/uninstall-managed-skills.sh" --dry-run >"$OUT_DIR/uninstall-dry.log" 2>&1; then
    pass "uninstall --dry-run exits 0"
else
    fail "uninstall --dry-run failed"
fi
check "uninstall lists both managed skills" bash -c "grep -q 'cheap-worker' '$OUT_DIR/uninstall-dry.log' && grep -q 'phase-runner' '$OUT_DIR/uninstall-dry.log'"
check "uninstall keeps siblings" bash -c "grep -q 'keep: .*docx' '$OUT_DIR/uninstall-dry.log'"
check "uninstall did not delete anything" test -d "$HOME/.agents/skills/cheap-worker"

finish
