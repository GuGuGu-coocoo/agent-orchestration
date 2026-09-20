#!/usr/bin/env bash
# worker-notify.sh - run the worker (or a whole Phase loop) in the background,
# hold a no-sleep assertion while it runs, and wake the Codex Supervisor session
# when it stops.
#
# Why: Codex can hand off work and end its turn instead of blocking on a shell
# call. When the run stops, a short message is delivered to the same Codex session
# with `codex queue`, which starts a new turn there.
#
# Two handoff shapes:
#   (default) one Task   -> cheap-worker/run-worker.sh; wake on RESULT/ESCALATION
#   --phase              -> phase-runner/run-phase.sh; wake only when the whole
#                           Phase loop stops (phase review, checkpoint, escalation)
#
# Usage:
#   worker-notify.sh --codex-thread <id-or-name> [run-worker options...]
#   worker-notify.sh --phase --codex-thread <id-or-name> [run-phase options...]
#   worker-notify.sh [run-worker options...]   # uses CODEX_THREAD_ID if the runtime set it
#   worker-notify.sh --foreground [...]        # stay attached (debug)
#   worker-notify.sh --print-message --simulate-exit 5
#   worker-notify.sh --print-target            # show the resolved target, if any
#
# The wake-up target must be identified exactly: pass --codex-thread, or have the
# runtime provide CODEX_THREAD_ID. There is NO guessing from local history - a
# wrong guess would wake another conversation. Without a target the helper fails
# closed (exit 14) and the Supervisor uses the blocking script instead.
#
# Options (all other options are forwarded to the runner script):
#   --phase                run the Phase loop (run-phase.sh) instead of one Task
#   --codex-thread NAME    Codex session id or exact name (required unless
#                          CODEX_THREAD_ID is set by the calling runtime) or --no-notify
#   --no-notify            run the worker but do not wake Codex
#   --foreground           do not detach (default: detached; use for tests/debug)
#   --print-message        dry-run: print the wake-up message and exit
#   --print-target         print the resolved target session and exit
#   --simulate-exit N      exit code to use with --print-message (0|2|3|4|5|10|other)
#   --message-prefix STR   optional prefix for the wake-up message
#   --codex-bin PATH       codex CLI path (default: auto-detect)
#   -h|--help
#
# Environment: CODEX_THREAD_ID (exact calling session, when provided),
#              WORKER_NOTIFY_CODEX_HOME (default ~/.codex), CODEX_BIN,
#              WORKER_NOTIFY_RUN_WORKER (default: sibling run-worker.sh),
#              WORKER_NOTIFY_RUN_PHASE (default: sibling phase-runner/run-phase.sh)
#
# Exit codes: the runner's exit code (foreground mode);
#             0 when the background launch succeeded;
#             14 no exact target (refusing to guess);
#             15 the run finished but the wake-up could not be delivered.
#
# This script never commits, pushes, merges or deletes anything.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETACHED="${WORKER_NOTIFY_DETACHED:-0}"
PHASE_MODE=0

# The runner is chosen after argument parsing (--phase switches to run-phase.sh).
RUN_WORKER="${WORKER_NOTIFY_RUN_WORKER:-$SCRIPT_DIR/run-worker.sh}"

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

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; }

# --- argument parsing ---------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --codex-thread)   CODEX_THREAD_ARG="${2:-}"; shift 2 ;;
        --phase)          PHASE_MODE=1; shift ;;
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

if [[ "$PHASE_MODE" -eq 1 ]]; then
    if [[ -n "${WORKER_NOTIFY_RUN_PHASE:-}" ]]; then
        RUN_WORKER="$WORKER_NOTIFY_RUN_PHASE"
    elif [[ -x "$SCRIPT_DIR/../../phase-runner/scripts/run-phase.sh" ]]; then
        RUN_WORKER="$(cd "$SCRIPT_DIR/../../phase-runner/scripts" && pwd)/run-phase.sh"
    else
        RUN_WORKER="$HOME/.agents/skills/phase-runner/scripts/run-phase.sh"
    fi
fi
[[ -x "$RUN_WORKER" ]] || die "runner not found or not executable: $RUN_WORKER"

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
    if [[ "$PHASE_MODE" -eq 1 ]]; then
        if [[ -f "$1/.agent/RUN_STATE.json" ]] && command -v jq >/dev/null 2>&1; then
            id="$(jq -r '.current_phase // empty' "$1/.agent/RUN_STATE.json" 2>/dev/null || true)"
        fi
        printf '%s' "phase-${id:--}"
        return 0
    fi
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
# Phase mode: the loop only wakes Codex when it stops at a gate, never per Task.
compose_phase_message() {
    local rc="$1" label="$2" root="$3" msg
    case "$rc" in
        0)
            msg="[phase-notify] $label 全部 Task 完成，状态 awaiting_phase_review。请做 Phase 级 integration review：读 $root/.agent/phases/ 下的 PHASE_REVIEW.md、各 Task 的 RESULT.md/VERIFY.md 与 git diff → phase-gate.sh review-pass 或 review-fail。不要开始下一个 Phase。"
            ;;
        2)
            msg="[phase-notify] $label 停在 checkpoint，等你决策。读 $root/.agent/RUN_STATE.json（stop_reason）、$root/.agent/current/（ESCALATION.md/VERIFY.md）后处理，再重跑 run-phase.sh。"
            ;;
        3)
            msg="[phase-notify] $label 有 Task 进入 escalation。读 $root/.agent/current/ESCALATION.md 与 TASK_QUEUE.json history，处理后重跑 run-phase.sh。"
            ;;
        4)
            msg="[phase-notify] $label 未启动：处于 awaiting_phase_review 或 awaiting_human_qa。先 phase-gate.sh review-pass/review-fail，或等待人工 QA 结论。"
            ;;
        5)
            msg="[phase-notify] $label 因状态不一致或管道问题停下。检查 $root/.agent/current/ 与 check-state.sh，修好后重跑 run-phase.sh。"
            ;;
        *)
            msg="[phase-notify] $label 结束（exit=${rc}，未预期状态）。检查 $root/.agent/RUN_STATE.json 与 .agent/current/logs/。"
            ;;
    esac
    msg="${msg}（无需轮询：该 loop 下一次停下时会自动通知）"
    if [[ -n "$MESSAGE_PREFIX" ]]; then
        msg="$MESSAGE_PREFIX $msg"
    fi
    printf '%s' "$msg"
}

compose_message() {
    local rc="$1" id="$2" root="$3" msg
    if [[ "$PHASE_MODE" -eq 1 ]]; then
        compose_phase_message "$rc" "$id" "$root"
        return 0
    fi
    case "$rc" in
        0)
            msg="[worker-notify] $id 完成。读 $root/.agent/current/RESULT.md + VERIFY.md + git diff → 证据达标即继续（由 run-phase.sh 自动判定），否则处理。若这是整个 Phase，请改用 --phase 一次交接，不要逐 Task 唤醒。"
            ;;
        5)
            msg="[worker-notify] $id 有 RESULT.md 但 opencode 非零退出（exit=5）。先检查 $root/.agent/current/RESULT.md、VERIFY.md 与 BASELINE.md，再决定重跑或人工处理。"
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
            msg="[worker-notify] $id 需要你决策（ESCALATION.md，Class=CHECKPOINT 或 ESCALATE）。先读 $root/.agent/current/ESCALATION.md，再决定下一步。"
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
