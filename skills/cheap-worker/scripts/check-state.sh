#!/usr/bin/env bash
# check-state.sh - read-only consistency check before resuming a Phase.
#
# Cross-checks the files that must agree after an interruption:
#   .agent/current/.worker.lock   (a live wrapper or worker process?)
#   .agent/RUN_STATE.json         (phase/task/status - required, structured)
#   .agent/phases/<phase>/TASK_QUEUE.json
#   .agent/current/TASK.md        (the Task in flight)
#   .agent/current/STATE.json     (run id / task / result of the last run)
#   .agent/current/{RESULT,ESCALATION}.md
#   .agent/history/*              (archives for done tasks)
#
# It is fail-closed: an empty, unreadable, wrongly-structured or missing required
# file is an ISSUE, never a default value. It never changes anything.
#
# Verdicts (printed as "verdict: <V>"):
#   WORKER_RUNNING    a wrapper or worker process is alive - wait, do not start
#   ESCALATED         the queue holds an escalated Task - Supervisor decision
#   BLOCKED           RUN_STATE says blocked - resolve before resuming
#   CHECKPOINT        awaiting_human_qa - stop and hand over to the human
#   INCONSISTENT      files disagree, are missing, or are unreadable - fix first
#   REVIEW_OR_RESUME  an in_progress Task: report ready -> review, else re-run it
#   NEXT              a pending Task is ready to hand off
#   PHASE_COMPLETE    every Task is done - run the phase final review
#   EMPTY             a fresh project (no .agent state at all)
#
# Exit codes: 0 = actionable (REVIEW_OR_RESUME / NEXT / PHASE_COMPLETE / EMPTY),
#             1 = stop (WORKER_RUNNING / ESCALATED / BLOCKED / CHECKPOINT / INCONSISTENT).
#
# Usage:
#   check-state.sh [--root DIR]

set -euo pipefail

usage() { sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

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

# valid_object <file> -> 0 when the file is a non-empty JSON object
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

section_nonempty() {
    awk -v h="$2" '
        $0 == "## " h || $0 ~ "^## " h "[[:space:]]*$" { f=1; next }
        /^## / { f=0 }
        f { print }
    ' "$1" | grep -v '^[[:space:]]*<!--' | grep -v '^[[:space:]]*$' | head -1 || true
}

VERDICT=""
STOP=1
set_verdict() { VERDICT="$1"; case "$1" in REVIEW_OR_RESUME|NEXT|PHASE_COMPLETE|EMPTY) STOP=0 ;; esac; }

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

    # --- a fresh project has no .agent state ------------------------------------
    if [[ ! -d "$agent" ]]; then
        printf 'verdict: EMPTY - no .agent/ state at all (fresh project; start from phase intake)\n'
        exit 0
    fi

    # --- lock: both the wrapper pid and the worker pid matter -------------------
    local lock="$current/.worker.lock" lock_live=0
    if [[ -d "$lock" ]]; then
        local lpid="" wpid=""
        [[ -f "$lock/info" ]] && {
            lpid="$(awk -F= '/^pid=/{print $2}' "$lock/info" | head -1)"
            wpid="$(awk -F= '/^worker_pid=/{print $2}' "$lock/info" | head -1)"
        }
        if [[ -n "$lpid" ]] && kill -0 "$lpid" 2>/dev/null; then
            lock_live=1
            ok "worker lock held by a LIVE wrapper (pid $lpid): $(tr '\n' ' ' <"$lock/info")"
        elif [[ -n "$wpid" ]] && kill -0 "$wpid" 2>/dev/null; then
            lock_live=1
            ok "worker lock held by a LIVE worker process (pid $wpid): $(tr '\n' ' ' <"$lock/info")"
        else
            warn "stale worker lock (no live pid); run-worker will refuse until --break-lock is passed after verification"
        fi
    else
        ok "no worker lock"
    fi

    # --- RUN_STATE is required and must be a structured object -------------------
    local run_state="$agent/RUN_STATE.json"
    local phase="" rs_task="" rs_status="" target=""
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
        target="$(jqv "$run_state" '.target_phase')"
        [[ -n "$rs_status" ]] || issue "RUN_STATE.json has no status"
        if [[ -n "$rs_status" && ! "$rs_status" =~ ^(running|blocked|awaiting_human_qa|idle)$ ]]; then
            issue "RUN_STATE.status '$rs_status' is not a known state"
        fi
        ok "RUN_STATE: phase=${phase:-?} task=${rs_task:-?} status=${rs_status:-?} target=${target:-?}"
    fi

    # --- queue must exist for the current phase and be structurally sound -------
    local pending="" in_progress="" done_list="" escalated="" queue=""
    local phase_required=0
    if [[ "$rs_status" =~ ^(running|blocked|awaiting_human_qa)$ ]]; then
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
            # Each Task must be an object with a non-empty string id and a valid
            # status; missing fields and type errors are ISSUES, not defaults.
            local bad=""
            bad="$(jq -r '[
                .tasks[] | . as $t | select(
                  ($t | type != "object")
                  or ($t.id | (type != "string") or (length == 0))
                  or ($t.status | (type != "string") or (["pending","in_progress","done","escalated","dropped"] | index($t.status) | not))
                )] | length' "$queue" 2>/dev/null || printf '1')"
            local dup="0"
            if [[ "$bad" == "0" ]]; then
                dup="$(jq -r '[.tasks[].id] as $ids | (($ids | length) - ($ids | unique | length))' "$queue" 2>/dev/null || printf '1')"
            fi
            if [[ "$bad" != "0" ]]; then
                issue "$queue has Tasks that are not objects, or have a missing/empty/non-string id, or an unknown status"
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

    # --- current/STATE.json must be readable when it exists ---------------------
    if [[ -e "$current/STATE.json" ]] && ! valid_object "$current/STATE.json"; then
        issue "current/STATE.json exists but is empty or not a JSON object"
    fi

    # --- current task / state / reports -----------------------------------------
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
        if [[ "$rstatus" == "DONE" ]]; then result_ok=1; else result_ok=0; fi
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
        [[ -n "$(section_nonempty "$current/ESCALATION.md" "Current Blocker")" ]] && escalation_ok=1 || escalation_ok=0
        ok "ESCALATION.md: task='${escalation:-?}' blocker=$([[ "$escalation_ok" -eq 1 ]] && echo yes || echo missing)"
        if [[ "$escalation_ok" -ne 1 ]]; then
            issue "ESCALATION.md is present but has no Current Blocker"
        fi
    fi

    # --- consistency --------------------------------------------------------------
    if [[ -n "$in_progress" ]]; then
        local ip_first="${in_progress%%,*}"
        [[ "$cur_task" == "$ip_first" ]] || issue "queue says in_progress=$ip_first but current/TASK.md is '${cur_task:-<none>}' (rewrite TASK.md from the saved definition before resuming)"
        [[ -z "$state_task" || "$state_task" == "$ip_first" ]] || issue "current/STATE.json belongs to task '$state_task' but queue is on '$ip_first'"
        [[ -n "$rs_task" && "$rs_task" != "$ip_first" ]] && issue "RUN_STATE.current_task='$rs_task' does not match the queue in_progress='$ip_first'"
        [[ "$in_progress" == *","* ]] && issue "more than one Task is in_progress in the queue: $in_progress (only one may be)"
        if [[ -z "$escalation" || "$escalation" == "none" ]]; then :; elif [[ "$escalation" != "$ip_first" ]]; then
            issue "ESCALATION.md belongs to task '$escalation' but the queue is on '$ip_first'"
        fi
        if ls -d "$agent/history"/*"-${ip_first}" >/dev/null 2>&1; then
            issue "Task '$ip_first' already has an archive but is still in_progress (verify the archived RESULT, then mark it done instead of re-running)"
        fi
    elif [[ -z "$pending" && -n "$done_list" ]]; then
        if [[ "$rs_status" != "awaiting_human_qa" && "$rs_status" != "done" ]]; then
            warn "all queue tasks are done but RUN_STATE.status=$rs_status (expected awaiting_human_qa after the phase review)"
        fi
    elif [[ -n "$rs_task" && -z "$pending" && -z "$done_list" && -z "$escalated" ]]; then
        warn "RUN_STATE.current_task='$rs_task' but the queue is empty"
    fi
    if [[ "$result" != "none" && "$escalation" != "none" ]]; then
        issue "both RESULT.md and ESCALATION.md exist; resolve before resuming"
    fi
    if [[ "$rs_status" == "awaiting_human_qa" ]]; then
        if [[ -n "$pending" || -n "$in_progress" ]]; then
            issue "RUN_STATE is awaiting_human_qa but the queue still has pending/in_progress Tasks"
        fi
    fi

    # --- archives for done tasks ----------------------------------------------------
    # A missing archive for a done Task is an evidence-completeness warning (the
    # Task is skipped either way); an archive for an in_progress Task is a
    # blocking inconsistency (handled above).
    local t
    if [[ -n "$done_list" ]]; then
        for t in ${done_list//,/ }; do
            if ! ls -d "$agent/history"/*"-${t}" >/dev/null 2>&1; then
                warn "done Task '$t' has no archive (verify its RESULT in the queue history if the evidence matters)"
            fi
        done
    fi

    # --- verdict (stop states first) -------------------------------------------------
    if [[ "$lock_live" -eq 1 ]]; then
        set_verdict "WORKER_RUNNING"
    elif [[ -n "$escalated" ]]; then
        set_verdict "ESCALATED"
    elif [[ "$rs_status" == "blocked" ]]; then
        set_verdict "BLOCKED"
    elif [[ "$rs_status" == "awaiting_human_qa" ]]; then
        set_verdict "CHECKPOINT"
    elif [[ "$ISSUES" -gt 0 ]]; then
        set_verdict "INCONSISTENT"
    elif [[ -n "$in_progress" ]]; then
        if [[ "$result_ok" -eq 1 || "$escalation_ok" -eq 1 ]]; then
            set_verdict "REVIEW_OR_RESUME"
        else
            set_verdict "REVIEW_OR_RESUME"
        fi
    elif [[ -n "$pending" ]]; then
        set_verdict "NEXT"
    elif [[ -n "$done_list" ]]; then
        set_verdict "PHASE_COMPLETE"
    else
        set_verdict "EMPTY"
    fi

    printf '\nverdict: %s' "$VERDICT"
    case "$VERDICT" in
        WORKER_RUNNING)   printf ' - do not start another worker; wait for the report or the [worker-notify] message\n' ;;
        ESCALATED)        printf ' - Task(s) %s need a Supervisor decision; read ESCALATION.md or the queue history\n' "${escalated:-?}" ;;
        BLOCKED)          printf ' - RUN_STATE says blocked; resolve the blocker before resuming\n' ;;
        CHECKPOINT)       printf ' - awaiting_human_qa: stop here; the human decides the next Phase\n' ;;
        INCONSISTENT)     printf ' (%d issue(s)) - fix the issues above before resuming\n' "$ISSUES" ;;
        REVIEW_OR_RESUME) printf ' task=%s - report acceptable=%s; review it, or re-run the same Task (run-worker.sh --allow-dirty)\n' "${in_progress%%,*}" "$([[ "$result_ok" -eq 1 || "$escalation_ok" -eq 1 ]] && echo yes || echo no)" ;;
        NEXT)             printf ' task=%s - hand it off from the queue\n' "${pending%%,*}" ;;
        PHASE_COMPLETE)   printf ' - run the phase final review, then awaiting_human_qa\n' ;;
        EMPTY)            printf ' - no queue state found\n' ;;
    esac

    [[ "$STOP" -eq 0 ]]
}

main "$@"
