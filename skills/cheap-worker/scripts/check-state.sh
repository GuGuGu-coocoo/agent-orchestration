#!/usr/bin/env bash
# check-state.sh - read-only consistency check before resuming a Phase.
#
# Cross-checks the files that must agree after an interruption:
#   .agent/current/.worker.lock   (a live worker?)
#   .agent/RUN_STATE.json         (phase/task/status)
#   .agent/current/TASK.md        (the Task in flight)
#   .agent/current/STATE.json     (run id / task / result of the last run)
#   .agent/current/{RESULT,ESCALATION}.md
#   .agent/phases/<phase>/TASK_QUEUE.json   (queue status + in_progress)
#   .agent/history/*              (archives for done tasks)
#
# It never changes anything. Exit 0 when consistent, 1 when issues were found.
#
# Usage:
#   check-state.sh [--root DIR]

set -euo pipefail

usage() { sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

ISSUES=0
issue() { printf '  ISSUE   %s\n' "$*"; ISSUES=$((ISSUES + 1)); }
warn()  { printf '  warn    %s\n' "$*"; }
ok()    { printf '  ok      %s\n' "$*"; }

resolve_root() {
    local given="${1:-}"
    if [[ -n "$given" ]]; then cd "$given" && pwd; return 0; fi
    if git rev-parse --show-toplevel >/dev/null 2>&1; then git rev-parse --show-toplevel; return 0; fi
    pwd
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

# json_ok <file> -> 0 when the file does not exist or parses; 1 when it exists and is broken
json_ok() {
    local file="$1"
    [[ -e "$file" ]] || return 0
    jq empty "$file" >/dev/null 2>&1
}

task_id_of() {
    [[ -f "$1" ]] || { printf ''; return 0; }
    awk '/^## Task ID[[:space:]]*$/{getline; gsub(/[[:space:]]/,""); print; exit}' "$1"
}

main() {
    local root_arg=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --root) root_arg="${2:-}"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) printf 'check-state: unknown argument %s\n' "$1" >&2; exit 1 ;;
        esac
    done

    local root agent run_state current queue phase
    root="$(resolve_root "$root_arg")"
    agent="$root/.agent"
    run_state="$agent/RUN_STATE.json"
    current="$agent/current"

    printf 'check-state: %s\n\n' "$root"

    # --- fail closed on unusable state files -------------------------------------
    local broken="" phase_for_check
    phase_for_check="$(jqv "$agent/RUN_STATE.json" '.current_phase')"
    for f in "$agent/RUN_STATE.json" "$current/STATE.json"; do
        if ! json_ok "$f"; then
            issue "$f exists but is not valid JSON; treat the state as unknown and repair it before resuming"
            broken=1
        fi
    done
    if [[ -n "$phase_for_check" ]] && ! json_ok "$agent/phases/$phase_for_check/TASK_QUEUE.json"; then
        issue "$agent/phases/$phase_for_check/TASK_QUEUE.json is not valid JSON"
        broken=1
    fi
    [[ -n "$broken" ]] && printf '\n'

    # --- lock / live worker -----------------------------------------------------
    local lock="$current/.worker.lock" lock_live=0
    if [[ -d "$lock" ]]; then
        local lpid=""
        [[ -f "$lock/info" ]] && lpid="$(awk -F= '/^pid=/{print $2}' "$lock/info" | head -1)"
        if [[ -n "$lpid" ]] && kill -0 "$lpid" 2>/dev/null; then
            lock_live=1
            ok "worker lock held by a LIVE process (pid $lpid): $(tr '\n' ' ' <"$lock/info")"
        else
            warn "stale worker lock (pid ${lpid:-unknown} not running); the next run will move it aside"
        fi
    else
        ok "no worker lock"
    fi

    # --- run state ---------------------------------------------------------------
    phase="$(jqv "$run_state" '.current_phase')"
    local rs_task rs_status target
    rs_task="$(jqv "$run_state" '.current_task')"
    rs_status="$(jqv "$run_state" '.status' 'idle')"
    target="$(jqv "$run_state" '.target_phase')"
    if [[ -n "$phase" || -n "$rs_status" ]]; then
        ok "RUN_STATE: phase=${phase:-?} task=${rs_task:-?} status=$rs_status target=${target:-?}"
    else
        warn "no usable RUN_STATE.json"
    fi

    # --- queue -------------------------------------------------------------------
    local pending="" in_progress="" done_list=""
    if [[ -n "$phase" && -f "$agent/phases/$phase/TASK_QUEUE.json" ]]; then
        queue="$agent/phases/$phase/TASK_QUEUE.json"
        pending="$(jqv "$queue" '[.tasks[] | select(.status=="pending") | .id] | join(",")')"
        in_progress="$(jqv "$queue" '[.tasks[] | select(.status=="in_progress") | .id] | join(",")')"
        done_list="$(jqv "$queue" '[.tasks[] | select(.status=="done") | .id] | join(",")')"
        ok "queue: done=[${done_list:-none}] in_progress=[${in_progress:-none}] pending=[${pending:-none}]"
    else
        warn "no TASK_QUEUE.json for phase '${phase:-?}'"
    fi

    # --- current task / state / reports ------------------------------------------
    local cur_task state_task
    cur_task="$(task_id_of "$current/TASK.md")"
    state_task="$(jqv "$current/STATE.json" '.task_id')"
    if [[ -n "$cur_task" && "$cur_task" == *"<"* ]]; then cur_task=""; fi
    printf '\n'
    ok "current/TASK.md task id: ${cur_task:-<none/template>}"
    ok "current/STATE.json task id: ${state_task:-<none>} status=$(jqv "$current/STATE.json" '.status' '?') run=$(jqv "$current/STATE.json" '.run_id' '?')"

    local result="none" escalation="none"
    [[ -s "$current/RESULT.md" ]] && result="$(task_id_of "$current/RESULT.md")"
    [[ -s "$current/ESCALATION.md" ]] && escalation="$(task_id_of "$current/ESCALATION.md")"
    if [[ "$result" != "none" ]]; then ok "RESULT.md for task '${result:-?}'"; fi
    if [[ "$escalation" != "none" ]]; then ok "ESCALATION.md for task '${escalation:-?}'"; fi

    # --- consistency ---------------------------------------------------------------
    if [[ -n "$in_progress" ]]; then
        local ip_first="${in_progress%%,*}"
        [[ "$cur_task" == "$ip_first" ]] || issue "queue says in_progress=$ip_first but current/TASK.md is '${cur_task:-<none>}' (rewrite TASK.md from the saved definition before resuming)"
        [[ -z "$state_task" || "$state_task" == "$ip_first" ]] || issue "current/STATE.json belongs to task '$state_task' but queue is on '$ip_first'"
        if [[ "$result" != "none" && "$result" != "$ip_first" ]]; then
            issue "RESULT.md belongs to task '$result' but the queue is on '$ip_first' (stale report? check .agent/history/attempts/)"
        fi
        if [[ "$escalation" != "none" && "$escalation" != "$ip_first" ]]; then
            issue "ESCALATION.md belongs to task '$escalation' but the queue is on '$ip_first'"
        fi
        if [[ -n "$rs_task" && "$rs_task" != "$ip_first" ]]; then
            issue "RUN_STATE.current_task='$rs_task' does not match the queue in_progress='$ip_first'"
        fi
        if [[ "$in_progress" == *","* ]]; then
            issue "more than one Task is in_progress in the queue: $in_progress (only one may be)"
        fi
        if ls -d "$agent/history"/*"-${ip_first}" >/dev/null 2>&1; then
            issue "Task '$ip_first' already has an archive but is still in_progress (verify the archived RESULT, then mark it done instead of re-running)"
        fi
    elif [[ -z "$pending" && -n "$done_list" ]]; then
        if [[ "$rs_status" != "awaiting_human_qa" && "$rs_status" != "done" ]]; then
            warn "all queue tasks are done but RUN_STATE.status=$rs_status (expected awaiting_human_qa after the phase review)"
        fi
    elif [[ -n "$rs_task" && -z "$pending" && -z "$done_list" ]]; then
        warn "RUN_STATE.current_task='$rs_task' but the queue is empty"
    fi
    if [[ "$result" != "none" && "$escalation" != "none" ]]; then
        issue "both RESULT.md and ESCALATION.md exist; resolve before resuming"
    fi

    # --- archives for done tasks ----------------------------------------------------
    local missing_archives=""
    if [[ -n "$done_list" ]]; then
        local t
        for t in ${done_list//,/ }; do
            if ! ls -d "$agent/history"/*"-${t}" >/dev/null 2>&1; then
                missing_archives="$missing_archives $t"
            fi
        done
    fi
    [[ -n "$missing_archives" ]] && issue "done tasks without an archive:$missing_archives (archive them or verify their RESULT before continuing)"

    # --- verdict ----------------------------------------------------------------------
    printf '\nverdict: '
    if [[ "$lock_live" -eq 1 ]]; then
        printf 'WORKER_RUNNING - do not start another worker; wait for the report or the [worker-notify] message\n'
    elif [[ "$ISSUES" -gt 0 ]]; then
        printf 'INCONSISTENT (%d issue(s)) - fix the issues above before resuming\n' "$ISSUES"
    elif [[ -n "$in_progress" ]]; then
        printf 'REVIEW_OR_RESUME task=%s - report ready: %s | no report: re-run the same Task (run-worker.sh --allow-dirty)\n' \
            "${in_progress%%,*}" "$([[ "$result" != "none" || "$escalation" != "none" ]] && echo yes || echo no)"
    elif [[ -n "$pending" ]]; then
        printf 'NEXT task=%s - hand it off from the queue\n' "${pending%%,*}"
    elif [[ -n "$done_list" ]]; then
        printf 'PHASE_COMPLETE - run the phase final review, then awaiting_human_qa\n'
    else
        printf 'EMPTY - no queue state found; start from phase intake\n'
    fi

    [[ "$ISSUES" -eq 0 ]]
}

main "$@"
