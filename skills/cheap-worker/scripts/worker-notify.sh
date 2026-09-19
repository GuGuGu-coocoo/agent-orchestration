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
#   worker-notify.sh --codex-thread <id-or-name> [run-worker options...]
#   worker-notify.sh [run-worker options...]   # uses CODEX_THREAD_ID if the runtime set it
#   worker-notify.sh --foreground [...]        # stay attached (debug)
#   worker-notify.sh --print-message --simulate-exit 5
#   worker-notify.sh --print-target            # show the resolved target, if any
#
# The wake-up target must be identified exactly: pass --codex-thread, or have the
# runtime provide CODEX_THREAD_ID. There is NO guessing from local history - a
# wrong guess would wake another conversation. Without a target the helper fails
# closed (exit 14) and the Supervisor uses run-worker.sh (blocking) instead.
#
# Options (all other options are forwarded to run-worker.sh):
#   --codex-thread NAME    Codex session id or exact name (required unless
#                          CODEX_THREAD_ID is set by the calling runtime) or --no-notify
#   --no-notify            run the worker but do not wake Codex
#   --foreground           do not detach (default: detached; use for tests/debug)
#   --print-message        dry-run: print the wake-up message and exit
#   --print-target         print the resolved target session and exit
#   --simulate-exit N      exit code to use with --print-message (0|5|10|other)
#   --message-prefix STR   optional prefix for the wake-up message
#   --codex-bin PATH       codex CLI path (default: auto-detect)
#   -h|--help
#
# Environment: CODEX_THREAD_ID (exact calling session, when provided),
#              WORKER_NOTIFY_CODEX_HOME (default ~/.codex), CODEX_BIN,
#              WORKER_NOTIFY_RUN_WORKER (default: sibling run-worker.sh)
#
# Exit codes: the worker's exit code (foreground mode);
#             0 when the background launch succeeded;
#             14 no exact target (refusing to guess);
#             15 the worker finished but the wake-up could not be delivered.
#
# This script never commits, pushes, merges or deletes anything.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_WORKER="${WORKER_NOTIFY_RUN_WORKER:-$SCRIPT_DIR/run-worker.sh}"
DETACHED="${WORKER_NOTIFY_DETACHED:-0}"

CODEX_THREAD_ARG=""
CODEX_THREAD=""
NOTIFY_FAILED=0
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
        --codex-thread)   CODEX_THREAD_ARG="${2:-}"; shift 2 ;;
        --no-notify)      NO_NOTIFY=1; shift ;;
        --foreground)     FOREGROUND=1; shift ;;
        --print-message)  PRINT_MESSAGE=1; shift ;;
        --print-session|--print-target) PRINT_SESSION=1; shift ;;
        --simulate-exit)  SIMULATE_EXIT="${2:-0}"; shift 2 ;;
        --message-prefix) MESSAGE_PREFIX="${2:-}"; shift 2 ;;
        --codex-bin)      CODEX_BIN_OPT="${2:-}"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *)                FORWARD+=("$1"); shift ;;
    esac
done

if [[ "$PRINT_MESSAGE" -eq 0 && "$PRINT_SESSION" -eq 0 && "$NO_NOTIFY" -eq 0 && "$CODEX_THREAD_ARG" == "auto" ]]; then
    CODEX_THREAD_ARG=""
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
        cd "$given" && pwd -P
        return 0
    fi
    if git rev-parse --show-toplevel >/dev/null 2>&1; then
        git rev-parse --show-toplevel
        return 0
    fi
    pwd -P
}

read_task_id() {
    local id
    id="$(forward_value --task-id)"
    if [[ -z "$id" && -f "$1/.agent/current/TASK.md" ]]; then
        id="$(awk '/^## Task ID[[:space:]]*$/{getline; gsub(/[[:space:]]/,""); print; exit}' "$1/.agent/current/TASK.md")"
    fi
    printf '%s' "${id:--}"
}

# --- Codex session identity -----------------------------------------------------
# Wake-up targets a session ONLY when it can be identified exactly:
#   1) --codex-thread <id-or-name> from the Supervisor, or
#   2) CODEX_THREAD_ID from the calling environment (when the runtime provides it).
# There is deliberately no guessing from local history: reading Codex's private
# DBs to infer "the most recent session" cannot prove who the caller is, and a
# wrong guess sends the wake-up to another conversation. When no identity is
# available the helper fails closed (exit 14) and the Supervisor uses blocking.
state_db_path() {
    ls -t "$CODEX_HOME_DIR"/state_*.sqlite 2>/dev/null | head -1
}

thread_row() {
    # thread_row <id> -> "title|cwd|updated"
    local state="$1" id="$2"
    [[ -n "$state" ]] || return 0
    sqlite3 -separator '|' "$state" \
        "SELECT COALESCE(title,''), COALESCE(cwd,''), COALESCE(datetime(updated_at,'unixepoch','localtime'),'') FROM threads WHERE id='$id' LIMIT 1;" \
        2>/dev/null || true
}

# resolve_thread_id -> prints the target id (exit 0) or returns 1
resolve_thread_id() {
    if [[ -n "$CODEX_THREAD_ARG" ]]; then
        printf '%s' "$CODEX_THREAD_ARG"
        return 0
    fi
    if [[ -n "${CODEX_THREAD_ID:-}" ]]; then
        printf '%s' "$CODEX_THREAD_ID"
        return 0
    fi
    return 1
}

# target_archived <id-or-name> -> 0 when the state DB says that thread is archived
target_archived() {
    local state id
    state="$(state_db_path)"
    [[ -n "$state" ]] || return 1
    id="$1"
    [[ -n "$id" ]] || return 1
    [[ "$(sqlite3 "$state" "SELECT archived FROM threads WHERE id='$id' OR title='$id' LIMIT 1;" 2>/dev/null || true)" == "1" ]]
}

ROOT="$(resolve_root)"
TASK_ID="$(read_task_id "$ROOT")"

if [[ "$PRINT_SESSION" -eq 1 ]]; then
    if TARGET_ID="$(resolve_thread_id)"; then
        STATE_DB="$(state_db_path)"
        ROW="$(thread_row "$STATE_DB" "$TARGET_ID")"
        printf '%s\t%s\n' "$TARGET_ID" "${ROW:-<no thread metadata>}"
        if target_archived "$TARGET_ID"; then
            printf 'target is ARCHIVED: reopen it in the app (or codex unarchive) before wake-up\n' >&2
            exit 3
        fi
        exit 0
    fi
    printf 'no target: pass --codex-thread <id-or-name> or set CODEX_THREAD_ID\n' >&2
    exit 1
fi

# --- wake-up message ----------------------------------------------------------
compose_message() {
    local rc="$1" id="$2" root="$3" msg
    case "$rc" in
        0)
            msg="[worker-notify] $id 完成。请验收：读 $root/.agent/current/RESULT.md + git diff + 必要测试 → ACCEPT（归档并发下一个 Task）或 REWORK（写 REVIEW.md 后重新投递）。"
            ;;
        5)
            msg="[worker-notify] $id 有 RESULT.md 但 opencode 非零退出（exit=5）。先检查 $root/.agent/current/RESULT.md、BASELINE.md 与 logs/，再决定接受、返工或重跑。"
            ;;
        4)
            msg="[worker-notify] $id 同时存在 RESULT.md 与 ESCALATION.md（exit=4）。需要你裁决：读两份报告后决定以哪一份为准。"
            ;;
        6)
            msg="[worker-notify] $id 的报告无效或过期（exit=6）。检查 $root/.agent/current/ 与 history/attempts/ 后再决定重跑或人工处理。"
            ;;
        7)
            msg="[worker-notify] $id 未启动：已有 worker 在运行（exit=7）。不要重复投递；先运行 check-state.sh 查看状态。"
            ;;
        10)
            msg="[worker-notify] $id 需要你决策（ESCALATION.md）。请读 $root/.agent/current/ESCALATION.md，处理后决定下一步。"
            ;;
        2|3)
            msg="[worker-notify] $id 失败（exit=${rc}，无报告）。请检查 $root/.agent/current/STATE.json 与 logs/，决定重试或升级。"
            ;;
        *)
            msg="[worker-notify] $id 结束（exit=${rc}，未预期状态）。请检查 $root/.agent/current/STATE.json 与 logs/ 后再决定。"
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

# --- resolve the target session (explicit id/name, else CODEX_THREAD_ID) -------
if [[ "$NO_NOTIFY" -eq 0 && -z "$CODEX_THREAD" ]]; then
    set +e
    CODEX_THREAD="$(resolve_thread_id)"
    R_RC=$?
    set -e
    if [[ "$R_RC" -ne 0 ]]; then
        printf 'worker-notify: ERROR no exact target session: pass --codex-thread <id-or-name> or set CODEX_THREAD_ID\n' >&2
        printf 'worker-notify: refusing to guess from local history; use run-worker.sh (blocking mode) instead\n' >&2
        exit 14
    fi
    if target_archived "$CODEX_THREAD"; then
        printf 'worker-notify: ERROR target session "%s" is archived; reopen it (or codex unarchive) first\n' "$CODEX_THREAD" >&2
        exit 14
    fi
    printf 'worker-notify: target session: %s\n' "$CODEX_THREAD"
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
    NOTIFY_FAILED=1
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

# No target means no wake-up: preserve the message and report it distinctly.
if [[ -z "$CODEX_THREAD" ]]; then
    notify_failed "$MESSAGE" "no Codex session target was resolved" \
        "pass --codex-thread <name or id>, or use run-worker.sh (blocking mode)"
    exit 15
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

if [[ "${NOTIFY_FAILED:-0}" -eq 1 ]]; then
    printf 'worker-notify: worker exit=%s but the wake-up was NOT delivered (exit 15); see NOTIFY_FAILED.md\n' "$worker_rc" >&2
    exit 15
fi
exit "$worker_rc"
