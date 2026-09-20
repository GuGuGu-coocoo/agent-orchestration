#!/usr/bin/env bash
# helpers.sh - shared test scaffolding. Not executed directly; sourced by test scripts.
#
# Design notes:
#   - Tests run the scripts from THIS repository (skills/*/scripts), not from
#     ~/.agents/skills, so a development checkout is tested before it is
#     installed and the installed copy is never touched.
#   - No EXIT trap (bash 3.2 fires inherited traps in command-substitution
#     subshells). Each test calls `finish`, which performs cleanup explicitly.
#   - Every test creates throwaway git repos under the system temp directory.
#     No test ever touches a real user project.
#   - Live helpers always return 0 and record the exit code in LAST_EXIT, so
#     `set -e` cannot abort the test before its assertions run.
#   - Set SMOKE_KEEP_REPOS=1 to keep the temp repos for inspection.

set -euo pipefail

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SMOKE_DIR/../.." && pwd)"
CW_SCRIPTS="$PROJECT_ROOT/skills/cheap-worker/scripts"
PR_SCRIPTS="$PROJECT_ROOT/skills/phase-runner/scripts"
WORKER="$CW_SCRIPTS/run-worker.sh"
CHECK_STATE="$CW_SCRIPTS/check-state.sh"
ARCHIVER="$CW_SCRIPTS/archive-task.sh"
NOTIFY="$CW_SCRIPTS/worker-notify.sh"
STATUS="$CW_SCRIPTS/status.sh"
DOCTOR="$CW_SCRIPTS/doctor.sh"
COLLECT="$CW_SCRIPTS/collect-result.sh"
RUN_PHASE="$PR_SCRIPTS/run-phase.sh"
PHASE_GATE="$PR_SCRIPTS/phase-gate.sh"
OUT_DIR="$SMOKE_DIR/.out"
TMP_BASE="${TMPDIR:-/tmp}"

# Model: live tests use OpenCode's configured default model, exactly like the
# worker does in production. There is no model override here on purpose; to test
# against a specific model, change OpenCode's own configuration first.

TEST_NAME="test"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
LAST_EXIT=0
CLEANUP_DIRS=()

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '  PASS  %s\n' "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '  FAIL  %s\n' "$*"; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); printf '  SKIP  %s\n' "$*"; }
info() { printf '  info  %s\n' "$*"; }

check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc"
    fi
}

check_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$desc"
    else
        fail "$desc (expected '$expected', got '$actual')"
    fi
}

# Some sandboxes refuse to create commits (a gated git shim returns success
# without writing a commit). Assertions that need a real HEAD are then reported as
# SKIP rather than FAIL, so the suite is honest in that environment instead of
# reporting a false pass. Probe once, at source time.
GIT_COMMIT_OK=1
probe_git_commit() {
    local d
    d="$(mktemp -d "$TMP_BASE/git-probe.XXXXXX")"
    if (
        cd "$d" || exit 1
        git init -q || exit 1
        git config user.email "probe@test.local" || exit 1
        git config user.name "Probe" || exit 1
        : >probe.txt || exit 1
        git add probe.txt || exit 1
        git commit -qm probe >/dev/null 2>&1 || exit 1
        git rev-parse --verify -q HEAD >/dev/null 2>&1 || exit 1
    ); then
        GIT_COMMIT_OK=1
    else
        GIT_COMMIT_OK=0
    fi
    rm -rf "$d"
}
probe_git_commit

# check_commit <desc> <cmd...> - like check, but skipped when a fixture commit is
# not possible in this environment (the two assertions that need a real HEAD).
check_commit() {
    local desc="$1"; shift
    if [[ "$GIT_COMMIT_OK" -eq 1 ]]; then
        check "$desc" "$@"
    else
        skip "$desc (needs a real HEAD; git commit is unavailable here)"
    fi
}

# file_hash <path> - stable content hash, portable across macOS (shasum) and
# Linux (sha256sum). Fails loudly when neither tool exists: a missing hasher
# must never turn into "two empty hashes are equal" (a silent false pass).
file_hash() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        printf 'file_hash: neither shasum nor sha256sum is available\n' >&2
        return 1
    fi
}

# agent_manifest <repo> - sorted dirs + content hashes of the WHOLE .agent tree,
# so a refusal can be proven byte-identical (no new files, no new directories).
agent_manifest() {
    local repo="$1" p
    (
        cd "$repo" || exit 1
        find .agent \( -type f -o -type d \) | LC_ALL=C sort | while IFS= read -r p; do
            if [[ -d "$p" ]]; then
                printf 'dir  %s\n' "$p"
            else
                printf 'file %s %s\n' "$(file_hash "$p")" "$p"
            fi
        done
    )
}

# new_repo <name> -> creates a temp git repo, echoes its path
new_repo() {
    local name="$1"
    local dir
    dir="$(mktemp -d "$TMP_BASE/${name}.XXXXXX")"
    (
        cd "$dir" || exit 1
        git init -q
        git config user.email "smoke@test.local"
        git config user.name "Smoke Test"
        git config commit.gpgsign false
    ) >/dev/null 2>&1
    printf '%s' "$dir"
}

# commit_all <repo> <message>
commit_all() {
    local repo="$1" msg="$2"
    (
        cd "$repo" || exit 1
        git add -A
        git commit -qm "$msg"
    ) >/dev/null 2>&1
}

# copy_asset <asset-relative-path> <dest-dir>
copy_asset() {
    local rel="$1" dest="$2"
    cp "$SMOKE_DIR/assets/$rel" "$dest/"
}

# make_fake_bin <dir> - creates <dir>/opencode (the offline fake CLI)
make_fake_bin() {
    local dir="$1"
    mkdir -p "$dir"
    cp "$SMOKE_DIR/assets/fake-opencode.sh" "$dir/opencode"
    chmod +x "$dir/opencode"
    printf '%s' "$dir"
}

# run_worker_live <repo> [run-worker args...]
# Runs the real worker script and records its exit code in LAST_EXIT.
# Retries transient provider quota errors (HTTP 429) up to 3 times: a rate limit
# is an infrastructure failure, not a Task failure.
# Uses files instead of command substitution so a non-zero worker exit cannot
# trip `set -e` (bash 3.2 exempts command substitutions but not plain subshells).
# Always returns 0.
run_worker_live() {
    local repo="$1"; shift
    local log="$OUT_DIR/worker-${TEST_NAME}.log"
    local rc_out="$OUT_DIR/.rc-${TEST_NAME}-$$"
    local attempt=0 rc=0
    : >"$log"
    : >"$rc_out"
    while :; do
        attempt=$((attempt + 1))
        (
            cd "$repo" || exit 1
            local wrc=0
            "$WORKER" "$@" >"$log" 2>&1 || wrc=$?
            printf '%s' "$wrc" >"$rc_out"
            exit 0
        ) || true
        rc="$(cat "$rc_out" 2>/dev/null || printf '1')"
        [[ -n "$rc" ]] || rc=1
        if [[ "$rc" -eq 2 ]] && grep -q '"type":"provider.quota"' "$log" 2>/dev/null && [[ "$attempt" -lt 3 ]]; then
            info "provider rate limit (attempt $attempt); waiting 20s"
            sleep 20
            continue
        fi
        break
    done
    LAST_EXIT="$rc"
    rm -f "$rc_out"
    return 0
}

# run_phase_live <repo> [run-phase args...]
# Runs the real Phase loop in a throwaway repo, recording its exit code in
# LAST_EXIT and its output in $OUT_DIR/phase-${TEST_NAME}.log. Always returns 0.
run_phase_live() {
    local repo="$1"; shift
    local log="$OUT_DIR/phase-${TEST_NAME}.log"
    local rc_out="$OUT_DIR/.prc-${TEST_NAME}-$$"
    LAST_EXIT=0
    (
        cd "$repo" || exit 1
        local prc=0
        "$RUN_PHASE" "$@" >"$log" 2>&1 || prc=$?
        printf '%s' "$prc" >"$rc_out"
        exit 0
    ) || true
    LAST_EXIT="$(cat "$rc_out" 2>/dev/null || printf '1')"
    [[ -n "$LAST_EXIT" ]] || LAST_EXIT=1
    rm -f "$rc_out"
    return 0
}

# run_phase_fake <repo> <fake-bin-dir> [run-phase args...]
# Runs the Phase loop offline against the fake opencode CLI. Always returns 0.
run_phase_fake() {
    local repo="$1" bin="$2"; shift 2
    local log="$OUT_DIR/phase-${TEST_NAME}.log"
    local rc_out="$OUT_DIR/.frc-${TEST_NAME}-$$"
    LAST_EXIT=0
    (
        cd "$repo" || exit 1
        local prc=0
        PATH="$bin:$PATH" \
        FAKE_OPENCODE_MODE="script" \
        FAKE_OPENCODE_SCRIPT="$SMOKE_DIR/assets/fake-task.sh" \
        FAKE_TASK_DIR="${FAKE_TASK_DIR:-}" \
            "$RUN_PHASE" "$@" >"$log" 2>&1 || prc=$?
        printf '%s' "$prc" >"$rc_out"
        exit 0
    ) || true
    LAST_EXIT="$(cat "$rc_out" 2>/dev/null || printf '1')"
    [[ -n "$LAST_EXIT" ]] || LAST_EXIT=1
    rm -f "$rc_out"
    return 0
}

# write_task <repo> <task-id> <mode> <objective> <existing> <desired> <files> \
#           <allowed> <forbidden> <criteria> <verify> <escalation>
write_task() {
    local repo="$1" id="$2" mode="$3" objective="$4" existing="$5" desired="$6"
    local files="$7" allowed="$8" forbidden="$9" criteria="${10}" verify="${11}" escalation="${12}"
    mkdir -p "$repo/.agent/current"
    cat >"$repo/.agent/current/TASK.md" <<EOF
# Task

## Task ID
$id

## Mode
$mode

## Objective
$objective

## Context
Smoke test task.

## Existing Behavior
$existing

## Desired Behavior
$desired

## Relevant Files
$files

## Allowed Changes
$allowed

## Forbidden Changes
$forbidden

## Acceptance Criteria
$criteria

## Required Verification
$verify

## Escalation Conditions
$escalation
EOF
}

# queue_task_json <id> <title> <risk> <status> <verify-cmd> <allowed> \
#                 [<forbidden>] [<criteria>] [<mode>]
# Emits one TASK_QUEUE task object on stdout (JSONL for write_queue).
queue_task_json() {
    local id="$1" title="$2" risk="$3" status="$4" verify="$5" allowed="$6"
    local forbidden="${7:-}" criteria="${8:-$title}" mode="${9:-implement}"
    jq -n --arg id "$id" --arg t "$title" --arg r "$risk" --arg s "$status" \
          --arg v "$verify" --arg a "$allowed" --arg f "$forbidden" --arg c "$criteria" --arg m "$mode" '{
        id: $id, title: $t, mode: $m, risk: $r, status: $s,
        objective: $t, context: "smoke fixture",
        existing_behavior: "fixture", desired_behavior: $t,
        relevant_files: ["app.py - fixture"],
        allowed_changes: (if $a == "" then [] else ($a | split(",") | map(gsub("^ +| +$"; ""))) end),
        forbidden_changes: (if $f == "" then [] else ($f | split(",") | map(gsub("^ +| +$"; ""))) end),
        acceptance_criteria: [$c],
        verification: [{cmd: $v, expect: "exit 0"}],
        escalation_conditions: [], depends_on: [], history: []
    }'
}

# write_queue <repo> <phase> <tasks-jsonl-file> <phase-verify-cmd>
write_queue() {
    local repo="$1" phase="$2" tasks="$3" pv="$4"
    mkdir -p "$repo/.agent/phases/$phase/history"
    jq -n --arg p "$phase" --arg pv "$pv" --slurpfile t "$tasks" \
        '{phase: $p, status: "ready", human_checkpoint_after: true,
          created_at: "2026-09-20T00:00:00Z", updated_at: "2026-09-20T00:00:00Z",
          phase_verification: [{cmd: $pv, expect: "exit 0"}],
          tasks: $t, adjustments: []}' >"$repo/.agent/phases/$phase/TASK_QUEUE.json"
    rm -f "$tasks"
}

# write_run_state <repo> <phase> <status> - fresh RUN_STATE.json, prints the status
write_run_state() {
    local repo="$1" phase="$2" status="$3"
    mkdir -p "$repo/.agent"
    jq -n --arg p "$phase" --arg s "$status" \
        '{"target_phase": $p, "current_phase": $p, "current_task": "", "status": $s,
          "stop_reason": "", "human_checkpoint": ("after_phase_" + $p),
          "updated_at": "2026-09-20T00:00:00Z", "notes": ""}' >"$repo/.agent/RUN_STATE.json"
    printf '%s' "$status"
}

# write_phase_md <repo> <phase>
write_phase_md() {
    local repo="$1" phase="$2"
    mkdir -p "$repo/.agent/phases/$phase"
    printf '# Phase %s\n\n## Human QA Required\n- fixture manual check\n\n## Result\n<!-- template -->\n' \
        "$phase" >"$repo/.agent/phases/$phase/PHASE.md"
}

# cleanup_temp_repos - removes the throwaway repos unless SMOKE_KEEP_REPOS=1.
# On failure the key .agent state of each repo is copied to $OUT_DIR/failure-<test>/
# so the evidence survives the cleanup.
cleanup_temp_repos() {
    local d n=0
    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        for d in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do
            [[ -d "$d/.agent" ]] || continue
            n=$((n + 1))
            local dest="$OUT_DIR/failure-${TEST_NAME}-${n}"
            mkdir -p "$dest"
            cp -R "$d/.agent" "$dest/.agent" 2>/dev/null || true
            printf 'failure evidence: %s -> %s\n' "$d" "$dest"
        done
    fi
    if [[ "${SMOKE_KEEP_REPOS:-0}" -eq 1 ]]; then
        printf '(SMOKE_KEEP_REPOS=1: kept %d temp repo(s))\n' "${#CLEANUP_DIRS[@]}"
        for d in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do
            printf '  %s\n' "$d"
        done
    else
        for d in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do
            [[ -d "$d" ]] && rm -rf "$d"
        done
    fi
}

finish() {
    cleanup_temp_repos
    if [[ "$SKIP_COUNT" -gt 0 ]]; then
        printf '\n%s: %d passed, %d failed, %d skipped\n' "$TEST_NAME" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
    else
        printf '\n%s: %d passed, %d failed\n' "$TEST_NAME" "$PASS_COUNT" "$FAIL_COUNT"
    fi
    printf '(test output kept in %s)\n' "$OUT_DIR"
    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

require_live_env() {
    command -v opencode >/dev/null 2>&1 || { printf 'opencode not found\n' >&2; exit 1; }
    [[ -x "$WORKER" ]] || { printf 'worker script not found: %s\n' "$WORKER" >&2; exit 1; }
    [[ -x "$RUN_PHASE" ]] || { printf 'phase loop not found: %s\n' "$RUN_PHASE" >&2; exit 1; }
}

mkdir -p "$OUT_DIR"
