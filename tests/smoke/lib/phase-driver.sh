#!/usr/bin/env bash
# phase-driver.sh - a minimal deterministic stand-in for the Codex Supervisor loop,
# used only by the smoke tests. It implements the phase-runner workflow without an
# LLM:
#
#   resume-aware: an in_progress Task is resumed (not skipped, not re-planned)
#   for each Task: render TASK.md -> mark in_progress (temp+rename) -> run-worker
#     -> deterministic acceptance check -> (REWORK before ACCEPT when forced)
#     -> archive -> mark done
#   phase review: run the phase verification for real, write PHASE.md ## Result,
#     mark the queue done and RUN_STATE awaiting_human_qa
#
# It is a test double, not the Codex Supervisor. Passing it does not prove that
# Codex follows the skill; the live tests in run-d/run-e exercise the scripts it
# drives, and the skill text is reviewed separately.
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
PHASE_DIR="$REPO/.agent/phases/A"
CURRENT="$REPO/.agent/current"

log() { printf '[phase-driver] %s\n' "$*"; }

# The skill says to consult check-state before resuming; the double logs it too.
if [[ -x "$HOME/.agents/skills/cheap-worker/scripts/check-state.sh" ]]; then
    log "check-state verdict:"
    (cd "$REPO" && "$HOME/.agents/skills/cheap-worker/scripts/check-state.sh" 2>&1 | grep -E 'verdict:|ISSUE' | sed 's/^/  /') || true
fi

archive_current() {
    local id="$1" decision="$2"
    (cd "$REPO" && "$ARCHIVER" --yes --task-id "$id" --decision "$decision") >/dev/null
}

jq_update_task() {
    local id="$1" expr="$2" tmp
    tmp="$(mktemp)"
    jq --arg id "$id" "(.tasks[] | select(.id == \$id)) |= ($expr)" "$QUEUE" >"$tmp"
    mv "$tmp" "$QUEUE"
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

next_task_id() {
    local id
    id="$(jq -r '[.tasks[] | select(.status == "in_progress")][0].id // empty' "$QUEUE")"
    if [[ -z "$id" ]]; then
        id="$(jq -r '[.tasks[] | select(.status == "pending")][0].id // empty' "$QUEUE")"
    fi
    printf '%s' "$id"
}

task_title() {
    jq -r --arg id "$1" '.tasks[] | select(.id==$id) | .title' "$QUEUE"
}

task_mode() {
    jq -r --arg id "$1" '.tasks[] | select(.id==$id) | .mode' "$QUEUE"
}

escalated_task() {
    jq -r '[.tasks[] | select(.status == "escalated") | .id] | join(",")' "$QUEUE"
}

write_task_md() {
    local id="$1" objective="$2" existing="$3" desired="$4" verify="$5"
    local allowed="${6:-- app.py only}" forbidden="${7:-- test_app.py (frozen: do not edit, delete, skip or weaken it)
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
- none expected
EOF
    cp "$CURRENT/TASK.md" "$PHASE_DIR/history/TASK-$id.md"
}

# render_task <id> - rebuild .agent/current/TASK.md from the saved definition when
# resuming (M03), otherwise write it fresh from the queue definition.
render_task() {
    local id="$1"
    case "$id" in
        A02)
            write_task_md "A02" \
                "Add shutdown(seconds) to app.py: it must return exactly 'shutting down in <N>s' for integer N. Also add a test function test_shutdown() to test_app.py asserting shutdown(5) == 'shutting down in 5s'." \
                "app.py defines uppercase() only. test_app.py has test_uppercase()." \
                "python3 -m pytest -q test_app.py passes, including the new test_shutdown()" \
                "python3 -m pytest -q test_app.py" \
                "- app.py (append shutdown) and test_app.py (append test_shutdown)" \
                "- deleting or weakening test_uppercase; any other file"
            ;;
        A03)
            write_task_md "A03" \
                "Add farewell(name) to app.py: it must return exactly 'bye, <name>'. Also add a test function test_farewell() to test_app.py asserting farewell('Ada') == 'bye, Ada'." \
                "app.py defines uppercase() and shutdown(). test_app.py has test_uppercase() and test_shutdown()." \
                "python3 -m pytest -q test_app.py passes, including the new test_farewell()" \
                "python3 -m pytest -q test_app.py" \
                "- app.py (append farewell) and test_app.py (append test_farewell)" \
                "- deleting or weakening test_uppercase/test_shutdown; any other file"
            ;;
        *)
            log "unexpected task id $id"
            return 1
            ;;
    esac
}

run_one_task() {
    local id="$1" mode="$2" extra="${3:-}" title="${4:-}"
    log "running $id (mode=$mode)"
    local title_args=()
    [[ -n "$title" ]] && title_args=(--title "$title")
    local rc=0
    # shellcheck disable=SC2086
    (cd "$REPO" && "$WORKER" \
        --mode "$mode" --task-id "$id" ${title_args[@]+"${title_args[@]}"} \
        --allow-dirty $extra) >>"$SMOKE_DIR/.out/phase-driver-${id}.log" 2>&1 || rc=$?
    log "$id exit=$rc"
    return $rc
}

review_task() {
    local id="$1"
    case "$id" in
        A02)
            (cd "$REPO" && python3 -c "from app import shutdown; assert shutdown(5) == 'shutting down in 5s'") >/dev/null 2>&1
            ;;
        A03)
            (cd "$REPO" && python3 -c "from app import farewell; assert farewell('Ada') == 'bye, Ada'") >/dev/null 2>&1
            ;;
        *) return 1 ;;
    esac
}

while :; do
    esc="$(escalated_task)"
    if [[ -n "$esc" ]]; then
        log "task(s) escalated: $esc - stopping (not a completed phase)"
        update_queue_status "blocked"
        update_run_state "blocked" "${esc%%,*}"
        exit 2
    fi

    next_id="$(next_task_id)"
    if [[ -z "$next_id" ]]; then
        log "no pending or in_progress tasks left"
        break
    fi

    was_in_progress="$(jq -r --arg id "$next_id" '.tasks[] | select(.id==$id) | .status' "$QUEUE")"
    if [[ "$was_in_progress" == "in_progress" ]]; then
        log "resuming in_progress task $next_id"
    fi

    # Render first, mark in_progress second (M03 ordering).
    render_task "$next_id" || exit 1
    jq_update_task "$next_id" ".status = \"in_progress\""
    update_queue_status "running"
    update_run_state "running" "$next_id"

    if ! run_one_task "$next_id" "implement" "" "$(task_title "$next_id")"; then
        log "$next_id did not produce a valid RESULT; stopping like a real Supervisor would"
        jq_update_task "$next_id" ".status = \"escalated\""
        update_run_state "blocked" "$next_id"
        exit 2
    fi

    # Deterministic review; one forced REWORK round before ACCEPT when requested.
    if ! review_task "$next_id"; then
        log "REVIEW $next_id: acceptance check failed; issuing REWORK"
        cat >"$CURRENT/REVIEW.md" <<EOF
# Review

## Task ID
$next_id

## Decision
REWORK

## Findings
- the acceptance check for $next_id did not pass.

## Required Corrections
- fix the behavior named in the queue acceptance_summary.
- do not modify test_app.py beyond appending the required test functions.

## Keep
- previously passing tests must keep passing.
EOF
        jq --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
            '(.tasks[] | select(.id=="'"$next_id"'")) |= (.history += [{at: $now, decision: "REWORK", note: "acceptance check failed"}])' \
            "$QUEUE" >"$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
        if ! run_one_task "$next_id" "$(task_mode "$next_id")" "" "$(task_title "$next_id")"; then
            log "reworked $next_id still failed; stopping"
            jq_update_task "$next_id" ".status = \"escalated\""
            update_run_state "blocked" "$next_id"
            exit 2
        fi
        rm -f "$CURRENT/REVIEW.md"
        if ! review_task "$next_id"; then
            log "$next_id still wrong after rework; stopping"
            jq_update_task "$next_id" ".status = \"escalated\""
            update_run_state "blocked" "$next_id"
            exit 2
        fi
    fi

    if [[ "$REWORK_MODE" -eq 1 && "$next_id" == "A02" ]]; then
        # Forced corrective round BEFORE acceptance: a stricter requirement is
        # appended to the test suite and the same Task must satisfy it.
        log "REWORK_MODE: forcing a corrective round on A02 (negative seconds must raise)"
        cat >>"$REPO/test_app.py" <<'EOF'


def test_shutdown_negative():
    import pytest
    from app import shutdown
    with pytest.raises(ValueError):
        shutdown(-1)
EOF
        # Prove the new requirement actually fails before calling it a rework.
        if (cd "$REPO" && python3 -m pytest -q test_app.py) >/dev/null 2>&1; then
            log "REWORK_MODE: appended requirement did not fail; refusing to fake a rework"
            jq_update_task "A02" ".status = \"escalated\""
            update_run_state "blocked" "A02"
            exit 2
        fi
        cat >"$CURRENT/REVIEW.md" <<'EOF'
# Review

## Task ID
A02

## Decision
REWORK

## Findings
- test_app.py now contains test_shutdown_negative, which fails: shutdown(-1) must raise ValueError.

## Required Corrections
- Make shutdown(seconds) raise ValueError for negative seconds.
- Keep test_uppercase and test_shutdown passing.

## Keep
- uppercase() and shutdown(5) behavior must stay correct.
EOF
        if ! run_one_task "A02" "$(task_mode "A02")" "" "add shutdown(seconds)"; then
            log "REWORK_MODE corrective round failed"
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
        rm -f "$CURRENT/REVIEW.md"
    fi

    log "ACCEPT $next_id (archive first, then mark done)"
    archive_current "$next_id" "ACCEPT"
    jq_update_task "$next_id" \
        ".status = \"done\" | .history += [{at: \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\", decision: \"ACCEPT\", note: \"phase-driver review passed\"}]"
done

# --- phase final review (real execution, not a status flip) --------------------
log "phase final review: running the phase verification"
PHASE_REVIEW="$PHASE_DIR/PHASE_REVIEW.md"
{
    printf '# Phase verification run\n\n'
    printf -- '- at: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf -- '- command: python3 -m pytest -q test_app.py\n\n'
    printf '## Output\n\n```\n'
} >"$PHASE_REVIEW"
phase_rc=0
(cd "$REPO" && python3 -m pytest -q test_app.py) >>"$PHASE_REVIEW" 2>&1 || phase_rc=$?
{
    printf '```\n\n## Result\n\n'
    if [[ "$phase_rc" -eq 0 ]]; then
        printf 'PASS (exit 0). Phase accepted by the driver review.\n'
    else
        printf 'FAIL (exit %s).\n' "$phase_rc"
    fi
} >>"$PHASE_REVIEW"

if [[ "$phase_rc" -ne 0 ]]; then
    log "phase verification failed (exit $phase_rc)"
    update_queue_status "blocked"
    update_run_state "blocked" ""
    exit 2
fi

{
    printf '\n## Result\n\n'
    printf -- '- Tasks completed: %s\n' "$(jq -r '[.tasks[].id] | join(", ")' "$QUEUE")"
    printf -- '- Verification: `python3 -m pytest -q test_app.py` passed (see history/PHASE_REVIEW.md)\n'
    printf -- '- Deviations from plan: none\n'
    printf -- '- Risks / follow-ups: none\n'
} >>"$PHASE_DIR/PHASE.md"

update_queue_status "done"
update_run_state "awaiting_human_qa" ""
log "phase A complete; RUN_STATE=awaiting_human_qa"
exit 0
