#!/usr/bin/env bash
# run-offline.sh - script-level smoke tests. No model calls, nothing is installed.
#
# Verifies:
#   - doctor.sh passes
#   - SKILL.md frontmatter is valid for both skills
#   - run-worker.sh fails fast without a Task / with an unknown model
#   - run-worker.sh --dry-run renders the prompt and resolves project/model correctly
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
check "doctor.sh checks the models" grep -q 'deepseek/deepseek-flash' "$OUT_DIR/doctor.log"

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

if (cd "$repo" && "$WORKER" --mode implement --model no/such-model) >"$OUT_DIR/bad-model.log" 2>&1; then
    fail "run-worker.sh should fail for unknown model"
else
    pass "run-worker.sh fails for unknown model"
fi
check "failure message mentions models" grep -q "not in 'opencode models'" "$OUT_DIR/bad-model.log"

# --- 4. dry-run ----------------------------------------------------------------
if (cd "$repo" && "$WORKER" --mode implement --dry-run) >"$OUT_DIR/dryrun.log" 2>&1; then
    pass "dry-run exits 0"
else
    fail "dry-run failed"
fi
check "dry-run reports the task" grep -q 'task         : OFF1' "$OUT_DIR/dryrun.log"
check "dry-run reports the model" grep -q 'model        : opencode/' "$OUT_DIR/dryrun.log"
check "dry-run reports the opencode command" grep -q 'opencode run --model' "$OUT_DIR/dryrun.log"

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
