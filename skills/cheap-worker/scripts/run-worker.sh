#!/usr/bin/env bash
# run-worker.sh - run exactly one cheap-worker Task via `opencode run`.
#
# This is the Task handoff used by the Phase loop (phase-runner/scripts/run-phase.sh)
# and by Codex directly for a single Task. One run = one OpenCode session.
#
# V1 design:
#   - One Task = one OpenCode session, created on the shared background service,
#     so the session is observable in OpenCode Desktop.
#   - The model is whatever OpenCode's own configuration selects. This script
#     never passes --model and never starts a private server (no --standalone).
#   - The worker prompt embeds the contract, so the worker never needs to read
#     files outside the project root (OpenCode's external_directory permission
#     defaults to "ask" and auto-rejects in non-interactive runs).
#
# Safety properties:
#   - a single project-level lock refuses a second concurrent worker; the lock
#     records both the wrapper pid and the worker pid, and a stale lock is never
#     taken over automatically (use --break-lock after verifying nothing runs)
#   - previous RESULT/ESCALATION/VERIFY/BASELINE* are quarantined before the run,
#     so a stale report can never be mistaken for this run's output
#   - the report must be fresh, carry this Task ID, and be well formed
#   - `--allow-dirty` records the pre-run dirty evidence in BASELINE.md +
#     BASELINE.patch (full `git diff HEAD --binary`)
#   - opencode runs with cwd = project root, even when invoked from elsewhere
#
# Usage:
#   run-worker.sh [--mode implement|investigate|fix|verify] [--root DIR]
#                 [--task-id ID] [--title SHORT_TITLE] [--allow-dirty]
#                 [--break-lock] [--dry-run]
#
# --title is the short Task title (e.g. "Add retry queue"). The OpenCode session
# title becomes "cheap-worker · <task-id> · <SHORT_TITLE>", or "cheap-worker ·
# <task-id>" when --title is omitted (then it is derived from the Objective).
#
# Exit codes:
#   0  fresh, valid RESULT.md from this run (opencode exited 0)
#   1  invalid invocation / invalid or inconsistent TASK.md / other precondition
#   2  opencode failed and wrote no report
#   3  opencode finished but wrote no report
#   4  both reports exist and are valid (inconsistent)
#   5  fresh, valid RESULT.md but opencode exited non-zero (review carefully)
#   6  a report exists but is stale, malformed, or for another Task
#   7  another worker is already running for this project
#   8  stale lock could not be proven dead; re-run with --break-lock after checking
#   10 fresh, valid ESCALATION.md (a decision is required; Class says CHECKPOINT or ESCALATE)
#
# This script never commits, pushes, merges or deletes anything.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The standard primary agent; the worker needs read/search/edit/bash/test tools.
OPENCODE_AGENT="${OPENCODE_AGENT:-build}"

LOCK_OWNED=0
RUN_ID=""
WORKER_PID=""
RUN_STARTED_EPOCH=0

die() { printf 'run-worker: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

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
        pwd -P
        return 0
    fi
    if git rev-parse --show-toplevel >/dev/null 2>&1; then
        git rev-parse --show-toplevel
        return 0
    fi
    pwd -P
}

todo_count() {
    grep -c '^- \[ \]' "$1" 2>/dev/null || true
}

# derive_title <task-file> - first non-empty line of the ## Objective section.
derive_title() {
    local line
    line="$(awk '/^## Objective[[:space:]]*$/{f=1;next} f&&/^## /{exit} f&&NF{print;exit}' "$1")"
    printf '%s' "$line" | tr -d '\r\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | cut -c1-48
}

# section_text <file> <header-without-##> -> first meaningful content lines
section_text() {
    awk -v h="$2" '
        $0 == "## " h || $0 ~ "^## " h "[[:space:]]*$" { f=1; next }
        /^## / { f=0 }
        f { print }
    ' "$1" | grep -v '^[[:space:]]*<!--' | grep -v '^[[:space:]]*$' | head -3 || true
}
validate_task_file() {
    local file="$1" missing="" header content
    for header in "Task ID" "Mode" "Objective" "Acceptance Criteria" "Required Verification" "Allowed Changes" "Forbidden Changes"; do
        content="$(section_text "$file" "$header")"
        if [[ -z "$content" ]]; then
            missing="$missing '$header'"
            continue
        fi
        if printf '%s\n' "$content" | grep -Eq '^[[:space:]]*(- \[ \][[:space:]]*|- )?<'; then
            missing="$missing '$header(placeholder)'"
        fi
    done
    if [[ -n "$missing" ]]; then
        die "TASK.md is incomplete or still a template (missing/placeholder:$missing)"
    fi
}

read_task_id() {
    awk '/^## Task ID[[:space:]]*$/{getline; gsub(/[[:space:]]/,""); print; exit}' "$1"
}

read_mode() {
    awk '/^## Mode[[:space:]]*$/{getline; print; exit}' "$1" | awk '{print $1}'
}

read_report_task_id() {
    awk '/^## Task ID[[:space:]]*$/{getline; gsub(/[[:space:]]/,""); print; exit}' "$1"
}

read_report_status() {
    awk '/^## Status[[:space:]]*$/{getline; gsub(/^[[:space:]]+|[[:space:]]+$/,""); print; exit}' "$1"
}

file_mtime() {
    stat -f %m "$1" 2>/dev/null || { stat -c %Y "$1" 2>/dev/null || printf '0'; }
}

# is_fresh <file> -> 0 when the file was written at/after this run started
is_fresh() {
    local mtime
    mtime="$(file_mtime "$1")"
    [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
    [[ "$mtime" -ge $((RUN_STARTED_EPOCH - 1)) ]]
}

# valid_result <file> -> fresh + Task ID matches + ## Status DONE
valid_result() {
    local f="$1"
    [[ -s "$f" ]] || return 1
    is_fresh "$f" || return 1
    [[ "$(read_report_task_id "$f")" == "$TASK_ID" ]] || return 1
    [[ "$(read_report_status "$f")" == "DONE" ]] || return 1
    return 0
}

# valid_escalation <file> -> fresh + Task ID matches + a blocker section.
# The `## Class` line is read by the caller (run-phase.sh): CHECKPOINT keeps the
# decision soft, anything else - including a missing class - is treated as
# ESCALATE (fail closed).
valid_escalation() {
    local f="$1"
    [[ -s "$f" ]] || return 1
    is_fresh "$f" || return 1
    [[ "$(read_report_task_id "$f")" == "$TASK_ID" ]] || return 1
    [[ -n "$(section_text "$f" "Current Blocker")" ]] || return 1
    return 0
}

release_lock() {
    [[ "$LOCK_OWNED" -eq 1 ]] || return 0
    local lock_dir="$LOCK_DIR"
    if [[ -f "$lock_dir/info" ]] && grep -q "^run_id=$RUN_ID$" "$lock_dir/info" 2>/dev/null; then
        rm -rf "$lock_dir" 2>/dev/null || true
    fi
    LOCK_OWNED=0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    local mode="" root_arg="" task_id_arg="" title_arg="" allow_dirty=0 dry_run=0 break_lock=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)       mode="${2:-}"; shift 2 ;;
            --root)       root_arg="${2:-}"; shift 2 ;;
            --task-id)    task_id_arg="${2:-}"; shift 2 ;;
            --title)      title_arg="${2:-}"; shift 2 ;;
            --allow-dirty) allow_dirty=1; shift ;;
            --break-lock) break_lock=1; shift ;;
            --dry-run)    dry_run=1; shift ;;
            -h|--help)    usage; exit 0 ;;
            *)            die "unknown argument '$1' (try --help)" ;;
        esac
    done

    if [[ -n "$mode" && ! "$mode" =~ ^(implement|investigate|fix|verify)$ ]]; then
        die "invalid --mode '$mode' (expected implement|investigate|fix|verify)"
    fi

    require_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found"; }
    require_cmd opencode
    require_cmd git
    require_cmd jq

    local sk_root
    sk_root="$(skill_root)" || die "cannot locate cheap-worker skill directory"
    local project_root
    project_root="$(resolve_project_root "$root_arg")"

    local task_file="$project_root/.agent/current/TASK.md"
    [[ -f "$task_file" ]] || die "no Task found at $task_file (the Phase loop or Codex writes it first)"
    validate_task_file "$task_file"

    local file_task_id file_mode
    file_task_id="$(read_task_id "$task_file")"
    file_mode="$(read_mode "$task_file")"
    [[ -n "$file_task_id" ]] || die "TASK.md has no Task ID"
    [[ "$file_task_id" =~ ^[A-Za-z0-9._-]+$ ]] || die "TASK.md Task ID '$file_task_id' is not a safe id ([A-Za-z0-9._-])"
    [[ -n "$file_mode" ]] || die "TASK.md has no Mode"
    [[ "$file_mode" =~ ^(implement|investigate|fix|verify)$ ]] || die "TASK.md Mode '$file_mode' is invalid"

    if [[ -n "$task_id_arg" && "$task_id_arg" != "$file_task_id" ]]; then
        die "--task-id '$task_id_arg' does not match TASK.md Task ID '$file_task_id'"
    fi
    if [[ -n "$mode" && "$mode" != "$file_mode" ]]; then
        die "--mode '$mode' does not match TASK.md Mode '$file_mode'"
    fi
    local task_id="$file_task_id"
    TASK_ID="$task_id"   # used by the report validators below
    [[ -n "$mode" ]] || mode="$file_mode"

    # A REVIEW.md (rework) must carry this Task's ID.
    local review_file="$project_root/.agent/current/REVIEW.md"
    if [[ -f "$review_file" ]]; then
        local review_id
        review_id="$(read_task_id "$review_file")"
        if [[ -z "$review_id" ]]; then
            die "REVIEW.md has no '## Task ID' (required so a rework cannot be applied to the wrong Task)"
        fi
        if [[ "$review_id" != "$task_id" ]]; then
            die "REVIEW.md is for Task '$review_id' but TASK.md is '$task_id'"
        fi
    fi

    # Session title, shown in OpenCode Desktop: "cheap-worker · C01 · short title".
    local short_title="${title_arg:-$(derive_title "$task_file")}"
    short_title="${short_title#cheap-worker · $task_id · }"
    local session_title="cheap-worker · $task_id"
    [[ -n "$short_title" ]] && session_title="$session_title · $short_title"

    # Git baseline + dirty evidence (recorded for the Supervisor).
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
            die "commit/stash first, or pass --allow-dirty when the dirty state is intentional (e.g. a resumed/accepted-but-uncommitted Task)"
        fi
    else
        printf '%s\n' "run-worker: warning: '$project_root' is not a git repository; no baseline recording" >&2
    fi

    local agent_dir="$project_root/.agent/current"
    mkdir -p "$agent_dir/logs" "$project_root/.agent/history/attempts"
    local opencode_version
    opencode_version="$(opencode --version 2>/dev/null | head -1)"

    local has_review="no"
    [[ -f "$review_file" ]] && has_review="yes"
    local has_agents_md="no"
    [[ -f "$project_root/AGENTS.md" ]] && has_agents_md="yes"

    local todo_before
    todo_before="$(todo_count "$task_file")"

    RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
    RUN_STARTED_EPOCH="$(date +%s)"

    if [[ "$dry_run" -eq 1 ]]; then
        printf 'run-worker (dry-run)\n'
        printf '  project root : %s\n' "$project_root"
        printf '  task         : %s (mode=%s)\n' "$task_id" "$mode"
        printf '  session title: %s\n' "$session_title"
        printf '  agent        : %s\n' "$OPENCODE_AGENT"
        printf '  baseline     : %s\n' "${baseline:-<none>}"
        printf '  dirty files  : %s\n' "$(printf '%s\n' "$dirty" | grep -c . || true)"
        printf '  run id       : %s\n' "$RUN_ID"
        printf '  opencode     : %s\n' "$opencode_version"
        printf '  review       : %s\n' "$has_review"
        printf '  command      : opencode run --agent %s --format json --title %s  (cwd=%s)\n' "$OPENCODE_AGENT" "$session_title" "$project_root"
        exit 0
    fi

    # --- single-run lock (H03) -------------------------------------------------
    # The lock records both the wrapper pid and the worker process pid. A wrapper
    # death does NOT prove the worker died, so a lock with no live pid is never
    # taken over automatically: the Supervisor must pass --break-lock after
    # verifying nothing is running.
    LOCK_DIR="$agent_dir/.worker.lock"
    write_lock_info() {
        printf 'pid=%s\nworker_pid=%s\nrun_id=%s\ntask_id=%s\nmode=%s\nstarted_at=%s\n' \
            "$$" "${1:-}" "$RUN_ID" "$task_id" "$mode" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$LOCK_DIR/info"
    }
    acquire_lock() {
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            write_lock_info ""
            LOCK_OWNED=1
            return 0
        fi
        local lpid="" wpid="" linfo=""
        if [[ -f "$LOCK_DIR/info" ]]; then
            linfo="$(tr '\n' ' ' <"$LOCK_DIR/info")"
            lpid="$(awk -F= '/^pid=/{print $2}' "$LOCK_DIR/info" | head -1)"
            wpid="$(awk -F= '/^worker_pid=/{print $2}' "$LOCK_DIR/info" | head -1)"
        fi
        if [[ -n "$lpid" && "$lpid" != "$$" ]] && kill -0 "$lpid" 2>/dev/null; then
            printf 'run-worker: another worker wrapper is running for this project (pid %s; %s)\n' "$lpid" "$linfo" >&2
            exit 7
        fi
        if [[ -n "$wpid" ]] && kill -0 "$wpid" 2>/dev/null; then
            printf 'run-worker: the worker process of a previous run is STILL RUNNING (pid %s; %s)\n' "$wpid" "$linfo" >&2
            exit 7
        fi
        if [[ "$break_lock" -ne 1 ]]; then
            printf 'run-worker: stale lock, and the previous run cannot be proven dead:\n  %s\n' "${linfo:-<no lock info>}" >&2
            printf 'run-worker: verify no worker is running (see check-state.sh), then re-run with --break-lock\n' >&2
            exit 8
        fi
        printf 'run-worker: --break-lock given; moving the stale lock aside\n' >&2
        local stale="$project_root/.agent/history/attempts/stale-locks/$(date -u '+%Y%m%dT%H%M%SZ')-${lpid:-unknown}"
        mkdir -p "$stale" && mv "$LOCK_DIR" "$stale/" || die "cannot move stale lock"
        mkdir "$LOCK_DIR" 2>/dev/null || { printf 'run-worker: another worker is already running for this project\n' >&2; exit 7; }
        write_lock_info ""
        LOCK_OWNED=1
    }
    acquire_lock
    # Cancellation is fail-safe: stop the worker we started, then KEEP the lock.
    # The wrapper dying is not proof that the execution is over, so the next run
    # must verify and pass --break-lock instead of taking the lock over silently.
    on_signal() {
        local sig="$1"
        printf 'run-worker: %s received; stopping the worker and KEEPING the lock\n' "$sig" >&2
        if [[ -n "$WORKER_PID" ]] && kill -0 "$WORKER_PID" 2>/dev/null; then
            kill -TERM "$WORKER_PID" 2>/dev/null || true
            local i=0
            while [[ "$i" -lt 50 ]] && kill -0 "$WORKER_PID" 2>/dev/null; do
                sleep 0.2
                i=$((i + 1))
            done
            if kill -0 "$WORKER_PID" 2>/dev/null; then
                printf 'run-worker: worker pid %s did not stop within 10s; lock retained\n' "$WORKER_PID" >&2
            else
                printf 'run-worker: worker stopped; lock retained on purpose after a signal\n' >&2
            fi
        fi
        printf 'cancelled_by=%s\ncancelled_at=%s\n' "$sig" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$LOCK_DIR/info" 2>/dev/null || true
        printf 'run-worker: after verifying nothing is running, re-run with --break-lock\n' >&2
        exit 130
    }
    trap 'on_signal INT' INT
    trap 'on_signal TERM' TERM

    # --- quarantine previous run evidence (H01) --------------------------------
    local prev_run=""
    if [[ -f "$agent_dir/STATE.json" ]]; then
        prev_run="$(jq -r '.run_id // empty' "$agent_dir/STATE.json" 2>/dev/null || true)"
    fi
    for f in RESULT.md ESCALATION.md VERIFY.md BASELINE.md BASELINE.patch; do
        if [[ -s "$agent_dir/$f" ]]; then
            local dest="$project_root/.agent/history/attempts/${task_id}/${prev_run:-prev-$(date -u '+%Y%m%dT%H%M%SZ')}"
            mkdir -p "$dest" && mv "$agent_dir/$f" "$dest/$f"
            printf 'run-worker: quarantined previous %s -> %s\n' "$f" "$dest"
        fi
    done

    # --- baseline evidence (M01) ------------------------------------------------
    {
        printf '# Baseline evidence (before run %s)\n\n' "$RUN_ID"
        printf -- '- task: %s\n' "$task_id"
        printf -- '- mode: %s\n' "$mode"
        printf -- '- HEAD: %s\n' "${baseline:-<no git>}"
        printf -- '- allow-dirty: %s\n\n' "$allow_dirty"
        printf '## git status --porcelain (tracked + untracked)\n\n```\n'
        git -C "$project_root" status --porcelain=v1 --untracked-files=all 2>/dev/null || true
        printf '```\n\n## git diff --stat (unstaged)\n\n```\n'
        git -C "$project_root" diff --stat 2>/dev/null || true
        printf '```\n\n## git diff --cached --stat (staged)\n\n```\n'
        git -C "$project_root" diff --cached --stat 2>/dev/null || true
        printf '```\n\n## Full pre-run patch\n\nThe complete `git diff HEAD --binary` (tracked changes) is stored next to this\nfile as `BASELINE.patch`, so the Supervisor can separate pre-existing changes\nfrom the changes of this run.\n'
    } >"$agent_dir/BASELINE.md"
    if [[ -n "$baseline" ]]; then
        git -C "$project_root" diff --binary HEAD >"$agent_dir/BASELINE.patch" 2>/dev/null || : >"$agent_dir/BASELINE.patch"
    else
        {
            printf 'no HEAD yet: BASELINE.patch cannot be produced (there is nothing to diff against).\n'
            printf 'Repositories without a commit are outside the pre-run recovery guarantee (M01).\n'
        } >"$agent_dir/BASELINE.patch"
    fi

    local log_file="$agent_dir/logs/worker-${RUN_ID}-${task_id}.jsonl"
    local started_at
    started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    printf 'run-worker: task=%s mode=%s run=%s\n' "$task_id" "$mode" "$RUN_ID"
    printf 'run-worker: session title=%s\n' "$session_title"
    printf 'run-worker: project=%s\n' "$project_root"
    printf 'run-worker: baseline=%s (dirty files before run: %s)\n' "${baseline:-<none>}" "$(printf '%s\n' "$dirty" | grep -c . || true)"
    printf 'run-worker: log=%s\n' "$log_file"
    printf 'run-worker: model=OpenCode default (not passed explicitly)\n'

    # Pre-write STATE.json so an interrupted run is still resumable.
    jq -n \
        --arg task_id "$task_id" \
        --arg mode "$mode" \
        --arg run_id "$RUN_ID" \
        --arg project_root "$project_root" \
        --arg baseline_commit "$baseline" \
        --arg opencode_version "$opencode_version" \
        --arg started_at "$started_at" \
        --arg log_file "$log_file" \
        --argjson dirty_count "$(printf '%s\n' "$dirty" | grep -c . || true)" \
        '{task_id: $task_id, mode: $mode, run_id: $run_id, status: "running",
          project_root: $project_root, baseline_commit: $baseline_commit,
          baseline_dirty_count: $dirty_count, opencode_version: $opencode_version,
          session_id: "", started_at: $started_at, finished_at: "",
          last_result: "", log_file: $log_file}' >"$agent_dir/STATE.json"

    # --- run the worker ---------------------------------------------------------
    # Non-interactive run on the shared background service (never --standalone),
    # one session per Task, with cwd pinned to the project root (H02).
    local rc=0
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
- Unticked acceptance items at handoff: ${todo_before:-0}
- Baseline commit: ${baseline:-<no git>}
- This run is one OpenCode session titled "$session_title" (visible in OpenCode Desktop).

Hard boundary: unless TASK.md explicitly allows it, do not modify any file outside
$project_root, and do not read files outside the project root (references are
embedded above - do not try to open the skill directory yourself).

Begin now. Read the Task, follow the contract, write exactly one report file, stop.
EOF
    } | ( cd "$project_root" && exec opencode run \
            --agent "$OPENCODE_AGENT" \
            --format json \
            --title "$session_title" ) >"$log_file" 2>&1 &
    WORKER_PID=$!
    write_lock_info "$WORKER_PID"
    wait "$WORKER_PID" || rc=$?

    local session_id=""
    session_id="$(jq -r 'select(.sessionID) | .sessionID' "$log_file" 2>/dev/null | head -1 || true)"

    local finished_at
    finished_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    # --- validate reports (H01) --------------------------------------------------
    local result_file="$agent_dir/RESULT.md" escalation_file="$agent_dir/ESCALATION.md"
    local result_state="none" escalation_state="none" invalid_reason=""

    if [[ -s "$result_file" ]]; then
        if valid_result "$result_file"; then result_state="valid"; else result_state="invalid";
            invalid_reason="RESULT.md is stale, malformed, or for another Task"; fi
    fi
    if [[ -s "$escalation_file" ]]; then
        if valid_escalation "$escalation_file"; then escalation_state="valid"; else escalation_state="invalid";
            [[ -n "$invalid_reason" ]] || invalid_reason="ESCALATION.md is stale, malformed, or for another Task"; fi
    fi

    local status="failed" last_result="none"
    if [[ "$result_state" == "valid" ]]; then status="result_written"; last_result="RESULT.md"; fi
    if [[ "$escalation_state" == "valid" ]]; then status="escalated"; last_result="ESCALATION.md"; fi
    if [[ "$result_state" == "valid" && "$escalation_state" == "valid" ]]; then
        status="inconsistent"; last_result="RESULT.md+ESCALATION.md"
    fi
    if [[ "$result_state" == "invalid" || "$escalation_state" == "invalid" ]]; then
        status="invalid_report"; last_result="invalid"
    fi
    if [[ "$rc" -ne 0 ]]; then
        case "$status" in
            result_written) status="result_after_failure" ;;
            escalated)      status="escalated" ;;
            inconsistent)   status="inconsistent" ;;
            invalid_report) status="invalid_report" ;;
            *)              status="opencode_failed" ;;
        esac
    fi

    jq -n \
        --arg task_id "$task_id" \
        --arg mode "$mode" \
        --arg run_id "$RUN_ID" \
        --arg project_root "$project_root" \
        --arg baseline_commit "$baseline" \
        --arg opencode_version "$opencode_version" \
        --arg session_id "$session_id" \
        --arg started_at "$started_at" \
        --arg finished_at "$finished_at" \
        --arg status "$status" \
        --arg last_result "$last_result" \
        --arg log_file "$log_file" \
        --arg invalid_reason "$invalid_reason" \
        --argjson rc "$rc" \
        --argjson dirty_count "$(printf '%s\n' "$dirty" | grep -c . || true)" \
        '{task_id: $task_id, mode: $mode, run_id: $run_id, status: $status,
          project_root: $project_root, baseline_commit: $baseline_commit,
          baseline_dirty_count: $dirty_count, opencode_version: $opencode_version,
          session_id: $session_id, started_at: $started_at, finished_at: $finished_at,
          last_result: $last_result, invalid_reason: $invalid_reason,
          opencode_exit_code: $rc, log_file: $log_file}' >"$agent_dir/STATE.json"

    printf 'run-worker: opencode exit=%s session=%s\n' "$rc" "${session_id:-<none>}"
    printf 'run-worker: result=%s\n' "$status"

    release_lock

    if [[ "$result_state" == "valid" && "$escalation_state" == "valid" ]]; then
        printf 'run-worker: ERROR both RESULT.md and ESCALATION.md are valid for this Task; Supervisor must resolve\n' >&2
        exit 4
    fi
    if [[ "$result_state" == "invalid" || "$escalation_state" == "invalid" ]]; then
        printf 'run-worker: ERROR %s\n' "$invalid_reason" >&2
        printf 'run-worker: the file was left in place for inspection; Supervisor must resolve\n' >&2
        exit 6
    fi
    if [[ "$escalation_state" == "valid" ]]; then
        printf 'run-worker: ESCALATION.md written; stopping. Supervisor decision required.\n' >&2
        exit 10
    fi
    if [[ "$result_state" == "valid" ]]; then
        if [[ "$rc" -ne 0 ]]; then
            printf 'run-worker: WARNING opencode exited %s but a valid RESULT.md was written; review before accepting\n' "$rc" >&2
            exit 5
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
