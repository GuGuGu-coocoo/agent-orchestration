#!/usr/bin/env bash
# run-worker.sh - run exactly one cheap-worker Task via the non-interactive OpenCode CLI.
#
# Usage:
#   run-worker.sh [--mode implement|investigate|fix|verify] [--root DIR] [--model provider/model]
#                 [--task-id ID] [--allow-dirty] [--dry-run]
#
# Environment:
#   CHEAP_WORKER_MODEL   model ID (default: opencode/muse-spark-1.3-contributor-free)
#   CHEAP_WORKER_AGENT   opencode agent to run as (default: build)
#
# Exit codes:
#   0  worker wrote RESULT.md (DONE)
#   10 worker wrote ESCALATION.md (stopped, needs Supervisor)
#   1  invalid invocation / precondition failure
#   2  opencode could not be executed successfully
#   3  opencode ran but wrote neither RESULT.md nor ESCALATION.md
#   4  opencode ran and wrote both (inconsistent)
#
# This script never commits, pushes, merges or deletes anything.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_MODEL="${CHEAP_WORKER_MODEL:-opencode/muse-spark-1.3-contributor-free}"
DEFAULT_AGENT="${CHEAP_WORKER_AGENT:-build}"

die() { printf 'run-worker: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

skill_root() {
    local root="$SCRIPT_DIR/.."
    [[ -f "$root/SKILL.md" && -d "$root/references" ]] && { printf '%s\n' "$(cd "$root" && pwd)"; return 0; }
    if [[ -f "$HOME/.agents/skills/cheap-worker/SKILL.md" ]]; then
        printf '%s\n' "$HOME/.agents/skills/cheap-worker"
        return 0
    fi
    return 1
}

resolve_project_root() {
    local given="${1:-}"
    if [[ -n "$given" ]]; then
        cd "$given" || die "cannot cd into --root '$given'"
        pwd
        return 0
    fi
    if git rev-parse --show-toplevel >/dev/null 2>&1; then
        git rev-parse --show-toplevel
        return 0
    fi
    pwd
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found"
}

opencode_env() {
    printf 'env -u OPENCODE_CONFIG -u OPENCODE_CONFIG_CONTENT -u OPENCODE_CONFIG_DIR -u OPENCODE_PERMISSION %s' "$1"
}

todo_count() {
    grep -c '^- \[ \]' "$1" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    local mode="" root_arg="" model="" task_id_arg="" allow_dirty=0 dry_run=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)       mode="${2:-}"; shift 2 ;;
            --root)       root_arg="${2:-}"; shift 2 ;;
            --model)      model="${2:-}"; shift 2 ;;
            --task-id)    task_id_arg="${2:-}"; shift 2 ;;
            --allow-dirty) allow_dirty=1; shift ;;
            --dry-run)    dry_run=1; shift ;;
            -h|--help)    usage; exit 0 ;;
            *)            die "unknown argument '$1' (try --help)" ;;
        esac
    done

    if [[ -n "$mode" && ! "$mode" =~ ^(implement|investigate|fix|verify)$ ]]; then
        die "invalid --mode '$mode' (expected implement|investigate|fix|verify)"
    fi

    require_cmd opencode
    require_cmd git
    require_cmd jq

    local sk_root
    sk_root="$(skill_root)" || die "cannot locate cheap-worker skill directory"
    local project_root
    project_root="$(resolve_project_root "$root_arg")"

    local task_file="$project_root/.agent/current/TASK.md"
    [[ -f "$task_file" ]] || die "no Task found at $task_file (Supervisor must write it first)"

    local task_id
    task_id="${task_id_arg:-$(awk '/^## Task ID[[:space:]]*$/{getline; gsub(/[[:space:]]/,""); print; exit}' "$task_file")}"
    [[ -n "$task_id" ]] || die "could not read Task ID from $task_file (use --task-id)"

    if [[ -z "$mode" ]]; then
        mode="$(awk '/^## Mode[[:space:]]*$/{getline; print; exit}' "$task_file" | awk '{print $1}')"
    fi
    [[ -n "$mode" ]] || die "could not determine mode (set --mode or the '## Mode' section)"
    [[ "$mode" =~ ^(implement|investigate|fix|verify)$ ]] || die "invalid mode '$mode' derived from TASK.md (use --mode)"

    # Model resolution: flag > env > default. Never hardcoded per backend.
    [[ -n "$model" ]] || model="$DEFAULT_MODEL"
    local model_lookup="${model%%#*}"
    # `opencode models` can transiently return a partial list while the background
    # server is busy, so retry before rejecting a model.
    local attempt model_list=""
    for attempt in 1 2 3; do
        model_list="$(opencode models 2>/dev/null || true)"
        if printf '%s\n' "$model_list" | grep -qxF "$model_lookup"; then
            break
        fi
        sleep 2
    done
    if ! printf '%s\n' "$model_list" | grep -qxF "$model_lookup"; then
        die "model '$model_lookup' is not in 'opencode models' output; fix CHEAP_WORKER_MODEL/--model (never guess model IDs)"
    fi

    # Git baseline (best effort: a non-git project or a fresh repo without commits
    # still works, with a warning).
    local baseline="" dirty=""
    if git -C "$project_root" rev-parse --show-toplevel >/dev/null 2>&1; then
        if git -C "$project_root" rev-parse --verify -q HEAD >/dev/null 2>&1; then
            baseline="$(git -C "$project_root" rev-parse HEAD)"
        else
            printf '%s\n' "run-worker: warning: repository has no commits yet; baseline is empty" >&2
        fi
        dirty="$(git -C "$project_root" status --porcelain | grep -v '^\s*..\s*\.agent/' || true)"
        if [[ -n "$dirty" && "$allow_dirty" -eq 0 ]]; then
            printf '%s\n' "run-worker: project is not clean:" >&2
            printf '%s\n' "$dirty" >&2
            die "commit/stash first, or pass --allow-dirty when the dirty state is intentional (e.g. resumed Task)"
        fi
    else
        printf '%s\n' "run-worker: warning: '$project_root' is not a git repository; no baseline recording" >&2
    fi

    local agent_dir="$project_root/.agent/current"
    mkdir -p "$agent_dir/logs"
    local opencode_version
    opencode_version="$(opencode --version 2>/dev/null | head -1)"

    # Review file: optional REWORK corrections for this Task.
    local has_review="no"
    [[ -f "$agent_dir/REVIEW.md" ]] && has_review="yes"
    local has_agents_md="no"
    [[ -f "$project_root/AGENTS.md" ]] && has_agents_md="yes"

    local todo_before
    todo_before="$(todo_count "$task_file")"

    # Render the worker prompt. The contract and safety policy are embedded so the
    # worker never needs to read files outside the project root (OpenCode's
    # external_directory permission defaults to "ask" and auto-rejects in
    # non-interactive runs).
    local prompt_file
    prompt_file="$(mktemp "${TMPDIR:-/tmp}/cheap-worker-prompt.XXXXXX")"
    trap 'rm -f "$prompt_file"' EXIT
    {
        cat "$sk_root/references/worker-prompt.md"
        printf '\n## Working Contract (embedded)\n\n'
        cat "$sk_root/references/worker-contract.md"
        printf '\n## Safety Policy (embedded)\n\n'
        cat "$sk_root/references/safety-policy.md"
        cat <<EOF

## This run

- Project root: $project_root
- Task file: .agent/current/TASK.md
- Mode: $mode
- Task ID: $task_id
- Review file present: $has_review
- AGENTS.md present: $has_agents_md
- Model: $model
- Unticked acceptance items at handoff: ${todo_before:-0}
- Baseline commit: ${baseline:-<no git>}

Hard boundary: unless TASK.md explicitly allows it, do not modify any file outside
$project_root, and do not read files outside the project root (references are
embedded above - do not try to open the skill directory yourself).

Begin now. Read the Task, follow the contract, write exactly one report file, stop.
EOF
    } >"$prompt_file"

    if [[ "$dry_run" -eq 1 ]]; then
        printf 'run-worker (dry-run)\n'
        printf '  project root : %s\n' "$project_root"
        printf '  task         : %s (mode=%s)\n' "$task_id" "$mode"
        printf '  model        : %s\n' "$model"
        printf '  agent        : %s\n' "$DEFAULT_AGENT"
        printf '  baseline     : %s\n' "${baseline:-<none>}"
        printf '  opencode     : %s\n' "$opencode_version"
        printf '  review       : %s\n' "$has_review"
        printf '  prompt file  : %s\n' "$prompt_file"
        printf '  command      : opencode run --model %s --agent %s --format json --title %s\n' "$model" "$DEFAULT_AGENT" "cheap-worker $task_id"
        exit 0
    fi

    local started_at
    started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local log_file="$agent_dir/logs/worker-$(date -u '+%Y%m%dT%H%M%SZ')-${task_id}.jsonl"

    printf 'run-worker: task=%s mode=%s model=%s\n' "$task_id" "$mode" "$model"
    printf 'run-worker: project=%s\n' "$project_root"
    printf 'run-worker: baseline=%s\n' "${baseline:-<none>}"
    printf 'run-worker: log=%s\n' "$log_file"

    # Pre-write STATE.json so an interrupted run is still resumable.
    jq -n \
        --arg task_id "$task_id" \
        --arg mode "$mode" \
        --arg model "$model" \
        --arg project_root "$project_root" \
        --arg baseline_commit "$baseline" \
        --arg opencode_version "$opencode_version" \
        --arg started_at "$started_at" \
        --arg log_file "$log_file" \
        '{task_id: $task_id, mode: $mode, status: "running", model: $model,
          project_root: $project_root, baseline_commit: $baseline_commit,
          opencode_version: $opencode_version, session_id: "",
          started_at: $started_at, finished_at: "", last_result: "",
          attempt_count: 0, log_file: $log_file}' >"$agent_dir/STATE.json"

    # Non-interactive run: stdin prompt, structured JSON event stream to the log.
    local rc=0
    # shellcheck disable=SC2086
    $(opencode_env opencode) run \
        --model "$model" \
        --agent "$DEFAULT_AGENT" \
        --format json \
        --title "cheap-worker $task_id" \
        <"$prompt_file" >"$log_file" 2>&1 || rc=$?

    local session_id=""
    session_id="$(jq -r 'select(.sessionID) | .sessionID' "$log_file" 2>/dev/null | head -1 || true)"

    local finished_at
    finished_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    local has_result=0 has_escalation=0
    [[ -s "$agent_dir/RESULT.md" ]] && has_result=1
    [[ -s "$agent_dir/ESCALATION.md" ]] && has_escalation=1

    local status="failed"
    local last_result="none"
    if [[ "$has_result" -eq 1 ]]; then
        status="result_written"
        last_result="RESULT.md"
    fi
    if [[ "$has_escalation" -eq 1 ]]; then
        status="escalated"
        last_result="ESCALATION.md"
    fi
    if [[ "$has_result" -eq 1 && "$has_escalation" -eq 1 ]]; then
        status="inconsistent"
        last_result="RESULT.md+ESCALATION.md"
    fi
    if [[ "$rc" -ne 0 && "$status" = "failed" ]]; then
        status="opencode_failed"
    fi

    jq -n \
        --arg task_id "$task_id" \
        --arg mode "$mode" \
        --arg model "$model" \
        --arg project_root "$project_root" \
        --arg baseline_commit "$baseline" \
        --arg opencode_version "$opencode_version" \
        --arg session_id "$session_id" \
        --arg started_at "$started_at" \
        --arg finished_at "$finished_at" \
        --arg status "$status" \
        --arg last_result "$last_result" \
        --arg log_file "$log_file" \
        --argjson rc "$rc" \
        '{task_id: $task_id, mode: $mode, status: $status, model: $model,
          project_root: $project_root, baseline_commit: $baseline_commit,
          opencode_version: $opencode_version, session_id: $session_id,
          started_at: $started_at, finished_at: $finished_at,
          last_result: $last_result, opencode_exit_code: $rc, log_file: $log_file}' >"$agent_dir/STATE.json"

    printf 'run-worker: opencode exit=%s session=%s\n' "$rc" "${session_id:-<none>}"
    printf 'run-worker: result=%s\n' "$status"

    if [[ "$has_result" -eq 1 && "$has_escalation" -eq 1 ]]; then
        printf 'run-worker: ERROR both RESULT.md and ESCALATION.md exist; Supervisor must resolve\n' >&2
        exit 4
    fi
    if [[ "$has_escalation" -eq 1 ]]; then
        printf 'run-worker: ESCALATION.md written; stopping. Supervisor decision required.\n' >&2
        exit 10
    fi
    if [[ "$has_result" -eq 1 ]]; then
        if [[ "$rc" -ne 0 ]]; then
            printf 'run-worker: warning: opencode exited %s but RESULT.md was written; review it\n' "$rc" >&2
        fi
        printf '%s\n' 'run-worker: RESULT.md written.'
        exit 0
    fi
    if [[ "$rc" -ne 0 ]]; then
        printf 'run-worker: ERROR opencode exited %s and wrote no report; see %s\n' "$rc" "$log_file" >&2
        exit 2
    fi
    printf 'run-worker: ERROR opencode finished but wrote neither RESULT.md nor ESCALATION.md\n' >&2
    exit 3
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
    esac
    main "$@"
fi
