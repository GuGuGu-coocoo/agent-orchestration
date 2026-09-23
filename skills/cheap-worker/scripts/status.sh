#!/usr/bin/env bash
# status.sh - read-only status of a project's Phase and current worker Task.
#
# Usage:
#   status.sh [--root DIR]
#
# Reports:
#   - project root, Phase, current Task and the loop state (RUN_STATE)
#   - the Task queue progress (done / in_progress / pending / escalated)
#   - the last worker run (STATE.json) and its OpenCode session id
#   - which report files exist (RESULT / ESCALATION + class / VERIFY / REVIEW)
#   - the latest phase and worker logs
#
# Exit codes: 0 always (status is diagnostic).

set -euo pipefail

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; }

resolve_root() {
    local given="${1:-}"
    if [[ -n "$given" ]]; then
        cd "$given" && pwd
        return 0
    fi
    if git rev-parse --show-toplevel >/dev/null 2>&1; then
        git rev-parse --show-toplevel
        return 0
    fi
    pwd
}

jqv() {
    # jqv <file> <jq-filter> <fallback>
    local file="$1" filter="$2" fallback="${3:-}"
    if [[ -f "$file" ]] && command -v jq >/dev/null 2>&1 && jq empty "$file" >/dev/null 2>&1; then
        local out
        out="$(jq -r "$filter" "$file" 2>/dev/null || true)"
        if [[ -n "$out" && "$out" != "null" ]]; then printf '%s' "$out"; return 0; fi
    fi
    printf '%s' "$fallback"
}

section_of() {  # section_of <file> <header> -> first non-empty line
    awk -v h="$2" '
        $0 == "## " h || $0 ~ "^## " h "[[:space:]]*$" { f=1; next }
        /^## / { f=0 }
        f { print }
    ' "$1" | grep -v '^[[:space:]]*$' | head -1 || true
}

main() {
    local root_arg=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --root) root_arg="${2:-}"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) printf 'status: unknown argument %s\n' "$1" >&2; exit 1 ;;
        esac
    done

    local root agent current state run_state
    root="$(resolve_root "$root_arg")"
    agent="$root/.agent"
    current="$agent/current"
    state="$current/STATE.json"
    run_state="$agent/RUN_STATE.json"

    local phase task loop_status stop_reason
    phase="$(jqv "$run_state" '.current_phase' '-')"
    loop_status="$(jqv "$run_state" '.status' '-')"
    stop_reason="$(jqv "$run_state" '.stop_reason' '-')"
    task="$(jqv "$run_state" '.current_task' '-')"

    local task_id mode run_status baseline finished session
    task_id="$(jqv "$state" '.task_id' '-')"
    mode="$(jqv "$state" '.mode' '-')"
    run_status="$(jqv "$state" '.status' 'idle')"
    baseline="$(jqv "$state" '.baseline_commit' '-')"
    finished="$(jqv "$state" '.finished_at' '-')"
    session="$(jqv "$state" '.session_id' '-')"

    if [[ "$task_id" == "-" && -f "$current/TASK.md" ]]; then
        task_id="$(awk '/^## Task ID[[:space:]]*$/{getline; gsub(/[[:space:]]/,""); print; exit}' "$current/TASK.md")"
        mode="$(awk '/^## Mode[[:space:]]*$/{getline; print; exit}' "$current/TASK.md" | awk '{print $1}')"
    fi

    printf 'agent-orchestration status\n'
    printf '  project root : %s\n' "$root"
    printf '  phase        : %s\n' "$phase"
    printf '  loop state   : %s\n' "$loop_status"
    printf '  stop reason  : %s\n' "$stop_reason"
    printf '  current task : %s\n' "$task"
    printf '  task id      : %s\n' "${task_id:--}"
    printf '  mode         : %s\n' "${mode:--}"
    printf '  last run     : %s\n' "$run_status"
    printf '  baseline     : %s\n' "${baseline:--}"
    printf '  finished at  : %s\n' "${finished:--}"
    printf '  session      : %s\n' "${session:--}"
    printf '  model        : OpenCode default (not selected by this skill)\n'

    if [[ -f "$run_state" ]] && [[ "$phase" != "-" ]] && command -v jq >/dev/null 2>&1; then
        local queue="$agent/phases/$phase/TASK_QUEUE.json"
        if [[ -f "$queue" ]] && jq empty "$queue" >/dev/null 2>&1; then
            printf '  queue        : done=%s in_progress=%s pending=%s escalated=%s\n' \
                "$(jqv "$queue" '[.tasks[]|select(.status=="done")|.id]|join(",")' 'none')" \
                "$(jqv "$queue" '[.tasks[]|select(.status=="in_progress")|.id]|join(",")' 'none')" \
                "$(jqv "$queue" '[.tasks[]|select(.status=="pending")|.id]|join(",")' 'none')" \
                "$(jqv "$queue" '[.tasks[]|select(.status=="escalated")|.id]|join(",")' 'none')"
        fi
    fi

    if command -v opencode >/dev/null 2>&1; then
        printf '  opencode     : %s\n' "$(opencode --version 2>/dev/null | head -1)"
    else
        printf '  opencode     : NOT FOUND\n'
    fi

    local f
    for f in TASK.md REVIEW.md RESULT.md ESCALATION.md VERIFY.md STATE.json; do
        if [[ -f "$current/$f" ]]; then
            printf '  file         : %s (%s bytes)\n' "$f" "$(wc -c <"$current/$f" | tr -d ' ')"
        fi
    done
    if [[ -s "$current/ESCALATION.md" ]]; then
        printf '  escalation   : class=%s\n' "$(section_of "$current/ESCALATION.md" "Class")"
    fi
    if [[ -s "$current/VERIFY.md" ]]; then
        printf '  evidence     : %s\n' "$(grep -m1 -E '^- result: ' "$current/VERIFY.md" || printf 'result: <none>')"
    fi

    local latest_phase_log="" latest_worker_log=""
    if [[ -d "$current/logs" ]]; then
        latest_phase_log="$(ls -1 "$current/logs" 2>/dev/null | grep '^phase-' | tail -1 || true)"
        latest_worker_log="$(ls -1 "$current/logs" 2>/dev/null | grep '^worker-' | tail -1 || true)"
    fi
    printf '  phase log    : %s\n' "${latest_phase_log:-<none>}"
    printf '  worker log   : %s\n' "${latest_worker_log:-<none>}"

    # A live run is not something to poll: it wakes the Supervisor itself when it
    # stops (worker-notify / phase-notify), so say so instead of inviting checks.
    local lock lpid wpid live=""
    for lock in "$current/.worker.lock" "$current/.phase.lock"; do
        [[ -d "$lock" && -f "$lock/info" ]] || continue
        lpid="$(awk -F= '/^pid=/{print $2}' "$lock/info" | head -1)"
        wpid="$(awk -F= '/^worker_pid=/{print $2}' "$lock/info" | head -1)"
        if { [[ -n "$lpid" ]] && kill -0 "$lpid" 2>/dev/null; } \
           || { [[ -n "$wpid" ]] && kill -0 "$wpid" 2>/dev/null; }; then
            live="$(basename "$lock")"
            break
        fi
    done
    if [[ -n "$live" ]]; then
        printf '  hint         : %s is live - do not poll; the notifier wakes the Supervisor once the run stops\n' "$live"
    elif [[ "$loop_status" == "running" || "$run_status" == "running" ]]; then
        # The state claims a run in progress, yet no lock holds a live pid: the
        # process died without updating anything and without sending a wake-up.
        # Say so - a stale "running" must never read as progress.
        printf '  warning      : the state says running but nothing is alive - the run stopped without saving it\n'
        printf '  next         : check-state.sh --root "%s"   then recover with --break-lock\n' "$root"
    fi

    exit 0
}

main "$@"
