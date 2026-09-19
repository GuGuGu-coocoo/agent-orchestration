#!/usr/bin/env bash
# helpers.sh - shared test scaffolding. Not executed directly; sourced by test scripts.
#
# Design notes:
#   - No EXIT trap (bash 3.2 fires inherited traps in command-substitution
#     subshells). Each test calls `finish`, which performs cleanup explicitly.
#   - Every test creates throwaway git repos under the system temp directory.
#     No test ever touches a real user project.
#   - `run_worker_live` always returns 0 and records the worker exit code in
#     LAST_EXIT, so `set -e` cannot abort the test before its assertions run.
#   - Set SMOKE_KEEP_REPOS=1 to keep the temp repos for inspection.

set -euo pipefail

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SMOKE_DIR/../.." && pwd)"
WORKER="$HOME/.agents/skills/cheap-worker/scripts/run-worker.sh"
OUT_DIR="$SMOKE_DIR/.out"
TMP_BASE="${TMPDIR:-/tmp}"

# Model: live tests use OpenCode's configured default model, exactly like the
# worker does in production. There is no model override here on purpose; to test
# against a specific model, change OpenCode's own configuration first.

TEST_NAME="test"
PASS_COUNT=0
FAIL_COUNT=0
LAST_EXIT=0
CLEANUP_DIRS=()

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '  PASS  %s\n' "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '  FAIL  %s\n' "$*"; }
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

# cleanup_temp_repos - removes the throwaway repos unless SMOKE_KEEP_REPOS=1
cleanup_temp_repos() {
    local d
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
    printf '\n%s: %d passed, %d failed\n' "$TEST_NAME" "$PASS_COUNT" "$FAIL_COUNT"
    printf '(test output kept in %s)\n' "$OUT_DIR"
    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

require_live_env() {
    command -v opencode >/dev/null 2>&1 || { printf 'opencode not found\n' >&2; exit 1; }
    [[ -x "$WORKER" ]] || { printf 'worker not installed: %s\n' "$WORKER" >&2; exit 1; }
}

mkdir -p "$OUT_DIR"
