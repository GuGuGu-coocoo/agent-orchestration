#!/usr/bin/env bash
# worker-notify.sh - run one cheap-worker Task in the background, hold a no-sleep
# assertion while it runs, and wake the Codex Supervisor session when it finishes.
#
# Why: the Supervisor can hand off a Task and end its turn instead of blocking on
# a shell call. When the worker is done, a short message is delivered to the same
# Codex session with `codex queue`, which starts a new turn there so Codex can
# review (ACCEPT / REWORK) and hand off the next Task.
#
# Usage:
#   worker-notify.sh [run-worker options...]          # session auto-detected
#   worker-notify.sh --codex-thread NAME_OR_ID [...]  # explicit session
#   worker-notify.sh --foreground [...]               # stay attached (debug)
#   worker-notify.sh --print-message --simulate-exit 10
#   worker-notify.sh --print-session                  # show the detected session
#
# The Codex session is auto-detected from Codex's own local history: the
# orchestration session is the one running this script, i.e. the thread with the
# most recent activity (archived threads are skipped, a session rooted at this
# project is preferred). Override with --codex-thread when needed.
#
# Options (all other options are forwarded to run-worker.sh):
#   --codex-thread NAME    Codex session name or id (default: auto-detect)
#   --no-notify            run the worker but do not wake Codex
#   --foreground           do not detach (default: detached; use for tests/debug)
#   --print-message        dry-run: print the wake-up message and exit
#   --print-session        print the detected session (id, title, cwd) and exit
#   --simulate-exit N      exit code to use with --print-message (0|10|other)
#   --message-prefix STR   optional prefix for the wake-up message
#   --codex-bin PATH       codex CLI path (default: auto-detect)
#   -h|--help
#
# Environment: WORKER_NOTIFY_CODEX_HOME (default ~/.codex), CODEX_BIN,
#              WORKER_NOTIFY_RUN_WORKER (default: sibling run-worker.sh)
#
# Exit codes: the worker's exit code (foreground/print mode);
#             0 when the background launch succeeded.
#
# This script never commits, pushes, merges or deletes anything.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_WORKER="${WORKER_NOTIFY_RUN_WORKER:-$SCRIPT_DIR/run-worker.sh}"
DETACHED="${WORKER_NOTIFY_DETACHED:-0}"

CODEX_THREAD=""
NO_NOTIFY=0
FOREGROUND=0
PRINT_MESSAGE=0
PRINT_SESSION=0
SIMULATE_EXIT=0
MESSAGE_PREFIX=""
CODEX_BIN_OPT=""
ORIG_ARGS=("$@")
FORWARD=()
CODEX_HOME_DIR="${WORKER_NOTIFY_CODEX_HOME:-$HOME/.codex}"

die() { printf 'worker-notify: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,42p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# --- argument parsing ---------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --codex-thread)   CODEX_THREAD="${2:-}"; shift 2 ;;
        --no-notify)      NO_NOTIFY=1; shift ;;
        --foreground)     FOREGROUND=1; shift ;;
        --print-message)  PRINT_MESSAGE=1; shift ;;
        --print-session)  PRINT_SESSION=1; shift ;;
        --simulate-exit)  SIMULATE_EXIT="${2:-0}"; shift 2 ;;
        --message-prefix) MESSAGE_PREFIX="${2:-}"; shift 2 ;;
        --codex-bin)      CODEX_BIN_OPT="${2:-}"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *)                FORWARD+=("$1"); shift ;;
    esac
done

if [[ "$PRINT_MESSAGE" -eq 0 && "$PRINT_SESSION" -eq 0 && "$NO_NOTIFY" -eq 0 && "$CODEX_THREAD" == "auto" ]]; then
    CODEX_THREAD=""
fi
[[ -x "$RUN_WORKER" ]] || die "run-worker.sh not found or not executable: $RUN_WORKER"

# --- project root / task id (for logs and message paths) ----------------------
forward_value() {
    local key="$1" i=0
    while [[ "$i" -lt "${#FORWARD[@]}" ]]; do
        if [[ "${FORWARD[$i]}" == "$key" ]]; then
            printf '%s' "${FORWARD[$((i + 1))]:-}"
            return 0
        fi
        i=$((i + 1))
    done
    return 0
}

resolve_root() {
    local given
    given="$(forward_value --root)"
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
    local id
    id="$(forward_value --task-id)"
    if [[ -z "$id" && -f "$1/.agent/current/TASK.md" ]]; then
        id="$(awk '/^## Task ID[[:space:]]*$/{getline; gsub(/[[:space:]]/,""); print; exit}' "$1/.agent/current/TASK.md")"
    fi
    printf '%s' "${id:--}"
}

# --- Codex session auto-discovery ---------------------------------------------
# The orchestration session is the one running this script, so it is the Codex
# thread with the most recent activity in Codex's own local history. Reading that
# is what lets the human just say "use $phase-runner ..." without naming a session.
state_db_path() {
    ls -t "$CODEX_HOME_DIR"/state_*.sqlite 2>/dev/null | head -1
}

history_db_path() {
    ls -t "$CODEX_HOME_DIR"/thread_history_*.sqlite 2>/dev/null | head -1
}

thread_row() {
    # thread_row <id> -> "title|cwd|updated" (or empty)
    local state="$1" id="$2"
    [[ -n "$state" ]] || return 0
    sqlite3 -separator '|' "$state" \
        "SELECT COALESCE(title,''), COALESCE(cwd,''), COALESCE(datetime(updated_at,'unixepoch','localtime'),'') FROM threads WHERE id='$id' LIMIT 1;" \
        2>/dev/null || true
}

discover_thread() {
    local hist state candidates id arch row fallback=""
    command -v sqlite3 >/dev/null 2>&1 || return 1
    hist="$(history_db_path)"
    state="$(state_db_path)"
    [[ -n "$hist" ]] || return 1
    candidates="$(sqlite3 "$hist" \
        "SELECT thread_id FROM thread_items GROUP BY thread_id ORDER BY max(created_at_ms) DESC LIMIT 8;" \
        2>/dev/null || true)"
    [[ -n "$candidates" ]] || return 1
    for id in $candidates; do
        [[ -n "$id" ]] || continue
        arch=""
        row=""
        if [[ -n "$state" ]]; then
            arch="$(sqlite3 "$state" "SELECT archived FROM threads WHERE id='$id' LIMIT 1;" 2>/dev/null || true)"
        fi
        [[ "$arch" == "1" ]] && continue
        row="$(thread_row "$state" "$id")"
        if [[ -n "$state" ]]; then
            local cwd="${row#*|}"; cwd="${cwd%%|*}"
            if [[ -n "$cwd" && ( "$ROOT" == "$cwd" || "$ROOT" == "$cwd"/* \
                || "$ROOT_PHYS" == "$cwd" || "$ROOT_PHYS" == "$cwd"/* ) ]]; then
                printf '%s' "$id"
                return 0
            fi
        fi
        [[ -z "$fallback" ]] && fallback="$id"
    done
    if [[ -n "$fallback" ]]; then
        printf '%s' "$fallback"
        return 0
    fi
    return 1
}

ROOT="$(resolve_root)"
ROOT_PHYS="$(cd "$ROOT" 2>/dev/null && pwd -P || printf '%s' "$ROOT")"
TASK_ID="$(read_task_id "$ROOT")"

if [[ "$PRINT_SESSION" -eq 1 ]]; then
    if DISCOVERED="$(discover_thread)"; then
        STATE_DB="$(state_db_path)"
        ROW="$(thread_row "$STATE_DB" "$DISCOVERED")"
        printf '%s\t%s\n' "$DISCOVERED" "${ROW:-<no thread metadata>}"
        exit 0
    fi
    printf 'worker-notify: no Codex session could be discovered in %s\n' "$CODEX_HOME_DIR" >&2
    exit 1
fi

# --- wake-up message ----------------------------------------------------------
compose_message() {
    local rc="$1" id="$2" root="$3" msg
    case "$rc" in
        0)
            msg="[worker-notify] $id 完成。请验收：读 $root/.agent/current/RESULT.md + git diff + 必要测试 → ACCEPT（归档并发下一个 Task）或 REWORK（写 REVIEW.md 后重新投递）。"
            ;;
        10)
            msg="[worker-notify] $id 需要你决策（ESCALATION.md）。请读 $root/.agent/current/ESCALATION.md，处理后决定下一步。"
            ;;
        *)
            msg="[worker-notify] $id 失败（exit=${rc}，无报告）。请检查 $root/.agent/current/STATE.json 与 $root/.agent/current/logs/，决定重试或升级。"
            ;;
    esac
    if [[ -n "$MESSAGE_PREFIX" ]]; then
        msg="$MESSAGE_PREFIX $msg"
    fi
    printf '%s' "$msg"
}

if [[ "$PRINT_MESSAGE" -eq 1 ]]; then
    printf '%s\n' "$(compose_message "$SIMULATE_EXIT" "$TASK_ID" "$ROOT")"
    exit 0
fi

# --- resolve the Codex session (explicit name/id or auto-discovery) -----------
if [[ "$NO_NOTIFY" -eq 0 && -z "$CODEX_THREAD" ]]; then
    if CODEX_THREAD="$(discover_thread)"; then
        printf 'worker-notify: session auto-detected: %s\n' "$CODEX_THREAD"
    else
        CODEX_THREAD=""
        printf 'worker-notify: WARNING no Codex session could be auto-detected; the result will be saved to NOTIFY_FAILED.md\n' >&2
    fi
fi

# --- detach (default): re-exec in the background and return immediately -------
if [[ "$FOREGROUND" -eq 0 && "$DETACHED" != "1" ]]; then
    mkdir -p "$ROOT/.agent/current/logs"
    LOG_FILE="$ROOT/.agent/current/logs/notify-$(date -u '+%Y%m%dT%H%M%SZ')-${TASK_ID}.log"
    CHILD_ARGS=(${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"} --foreground)
    if [[ -n "$CODEX_THREAD" ]]; then
        CHILD_ARGS+=(--codex-thread "$CODEX_THREAD")
    fi
    WORKER_NOTIFY_DETACHED=1 nohup bash "$0" "${CHILD_ARGS[@]}" >"$LOG_FILE" 2>&1 &
    PID=$!
    printf 'worker-notify: background worker started (pid %s)\n' "$PID"
    printf 'worker-notify: task=%s\n' "$TASK_ID"
    printf 'worker-notify: log=%s\n' "$LOG_FILE"
    if [[ "$NO_NOTIFY" -eq 0 && -n "$CODEX_THREAD" ]]; then
        printf 'worker-notify: will wake Codex session "%s" when done\n' "$CODEX_THREAD"
    fi
    exit 0
fi

# --- run the worker, holding a no-sleep assertion while it runs ---------------
worker_rc=0
"$RUN_WORKER" ${FORWARD[@]+"${FORWARD[@]}"} &
worker_pid=$!
caffeinate_pid=""
if command -v caffeinate >/dev/null 2>&1; then
    caffeinate -i -w "$worker_pid" >/dev/null 2>&1 &
    caffeinate_pid=$!
fi
wait "$worker_pid" || worker_rc=$?
if [[ -n "$caffeinate_pid" ]]; then
    kill "$caffeinate_pid" 2>/dev/null || true
    wait "$caffeinate_pid" 2>/dev/null || true
fi

printf 'worker-notify: worker exit=%s\n' "$worker_rc"

# --- wake the Codex session ---------------------------------------------------
if [[ "$NO_NOTIFY" -eq 1 ]]; then
    exit "$worker_rc"
fi

detect_codex_bin() {
    if [[ -n "$CODEX_BIN_OPT" ]]; then printf '%s' "$CODEX_BIN_OPT"; return 0; fi
    if [[ -n "${CODEX_BIN:-}" ]]; then printf '%s' "$CODEX_BIN"; return 0; fi
    if command -v codex >/dev/null 2>&1; then command -v codex; return 0; fi
    local p
    for p in "/Applications/ChatGPT.app/Contents/Resources/codex" \
             "$HOME/Applications/ChatGPT.app/Contents/Resources/codex"; do
        if [[ -x "$p" ]]; then printf '%s' "$p"; return 0; fi
    done
    return 1
}

notify_failed() {
    local msg="$1" reason="$2" hint="${3:-}"
    printf 'worker-notify: WARNING could not reach Codex session "%s": %s\n' "$CODEX_THREAD" "$reason" >&2
    {
        printf '# Notification not delivered\n\n'
        printf -- '- at: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf -- '- thread: %s\n' "$CODEX_THREAD"
        printf -- '- reason: %s\n' "$reason"
        if [[ -n "$hint" ]]; then
            printf -- '- hint: %s\n' "$hint"
        fi
        printf '\n## Message to paste manually\n\n%s\n' "$msg"
    } >"$ROOT/.agent/current/NOTIFY_FAILED.md"
    printf 'worker-notify: message saved to %s/.agent/current/NOTIFY_FAILED.md\n' "$ROOT"
    if command -v osascript >/dev/null 2>&1; then
        osascript -e 'display notification "worker 结束，但 Codex 会话不可达（见 NOTIFY_FAILED.md）" with title "worker-notify"' >/dev/null 2>&1 || true
    fi
}

MESSAGE="$(compose_message "$worker_rc" "$TASK_ID" "$ROOT")"

# Last chance: if the session was not resolved at launch (e.g. discovery failed),
# try again now - the launching session has been active since.
if [[ -z "$CODEX_THREAD" ]]; then
    if CODEX_THREAD="$(discover_thread)"; then
        printf 'worker-notify: session auto-detected at wake time: %s\n' "$CODEX_THREAD"
    fi
fi

if [[ -z "$CODEX_THREAD" ]]; then
    notify_failed "$MESSAGE" "no Codex session could be auto-detected" \
        "pass --codex-thread <name or id>, or keep the orchestration session open in the app"
    exit "$worker_rc"
fi

CODEX_BIN_PATH=""
if CODEX_BIN_PATH="$(detect_codex_bin)"; then
    QUEUE_OUT=""
    if QUEUE_OUT="$("$CODEX_BIN_PATH" queue --thread "$CODEX_THREAD" --message "$MESSAGE" 2>&1)"; then
        printf '%s\n' "$QUEUE_OUT"
        printf 'worker-notify: Codex session "%s" notified\n' "$CODEX_THREAD"
        rm -f "$ROOT/.agent/current/NOTIFY_FAILED.md"
    else
        printf '%s\n' "$QUEUE_OUT" >&2
        HINT=""
        case "$QUEUE_OUT" in
            *archived*)
                HINT="the session is archived: reopen it in the ChatGPT/Codex app, or run 'codex unarchive <session-id>'"
                ;;
            *"No active session"*)
                HINT="no active session with that name: keep the orchestration session OPEN in the app (an open session can be woken; a closed one cannot)"
                ;;
        esac
        notify_failed "$MESSAGE" "codex queue failed" "$HINT"
    fi
else
    notify_failed "$MESSAGE" "codex CLI not found (install ChatGPT desktop app or set --codex-bin)"
fi

exit "$worker_rc"
