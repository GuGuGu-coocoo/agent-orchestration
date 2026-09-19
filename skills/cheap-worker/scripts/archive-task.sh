#!/usr/bin/env bash
# archive-task.sh - archive the current Task's artifacts into .agent/history/.
#
# Called by the Supervisor AFTER a review decision (normally ACCEPT), never by the
# worker itself. Non-destructive up to .agent/history: it moves files, it never
# deletes project code.
#
# Usage:
#   archive-task.sh [--root DIR] [--task-id ID] --yes [--decision ACCEPT|REWORK|ESCALATE]
#
# Effects:
#   .agent/current/{TASK.md,RESULT.md,REVIEW.md,ESCALATION.md,STATE.json,BASELINE.md,BASELINE.patch,logs/}
#     -> .agent/history/<UTC timestamp>-<task-id>/
#   .agent/current/{TASK.md,STATE.json} are re-seeded from the skill templates.
#
# Exit codes: 0 archived, 1 invalid invocation/precondition.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die()   { printf 'archive-task: %s\n' "$*" >&2; exit 1; }

skill_root() {
    local root="$SCRIPT_DIR/.."
    [[ -f "$root/SKILL.md" ]] && { printf '%s\n' "$(cd "$root" && pwd)"; return 0; }
    [[ -f "$HOME/.agents/skills/cheap-worker/SKILL.md" ]] && { printf '%s\n' "$HOME/.agents/skills/cheap-worker"; return 0; }
    return 1
}

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

read_task_id() {
    # Extracts the Task ID from TASK.md and strips trailing comments/whitespace.
    awk '/^## Task ID[[:space:]]*$/{getline; print; exit}' "$1" \
        | sed 's/<!--.*-->//' \
        | sed 's/[[:space:]]*$//'
}

main() {
    local root_arg="" task_id="" decision="ACCEPT" confirmed=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --root)     root_arg="${2:-}"; shift 2 ;;
            --task-id)  task_id="${2:-}"; shift 2 ;;
            --decision) decision="${2:-}"; shift 2 ;;
            --yes|-y)   confirmed=1; shift ;;
            -h|--help)  usage; exit 0 ;;
            *) die "unknown argument '$1' (try --help)" ;;
        esac
    done

    [[ "$decision" =~ ^(ACCEPT|REWORK|ESCALATE)$ ]] || die "invalid --decision '$decision'"

    local root current history
    root="$(resolve_root "$root_arg")"
    current="$root/.agent/current"
    history="$root/.agent/history"
    [[ -d "$current" ]] || die "no .agent/current in $root"

    if [[ -f "$current/TASK.md" && -z "$task_id" ]]; then
        task_id="$(read_task_id "$current/TASK.md")"
    fi
    if [[ -z "$task_id" || "$task_id" == *"<"* || "$task_id" == *">"* || ! "$task_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
        die "cannot determine a safe Task ID (got '${task_id:-<empty>}'); use --task-id"
    fi

    local has_result=0
    [[ -s "$current/RESULT.md" ]] && has_result=1
    if [[ "$has_result" -eq 0 && -z "$(ls -A "$current" 2>/dev/null)" ]]; then
        die "nothing to archive in $current"
    fi

    local stamp archive
    stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
    archive="$history/${stamp}-${task_id}"

    if [[ "$confirmed" -eq 0 ]]; then
        printf 'archive-task: will move the current Task artifacts to:\n  %s\n' "$archive"
        printf 'archive-task: use --yes to confirm (non-interactive safe).\n' >&2
        exit 1
    fi

    mkdir -p "$archive"
    for f in TASK.md RESULT.md REVIEW.md ESCALATION.md STATE.json BASELINE.md BASELINE.patch; do
        [[ -e "$current/$f" ]] && mv "$current/$f" "$archive/$f"
    done
    if [[ -d "$current/logs" ]]; then
        mv "$current/logs" "$archive/logs"
    fi
    mkdir -p "$current/logs"

    # Record the review decision next to the artifacts.
    {
        printf '# Archive Record\n\n'
        printf -- '- Task ID: %s\n' "$task_id"
        printf -- '- Decision: %s\n' "$decision"
        printf -- '- Archived at: %s\n' "$stamp"
        printf -- '- Source: .agent/current\n'
    } >"$archive/REVIEW_DECISION.md"

    # Re-seed a blank workspace for the next Task.
    local sk
    if sk="$(skill_root)"; then
        [[ -f "$sk/assets/templates/TASK.md" ]] && cp "$sk/assets/templates/TASK.md" "$current/TASK.md"
        [[ -f "$sk/assets/templates/STATE.json" ]] && cp "$sk/assets/templates/STATE.json" "$current/STATE.json"
    fi

    printf 'archive-task: archived task %s -> %s\n' "$task_id" "$archive"
    exit 0
}

main "$@"
