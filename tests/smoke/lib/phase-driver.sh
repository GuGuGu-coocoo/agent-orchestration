#!/usr/bin/env bash
# phase-driver.sh - a minimal stand-in for the Codex Supervisor loop, used only by
# the smoke tests. It implements the phase-runner workflow without an LLM:
#
#   for each pending Task: render TASK.md -> run-worker.sh -> inspect exit code
#     -> ACCEPT (archive, next) or stop on escalation
#
# In --rework mode it issues one deliberate REWORK after A02 (writing REVIEW.md
# with concrete corrections) and then accepts the corrected result, proving the
# rework loop works and the task id is not re-run from scratch.
#
# Inputs (environment):
#   SMOKE_DIR, REPO, REWORK_MODE

set -euo pipefail

SMOKE_DIR="${SMOKE_DIR:?}"
REPO="${REPO:?}"
REWORK_MODE="${REWORK_MODE:-0}"

WORKER="$HOME/.agents/skills/cheap-worker/scripts/run-worker.sh"
ARCHIVER="$HOME/.agents/skills/cheap-worker/scripts/archive-task.sh"
QUEUE="$REPO/.agent/phases/A/TASK_QUEUE.json"
CURRENT="$REPO/.agent/current"

log() { printf '[phase-driver] %s\n' "$*"; }

# archive_current <task-id> <decision> - always passes the Task ID explicitly so
# archiving never depends on parsing the (possibly template) TASK.md.
archive_current() {
    local id="$1" decision="$2"
    (cd "$REPO" && "$ARCHIVER" --yes --task-id "$id" --decision "$decision") >/dev/null
}

jq_update_task() {
    # jq_update_task <task-id> <jq-expression-applied-to-the-task>
    local id="$1" expr="$2"
    local tmp
    tmp="$(mktemp)"
    jq --arg id "$id" "(.tasks[] | select(.id == \$id)) |= ($expr)" "$QUEUE" >"$tmp"
    mv "$tmp" "$QUEUE"
}

write_task_md() {
    local id="$1" title="$2" objective="$3" existing="$4" desired="$5" verify="$6"
    local allowed="${7:-- app.py only}" forbidden="${8:-- test_app.py (frozen: do not edit, delete, skip or weaken it)
- any other file}"
    mkdir -p "$CURRENT"
    cat >"$CURRENT/TASK.md" <<EOF
# Task

## Task ID
$id

## Mode
implement

## Objective
$objective

## Context
Smoke-test phase A. This Task was produced by the phase-driver from the queue.

## Existing Behavior
$existing

## Desired Behavior
$desired

## Relevant Files
- app.py - the application module
- test_app.py - the acceptance test suite

## Allowed Changes
$allowed

## Forbidden Changes
$forbidden

## Acceptance Criteria
- [ ] $desired
- [ ] every Required Verification command passes

## Required Verification
- $verify

## Escalation Conditions
- none expected; adding a new function and its test is ordinary work
EOF
    cp "$CURRENT/TASK.md" "$REPO/.agent/phases/A/history/TASK-$id.md"
}

update_queue_status() {
    local status="$1" tmp
    tmp="$(mktemp)"
    jq --arg s "$status" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        '.status = $s | .updated_at = $now' "$QUEUE" >"$tmp"
    mv "$tmp" "$QUEUE"
}

update_run_state() {
    local status="$1" task="$2" tmp
    tmp="$(mktemp)"
    jq --arg s "$status" --arg t "$task" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        '.status = $s | .current_phase = "A" | .current_task = $t | .target_phase = "A" | .human_checkpoint = "after_phase_A" | .updated_at = $now' \
        "$REPO/.agent/RUN_STATE.json" >"$tmp"
    mv "$tmp" "$REPO/.agent/RUN_STATE.json"
}

run_one_task() {
    local id="$1" mode="$2" use_review="$3" extra="${4:-}" title="${5:-}"
    log "running $id (mode=$mode${use_review:+, with REVIEW.md})"
    local title_args=()
    [[ -n "$title" ]] && title_args=(--title "$title")
    local rc=0 attempt=0
    while :; do
        attempt=$((attempt + 1))
        set +e
        # shellcheck disable=SC2086
        (cd "$REPO" && "$WORKER" \
            --mode "$mode" --task-id "$id" ${title_args[@]+"${title_args[@]}"} \
            --allow-dirty $extra) >>"$SMOKE_DIR/.out/phase-driver-${id}.log" 2>&1
        rc=$?
        set -e
        log "$id attempt=$attempt exit=$rc"

        # A 429/quota error is a transient infrastructure failure, not a task
        # failure; retry it like a real Supervisor would.
        if [[ "$rc" -eq 2 ]] && grep -q '"type":"provider.quota"' "$SMOKE_DIR/.out/phase-driver-${id}.log" 2>/dev/null && [[ "$attempt" -lt 3 ]]; then
            log "$id: provider rate limit; waiting 20s before retry"
            sleep 20
            continue
        fi
        break
    done
    return $rc
}

# A01 is already done in the queue (resume scenario). Start from pending Tasks.
while :; do
    next_id="$(jq -r '[.tasks[] | select(.status == "pending")][0].id // empty' "$QUEUE")"
    if [[ -z "$next_id" ]]; then
        log "no pending tasks left"
        break
    fi

    case "$next_id" in
        A02)
            write_task_md "A02" "add shutdown(seconds)" \
                "Add shutdown(seconds) to app.py: it must return exactly 'shutting down in <N>s' for integer N. Also add a test function test_shutdown() to test_app.py asserting shutdown(5) == 'shutting down in 5s'." \
                "app.py defines uppercase() only. test_app.py has test_uppercase()." \
                "python3 -m pytest -q test_app.py passes, including the new test_shutdown()" \
                "python3 -m pytest -q test_app.py" \
                "- app.py (append shutdown) and test_app.py (append test_shutdown)" \
                "- deleting or weakening test_uppercase; any other file"
            ;;
        A03)
            write_task_md "A03" "add farewell(name)" \
                "Add farewell(name) to app.py: it must return exactly 'bye, <name>'. Also add a test function test_farewell() to test_app.py asserting farewell('Ada') == 'bye, Ada'." \
                "app.py defines uppercase() and shutdown(). test_app.py has test_uppercase() and test_shutdown()." \
                "python3 -m pytest -q test_app.py passes, including the new test_farewell()" \
                "python3 -m pytest -q test_app.py" \
                "- app.py (append farewell) and test_app.py (append test_farewell)" \
                "- deleting or weakening test_uppercase/test_shutdown; any other file"
            ;;
        *)
            log "unexpected task id $next_id"
            exit 1
            ;;
    esac

    jq_update_task "$next_id" ".status = \"in_progress\""
    update_queue_status "running"
    update_run_state "running" "$next_id"

    rc=0
    run_one_task "$next_id" "implement" "" " " "$(jq -r --arg id "$next_id" '.tasks[] | select(.id==$id) | .title' "$QUEUE")" || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        log "$next_id did not produce a RESULT (exit $rc); stopping like a real Supervisor would"
        jq_update_task "$next_id" ".status = \"escalated\""
        update_run_state "blocked" "$next_id"
        exit 2
    fi

    # Review step: verify the acceptance condition from the queue itself.
    case "$next_id" in
        A02)
            if ! (cd "$REPO" && python3 -c "from app import shutdown; assert shutdown(5) == 'shutting down in 5s'") >/dev/null 2>&1; then
                log "REVIEW A02: behavior wrong; issuing REWORK"
                cat >"$CURRENT/REVIEW.md" <<'EOF'
# Review

## Task ID
A02

## Decision
REWORK

## Findings
- app.py's shutdown(seconds) does not return exactly "shutting down in <N>s".

## Required Corrections
- Implement shutdown(seconds) to return f"shutting down in {seconds}s".
- Do not modify test_app.py.

## Keep
- uppercase() must keep working.
EOF
                jq_update_task "A02" ".status = \"pending\""
                jq --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
                    '(.tasks[] | select(.id=="A02")) |= (.history += [{at: $now, decision: "REWORK", note: "behavior did not match acceptance_summary"}])' \
                    "$QUEUE" >"$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"

                rc2=0
                run_one_task "A02" "implement" "yes" "" "add shutdown(seconds)" || rc2=$?
                if [[ "$rc2" -ne 0 ]]; then
                    log "reworked A02 still failed (exit $rc2); stopping"
                    jq_update_task "A02" ".status = \"escalated\""
                    update_run_state "blocked" "A02"
                    exit 2
                fi
                rm -f "$CURRENT/REVIEW.md"

                if ! (cd "$REPO" && python3 -c "from app import shutdown; assert shutdown(5) == 'shutting down in 5s'") >/dev/null 2>&1; then
                    log "REVIEW A02: still wrong after rework; stopping"
                    jq_update_task "A02" ".status = \"escalated\""
                    update_run_state "blocked" "A02"
                    exit 2
                fi
            fi
            ;;
        A03)
            if ! (cd "$REPO" && python3 -c "from app import farewell; assert farewell('Ada') == 'bye, Ada'") >/dev/null 2>&1; then
                log "REVIEW A03: behavior wrong; stopping"
                jq_update_task "A03" ".status = \"escalated\""
                update_run_state "blocked" "A03"
                exit 2
            fi
            ;;
    esac

    log "ACCEPT $next_id"
    jq_update_task "$next_id" \
        ".status = \"done\" | .history += [{at: \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\", decision: \"ACCEPT\", note: \"phase-driver review passed\"}]"
    archive_current "$next_id" "ACCEPT"

    if [[ "$REWORK_MODE" -eq 1 && "$next_id" == "A02" ]]; then
        # Demonstrate the REWORK path once, realistically: a new edge-case test is
        # appended to test_app.py, the review requires making it pass, and the Task
        # is only accepted after the corrected run.
        log "REWORK_MODE: forcing one corrective round trip on A02 (edge case shutdown(0))"
        cat >>"$REPO/test_app.py" <<'EOF'


def test_shutdown_zero():
    from app import shutdown
    assert shutdown(0) == "shutting down in 0s"
EOF
        jq_update_task "A02" ".status = \"in_progress\""
        cat >"$CURRENT/REVIEW.md" <<'EOF'
# Review

## Task ID
A02

## Decision
REWORK

## Findings
- test_app.py now contains test_shutdown_zero, which fails: shutdown(0) must return "shutting down in 0s".

## Required Corrections
- Make shutdown(0) return exactly "shutting down in 0s".
- Keep test_uppercase and test_shutdown passing.

## Keep
- uppercase() and shutdown(5) behavior must stay correct.
EOF
        rc3=0
        run_one_task "A02" "fix" "yes" "" "add shutdown(seconds)" || rc3=$?
        if [[ "$rc3" -ne 0 ]]; then
            log "REWORK_MODE corrective round failed (exit $rc3)"
            jq_update_task "A02" ".status = \"escalated\""
            update_run_state "blocked" "A02"
            exit 2
        fi
        if ! (cd "$REPO" && python3 -m pytest -q test_app.py) >/dev/null 2>&1; then
            log "REWORK_MODE: corrections did not make the suite pass"
            jq_update_task "A02" ".status = \"escalated\""
            update_run_state "blocked" "A02"
            exit 2
        fi
        jq --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
            '(.tasks[] | select(.id=="A02")) |= (.history += [{at: $now, decision: "REWORK", note: "edge case shutdown(0) required"}])' \
            "$QUEUE" >"$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
        archive_current "A02" "REWORK"
        rm -f "$CURRENT/REVIEW.md"
        jq_update_task "A02" \
            ".status = \"done\" | .history += [{at: \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\", decision: \"ACCEPT\", note: \"accepted after corrective round\"}]"
    fi
done

update_queue_status "done"
update_run_state "awaiting_human_qa" ""
log "phase A complete; RUN_STATE=awaiting_human_qa"
exit 0
