#!/usr/bin/env bash
# check-state.sh - read-only consistency check and resume verdict for a Phase.
#
# Cross-checks the files that must agree after an interruption:
#   .agent/current/.worker.lock   (a live worker wrapper / worker process?)
#   .agent/current/.phase.lock    (a live phase loop?)
#   .agent/RUN_STATE.json         (phase/task/status - required, structured)
#   .agent/phases/<phase>/TASK_QUEUE.json
#   .agent/current/TASK.md        (the Task in flight)
#   .agent/current/STATE.json     (run id / task / result of the last run)
#   .agent/current/{RESULT,ESCALATION,VERIFY}.md
#   .agent/history/*              (archives for done Tasks)
#
# It is fail-closed: an empty, unreadable, wrongly-structured or missing required
# file is an ISSUE, never a default value. It never changes anything.
#
# Verdicts (printed as "verdict: <V>"):
#   WORKER_RUNNING        a worker or phase loop process is alive - do not start
#   INCONSISTENT          files disagree, are missing, or are unreadable - fix first
#   ESCALATED             the loop stopped on a blocker (status or a Task) - Codex
#   CHECKPOINT            the loop stopped for a Codex decision (status=checkpoint)
#   AWAITING_PHASE_REVIEW Tasks are done, the Phase waits for the Codex review
#   AWAITING_HUMAN_QA     the review passed, the human decides the next Phase
#   RUNNING               the loop may continue (pending/in_progress Tasks)
#   QUEUE_COMPLETE        a queue with no runnable Task left (Phase review, or
#                         Codex adds a corrective Task)
#   EMPTY                 a fresh project (no .agent state at all)
#
# Exit codes: 0 = actionable (RUNNING / QUEUE_COMPLETE / EMPTY), 1 = stop (the rest).
#
# Usage:
#   check-state.sh [--root DIR]

set -euo pipefail

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; }

ISSUES=0
issue() { printf '  ISSUE   %s\n' "$*"; ISSUES=$((ISSUES + 1)); }
warn()  { printf '  warn    %s\n' "$*"; }
ok()    { printf '  ok      %s\n' "$*"; }

resolve_root() {
    local given="${1:-}"
    if [[ -n "$given" ]]; then cd "$given" && pwd -P; return 0; fi
    if git rev-parse --show-toplevel >/dev/null 2>&1; then git rev-parse --show-toplevel; return 0; fi
    pwd -P
}

jqv() {
    local file="$1" filter="$2" fallback="${3:-}"
    if [[ -f "$file" ]] && command -v jq >/dev/null 2>&1 && jq empty "$file" >/dev/null 2>&1; then
        local out
        out="$(jq -r "$filter" "$file" 2>/dev/null || true)"
        if [[ -n "$out" && "$out" != "null" ]]; then printf '%s' "$out"; return 0; fi
    fi
    printf '%s' "$fallback"
}

valid_object() {
    local file="$1"
    [[ -s "$file" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    jq -e 'type == "object"' "$file" >/dev/null 2>&1
}

task_id_of() {
    [[ -f "$1" ]] || { printf ''; return 0; }
    awk '/^## Task ID[[:space:]]*$/{getline; gsub(/[[:space:]]/,""); print; exit}' "$1"
}

report_status_of() {
    [[ -f "$1" ]] || { printf ''; return 0; }
    awk '/^## Status[[:space:]]*$/{getline; gsub(/^[[:space:]]+|[[:space:]]+$/,""); print; exit}' "$1"
}

report_class_of() {
    [[ -f "$1" ]] || { printf ''; return 0; }
    awk '/^## Class[[:space:]]*$/{getline; gsub(/^[[:space:]]+|[[:space:]]+$/,""); print; exit}' "$1"
}

section_nonempty() {
    awk -v h="$2" '
        $0 == "## " h || $0 ~ "^## " h "[[:space:]]*$" { f=1; next }
        /^## / { f=0 }
        f { print }
    ' "$1" | grep -v '^[[:space:]]*<!--' | grep -v '^[[:space:]]*$' | head -1 || true
}

live_pid_in() {  # live_pid_in <lock-dir> -> prints "wrapper:<pid>|worker:<pid>" when live
    local lock="$1" lpid="" wpid=""
    [[ -d "$lock" ]] || return 1
    [[ -f "$lock/info" ]] || return 1
    lpid="$(awk -F= '/^pid=/{print $2}' "$lock/info" | head -1)"
    wpid="$(awk -F= '/^worker_pid=/{print $2}' "$lock/info" | head -1)"
    if [[ -n "$lpid" ]] && kill -0 "$lpid" 2>/dev/null; then printf 'wrapper:%s' "$lpid"; return 0; fi
    if [[ -n "$wpid" ]] && kill -0 "$wpid" 2>/dev/null; then printf 'worker:%s' "$wpid"; return 0; fi
    return 1
}

VERDICT=""
STOP=1
set_verdict() { VERDICT="$1"; case "$1" in RUNNING|EMPTY|QUEUE_COMPLETE) STOP=0 ;; esac; }

KNOWN_STATES="idle running checkpoint escalated awaiting_phase_review awaiting_human_qa"

main() {
    local root_arg=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --root) root_arg="${2:-}"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) printf 'check-state: unknown argument %s\n' "$1" >&2; exit 1 ;;
        esac
    done

    local root agent current
    root="$(resolve_root "$root_arg")"
    agent="$root/.agent"
    current="$agent/current"
    printf 'check-state: %s\n\n' "$root"

    if [[ ! -d "$agent" ]]; then
        printf 'verdict: EMPTY - no .agent/ state at all (fresh project; plan the Phase first)\n'
        exit 0
    fi

    # --- live processes -----------------------------------------------------------------
    local worker_live="" phase_live=""
    worker_live="$(live_pid_in "$current/.worker.lock" || true)"
    phase_live="$(live_pid_in "$current/.phase.lock" || true)"
    if [[ -n "$worker_live" ]]; then
        ok "worker lock held by a LIVE process ($worker_live): $(tr '\n' ' ' <"$current/.worker.lock/info")"
    elif [[ -d "$current/.worker.lock" ]]; then
        warn "stale worker lock (no live pid); run-worker refuses until --break-lock is passed after verification"
    else
        ok "no worker lock"
    fi
    if [[ -n "$phase_live" ]]; then
        ok "phase lock held by a LIVE loop ($phase_live): $(tr '\n' ' ' <"$current/.phase.lock/info")"
    elif [[ -d "$current/.phase.lock" ]]; then
        warn "stale phase lock (no live pid); run-phase refuses until --break-lock is passed after verification"
    fi

    # --- RUN_STATE ------------------------------------------------------------------------
    local run_state="$agent/RUN_STATE.json"
    local phase="" rs_task="" rs_status="" rs_reason=""
    if [[ ! -e "$run_state" ]]; then
        if [[ -d "$current" || -d "$agent/phases" ]]; then
            issue "RUN_STATE.json is missing while other .agent state exists"
        else
            printf 'verdict: EMPTY - no RUN_STATE.json and no other state\n'
            exit 0
        fi
    elif ! valid_object "$run_state"; then
        issue "RUN_STATE.json is empty or not a JSON object"
    else
        phase="$(jqv "$run_state" '.current_phase')"
        rs_task="$(jqv "$run_state" '.current_task')"
        rs_status="$(jqv "$run_state" '.status')"
        rs_reason="$(jqv "$run_state" '.stop_reason')"
        if [[ -z "$rs_status" ]]; then
            issue "RUN_STATE.json has no status"
        elif [[ " $KNOWN_STATES " != *" $rs_status "* ]]; then
            issue "RUN_STATE.status '$rs_status' is not a known state (idle|running|checkpoint|escalated|awaiting_phase_review|awaiting_human_qa)"
        fi
        ok "RUN_STATE: phase=${phase:-?} task=${rs_task:-?} status=${rs_status:-?} stop_reason=${rs_reason:-none}"
        if [[ "$rs_status" == "checkpoint" && -z "$rs_reason" ]]; then
            warn "status=checkpoint but no stop_reason is recorded"
        fi
    fi

    # --- queue ---------------------------------------------------------------------------
    local pending="" in_progress="" done_list="" escalated="" queue=""
    local phase_required=0
    if [[ " running checkpoint escalated awaiting_phase_review awaiting_human_qa " == *" $rs_status "* ]]; then
        phase_required=1
    fi
    if [[ "$phase_required" -eq 1 && -z "$phase" ]]; then
        issue "RUN_STATE.status='$rs_status' requires a current_phase, but none is set"
    fi
    if [[ -n "$phase" ]]; then
        queue="$agent/phases/$phase/TASK_QUEUE.json"
        if [[ ! -e "$queue" ]]; then
            issue "RUN_STATE says current_phase=$phase but $queue is missing"
        elif ! valid_object "$queue"; then
            issue "$queue is empty or not a JSON object"
        elif ! jq -e '(.tasks | type) == "array"' "$queue" >/dev/null 2>&1; then
            issue "$queue has no tasks array"
        else
            local bad dup
            bad="$(jq -r '[
                .tasks[] | . as $t | select(
                  ($t | type != "object")
                  or ($t.id | (type != "string") or (length == 0))
                  or ($t.status | (type != "string") or (["pending","in_progress","done","escalated","dropped"] | index($t.status) | not))
                  or ((($t.verification // []) | length) == 0)
                )] | length' "$queue" 2>/dev/null || printf '1')"
            dup="0"
            if [[ "$bad" == "0" ]]; then
                dup="$(jq -r '[.tasks[].id] as $ids | (($ids | length) - ($ids | unique | length))' "$queue" 2>/dev/null || printf '1')"
            fi
            if [[ "$bad" != "0" ]]; then
                issue "$queue has Tasks that are not objects, or have a missing/invalid id or status, or no verification commands"
            elif [[ "$dup" != "0" ]]; then
                issue "$queue has duplicate Task ids"
            else
                pending="$(jqv "$queue" '[.tasks[] | select(.status=="pending") | .id] | join(",")')"
                in_progress="$(jqv "$queue" '[.tasks[] | select(.status=="in_progress") | .id] | join(",")')"
                done_list="$(jqv "$queue" '[.tasks[] | select(.status=="done") | .id] | join(",")')"
                escalated="$(jqv "$queue" '[.tasks[] | select(.status=="escalated") | .id] | join(",")')"
                ok "queue: done=[${done_list:-none}] in_progress=[${in_progress:-none}] pending=[${pending:-none}] escalated=[${escalated:-none}]"
            fi
        fi
    fi

    # --- current/STATE.json ----------------------------------------------------------------
    if [[ -e "$current/STATE.json" ]] && ! valid_object "$current/STATE.json"; then
        issue "current/STATE.json exists but is empty or not a JSON object"
    fi

    # --- current task / state / reports -----------------------------------------------------
    local cur_task state_task result="none" escalation="none" result_ok=0 escalation_ok=0
    cur_task="$(task_id_of "$current/TASK.md")"
    [[ -n "$cur_task" && "$cur_task" == *"<"* ]] && cur_task=""
    state_task="$(jqv "$current/STATE.json" '.task_id')"
    ok "current/TASK.md task id: ${cur_task:-<none/template>}"
    ok "current/STATE.json task id: ${state_task:-<none>} status=$(jqv "$current/STATE.json" '.status' '?') run=$(jqv "$current/STATE.json" '.run_id' '?')"

    local expect_task="${rs_task:-}"
    [[ -n "$in_progress" ]] && expect_task="${in_progress%%,*}"

    if [[ -s "$current/RESULT.md" ]]; then
        result="$(task_id_of "$current/RESULT.md")"
        local rstatus
        rstatus="$(report_status_of "$current/RESULT.md")"
        [[ "$rstatus" == "DONE" ]] && result_ok=1
        ok "RESULT.md: task='${result:-?}' status='${rstatus:-<none>}'"
        if [[ "$result_ok" -ne 1 ]]; then
            issue "RESULT.md is present but not acceptable (Status must be DONE)"
        fi
        if [[ -n "$expect_task" && "$result" != "$expect_task" ]]; then
            issue "RESULT.md belongs to task '$result' but the current Task is '$expect_task'"
        fi
    fi
    if [[ -s "$current/ESCALATION.md" ]]; then
        escalation="$(task_id_of "$current/ESCALATION.md")"
        local esc_class
        esc_class="$(report_class_of "$current/ESCALATION.md")"
        [[ -n "$(section_nonempty "$current/ESCALATION.md" "Current Blocker")" ]] && escalation_ok=1 || escalation_ok=0
        ok "ESCALATION.md: task='${escalation:-?}' class='${esc_class:-<missing>}' blocker=$([[ "$escalation_ok" -eq 1 ]] && echo yes || echo missing)"
        if [[ "$escalation_ok" -ne 1 ]]; then
            issue "ESCALATION.md is present but has no Current Blocker"
        fi
        case "$esc_class" in
            CHECKPOINT|ESCALATE) : ;;
            "") warn "ESCALATION.md has no Class (CHECKPOINT|ESCALATE); a missing class is treated as ESCALATE" ;;
            *) warn "ESCALATION.md Class '$esc_class' is not recognised; it is treated as ESCALATE" ;;
        esac
    fi
    if [[ -s "$current/VERIFY.md" ]]; then
        ok "VERIFY.md (evidence gate) present: $(grep -m1 -E '^- result: ' "$current/VERIFY.md" || printf 'result: <none>')"
    fi

    # --- consistency --------------------------------------------------------------------------
    if [[ -n "$in_progress" ]]; then
        local ip_first="${in_progress%%,*}"
        [[ "$cur_task" == "$ip_first" ]] || issue "queue says in_progress=$ip_first but current/TASK.md is '${cur_task:-<none>}' (rewrite TASK.md from the saved definition before resuming)"
        [[ -z "$state_task" || "$state_task" == "$ip_first" ]] || issue "current/STATE.json belongs to task '$state_task' but the queue is on '$ip_first'"
        [[ -n "$rs_task" && "$rs_task" != "$ip_first" ]] && issue "RUN_STATE.current_task='$rs_task' does not match the queue in_progress='$ip_first'"
        [[ "$in_progress" == *","* ]] && issue "more than one Task is in_progress in the queue: $in_progress (only one may be)"
        if [[ "$escalation" != "none" && "$escalation" != "$ip_first" ]]; then
            issue "ESCALATION.md belongs to task '$escalation' but the queue is on '$ip_first'"
        fi
        if ls -d "$agent/history"/*"-${ip_first}" >/dev/null 2>&1; then
            issue "Task '$ip_first' already has an archive but is still in_progress (verify the archived RESULT, then mark it done instead of re-running)"
        fi
    fi
    if [[ "$result" != "none" && "$escalation" != "none" ]]; then
        issue "both RESULT.md and ESCALATION.md exist; resolve before resuming"
    fi
    if [[ "$rs_status" == "awaiting_phase_review" || "$rs_status" == "awaiting_human_qa" ]]; then
        if [[ -n "$pending" || -n "$in_progress" ]]; then
            issue "RUN_STATE is $rs_status but the queue still has pending/in_progress Tasks"
        fi
    fi
    if [[ "$rs_status" == "escalated" && -z "$escalated" ]]; then
        warn "status=escalated but no Task is marked escalated"
    fi

    # --- archives for done tasks --------------------------------------------------------------
    local t
    if [[ -n "$done_list" ]]; then
        for t in ${done_list//,/ }; do
            if ! ls -d "$agent/history"/*"-${t}" >/dev/null 2>&1; then
                warn "done Task '$t' has no archive (verify its evidence in the queue history if it matters)"
            fi
        done
    fi

    # --- verdict -------------------------------------------------------------------------------
    if [[ -n "$worker_live" || -n "$phase_live" ]]; then
        set_verdict "WORKER_RUNNING"
    elif [[ "$ISSUES" -gt 0 ]]; then
        set_verdict "INCONSISTENT"
    elif [[ -n "$escalated" || "$rs_status" == "escalated" ]]; then
        set_verdict "ESCALATED"
    elif [[ "$rs_status" == "checkpoint" ]]; then
        set_verdict "CHECKPOINT"
    elif [[ "$rs_status" == "awaiting_phase_review" ]]; then
        set_verdict "AWAITING_PHASE_REVIEW"
    elif [[ "$rs_status" == "awaiting_human_qa" ]]; then
        set_verdict "AWAITING_HUMAN_QA"
    elif [[ -n "$pending" || -n "$in_progress" ]]; then
        set_verdict "RUNNING"
    elif [[ -n "$queue" && -f "$queue" ]]; then
        set_verdict "QUEUE_COMPLETE"
    else
        set_verdict "EMPTY"
    fi

    printf '\nverdict: %s' "$VERDICT"
    case "$VERDICT" in
        WORKER_RUNNING)
            printf ' - a worker or phase loop is alive; do not start another\n' ;;
        INCONSISTENT)
            printf ' (%d issue(s)) - fix the issues above before resuming\n' "$ISSUES" ;;
        ESCALATED)
            printf ' task=%s - Codex must resolve the blocker (queue history / ESCALATION.md)\n' "${escalated:-${rs_task:-?}}" ;;
        CHECKPOINT)
            printf ' task=%s - Codex decision needed (%s); read .agent/current/ then run run-phase.sh again\n' "${rs_task:-?}" "${rs_reason:-no stop_reason}" ;;
        AWAITING_PHASE_REVIEW)
            printf ' - all Tasks done; Codex phase review required (phase-gate.sh review-pass|review-fail)\n' ;;
        AWAITING_HUMAN_QA)
            printf ' - stop here; the human decides (phase-gate.sh qa-pass|qa-fail after the verdict)\n' ;;
        RUNNING)
            printf ' - next=%s in_progress=%s; continue with run-phase.sh\n' "${pending:-none}" "${in_progress:-none}" ;;
        QUEUE_COMPLETE)
            printf ' - no runnable Task left in phase %s; run run-phase.sh for the Phase verification, or add a Task (Codex)\n' "${phase:-?}" ;;
        EMPTY)
            printf ' - no queue state found (fresh project)\n' ;;
    esac

    [[ "$STOP" -eq 0 ]]
}

main "$@"
