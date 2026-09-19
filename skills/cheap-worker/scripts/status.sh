#!/usr/bin/env bash
# status.sh - read-only status of the current worker Task for a project.
#
# Usage:
#   status.sh [--root DIR]
#
# Reports:
#   - project root, current Task ID and mode
#   - current state (STATE.json) and the OpenCode session id
#   - OpenCode version
#   - whether RESULT.md / ESCALATION.md / REVIEW.md exist
#   - the latest worker log
#
# Exit codes: 0 always (status is diagnostic).

set -euo pipefail

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

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

main() {
    local root_arg=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --root) root_arg="${2:-}"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) printf 'status: unknown argument %s\n' "$1" >&2; exit 1 ;;
        esac
    done

    local root current state
    root="$(resolve_root "$root_arg")"
    current="$root/.agent/current"
    state="$current/STATE.json"

    local task_id mode status baseline finished session
    task_id="$(jqv "$state" '.task_id' '-')"
    mode="$(jqv "$state" '.mode' '-')"
    status="$(jqv "$state" '.status' 'idle')"
    baseline="$(jqv "$state" '.baseline_commit' '-')"
    finished="$(jqv "$state" '.finished_at' '-')"
    session="$(jqv "$state" '.session_id' '-')"

    if [[ "$task_id" == "-" && -f "$current/TASK.md" ]]; then
        task_id="$(awk '/^## Task ID[[:space:]]*$/{getline; gsub(/[[:space:]]/,""); print; exit}' "$current/TASK.md")"
        mode="$(awk '/^## Mode[[:space:]]*$/{getline; print; exit}' "$current/TASK.md" | awk '{print $1}')"
    fi

    printf 'cheap-worker status\n'
    printf '  project root : %s\n' "$root"
    printf '  task id      : %s\n' "${task_id:--}"
    printf '  mode         : %s\n' "${mode:--}"
    printf '  state        : %s\n' "$status"
    printf '  baseline     : %s\n' "${baseline:--}"
    printf '  finished at  : %s\n' "${finished:--}"
    printf '  session      : %s\n' "${session:--}"
    printf '  model        : OpenCode default (not selected by this skill)\n'
    if command -v opencode >/dev/null 2>&1; then
        printf '  opencode     : %s\n' "$(opencode --version 2>/dev/null | head -1)"
    else
        printf '  opencode     : NOT FOUND\n'
    fi

    local f
    for f in TASK.md REVIEW.md RESULT.md ESCALATION.md STATE.json; do
        if [[ -f "$current/$f" ]]; then
            printf '  file         : %s (%s)\n' "$f" "$(wc -c <"$current/$f" | tr -d ' ') bytes"
        fi
    done

    local latest_log=""
    if [[ -d "$current/logs" ]]; then
        latest_log="$(ls -1 "$current/logs" 2>/dev/null | tail -1 || true)"
    fi
    printf '  latest log   : %s\n' "${latest_log:-<none>}"

    exit 0
}

main "$@"
