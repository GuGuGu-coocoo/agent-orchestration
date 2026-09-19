#!/usr/bin/env bash
# phase-gate.sh - the two Phase-level gates, recorded as files (never implied).
#
# The Phase execution loop (run-phase.sh) never crosses these gates by itself:
#
#   awaiting_phase_review --(Codex review)--> awaiting_human_qa --(human)--> idle
#
#   review-pass --summary S   Codex phase-level integration review passed:
#                             re-runs the Phase verification for real, writes the
#                             PHASE.md ## Result, moves to awaiting_human_qa.
#                             It does NOT start the next Phase.
#   review-fail --reason R    the review found problems: reopens the queue so
#                             Codex can append corrective Tasks and continue.
#   qa-pass     --note N      the human confirmed the Phase: clears the gate.
#                             Planning the next Phase stays a deliberate action.
#   qa-fail     --note N      the human reported defects: reopens the queue.
#
# Usage:
#   phase-gate.sh review-pass --summary "..." [--root DIR]
#   phase-gate.sh review-fail --reason "..."  [--root DIR]
#   phase-gate.sh qa-pass --note "..."        [--root DIR]
#   phase-gate.sh qa-fail --note "..."        [--root DIR]
#
# Exit codes: 0 recorded, 1 invalid invocation or the gate refused (wrong state,
# unfinished Tasks, or a failing Phase verification).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die()  { printf 'phase-gate: %s\n' "$*" >&2; exit 1; }
log()  { printf 'phase-gate: %s\n' "$*"; }

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; }

resolve_root() {
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

jqv() {
    local file="$1" filter="$2" fallback="${3:-}"
    if [[ -f "$file" ]] && command -v jq >/dev/null 2>&1 && jq empty "$file" >/dev/null 2>&1; then
        local out
        out="$(jq -r "$filter" "$file" 2>/dev/null || true)"
        if [[ -n "$out" && "$out" != "null" ]]; then printf '%s' "$out"; return 0; fi
    fi
    printf '%s' "$fallback"
}

# state_patch <status|-> <stop_reason|-> <notes|-> [<extra-json-object>]
#
# Every value is passed to jq with --arg: note/summary/reason text is data, never
# filter source, so quotes, backslashes and newlines cannot break the transition.
# "-" leaves a field unchanged.
state_patch() {
    local status="$1" reason="$2" notes="$3" extra="${4:-}" tmp
    [[ -n "$extra" ]] || extra='{}'
    tmp="$(mktemp)"
    if jq --arg s "$status" --arg r "$reason" --arg n "$notes" --argjson x "$extra" \
        --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
        .updated_at = $now
        | (if $s == "-" then . else .status = $s end)
        | (if $r == "-" then . else .stop_reason = $r end)
        | (if $n == "-" then . else .notes = $n end)
        | . + $x
      ' "$RUN_STATE" >"$tmp"; then
        mv "$tmp" "$RUN_STATE"
    else
        rm -f "$tmp"
        die "cannot update $RUN_STATE"
    fi
}

first_line() {  # first_line <text> [max-chars]
    printf '%s' "$1" | head -1 | cut -c1-"${2:-200}"
}

json_obj() {  # json_obj <jq-args...> - build an object safely from --arg values
    jq -nc "$@"
}

append_adjustment() {  # append_adjustment <change> <reason>
    local change="$1" reason="$2" tmp c r
    c="$(jq -Rn --arg v "$change" '$v')"
    r="$(jq -Rn --arg v "$reason" '$v')"
    tmp="$(mktemp)"
    if jq --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        ".adjustments = ((.adjustments // []) + [{at: \$now, change: $c, reason: $r}]) | .updated_at = \$now" \
        "$QUEUE" >"$tmp"; then
        mv "$tmp" "$QUEUE"
    else
        rm -f "$tmp"
        die "cannot update $QUEUE"
    fi
}

run_check() {  # run_check <cmd> <expect> ; CHECK_RC / CHECK_OUTPUT
    local cmd="$1" expect="$2"
    CHECK_RC=0
    CHECK_OUTPUT="$(cd "$ROOT" && bash -c "$cmd" 2>&1)" || CHECK_RC=$?
    case "$expect" in
        ""|"exit 0") [[ "$CHECK_RC" -eq 0 ]] ;;
        exit\ *)     [[ "$CHECK_RC" -eq "${expect#exit }" ]] ;;
        contains:*)  [[ "$CHECK_RC" -eq 0 ]] && printf '%s' "$CHECK_OUTPUT" | grep -qF -- "${expect#contains:}" ;;
        *)           return 1 ;;
    esac
}

require_state() {  # require_state <expected> <hint>
    local expected="$1" hint="$2" actual
    actual="$(jqv "$RUN_STATE" '.status')"
    if [[ "$actual" != "$expected" ]]; then
        die "RUN_STATE.status is '${actual:-<empty>}' but '$expected' is required: $hint"
    fi
}

require_phase_context() {
    PHASE="$(jqv "$RUN_STATE" '.current_phase')"
    [[ -n "$PHASE" ]] || die "RUN_STATE has no current_phase"
    PHASE_DIR="$ROOT/.agent/phases/$PHASE"
    QUEUE="$PHASE_DIR/TASK_QUEUE.json"
    [[ -f "$QUEUE" ]] || die "no $QUEUE"
}

# --- review-pass -----------------------------------------------------------------
do_review_pass() {
    local summary="$1"
    [[ -n "$summary" ]] || die "review-pass needs --summary \"what the review verified\""
    case "$summary" in '<'*) die "review-pass --summary still looks like a template placeholder" ;; esac
    require_state "awaiting_phase_review" "only a Phase that finished its Tasks can be reviewed"
    require_phase_context

    local unfinished
    unfinished="$(jq -r '[.tasks[] | select(.status != "done" and .status != "dropped") | "\(.id)=\(.status)"] | join(", ")' "$QUEUE")"
    [[ -z "$unfinished" ]] || die "Tasks are not finished: $unfinished"

    local review_file="$PHASE_DIR/PHASE_REVIEW.md"
    [[ -f "$review_file" ]] || die "no $review_file (run-phase.sh must have written the Phase verification evidence)"

    # Re-run the Phase verification for real: a review that only flips a status is
    # not a review.
    log "re-running the Phase verification for phase $PHASE"
    local total pv_rc=0 output="" n=0
    total="$(jq -r '(.phase_verification // []) | length' "$QUEUE")"
    local i=0 cmd expect
    while [[ "$i" -lt "$total" ]]; do
        cmd="$(jq -r --argjson i "$i" '(.phase_verification // [])[$i].cmd' "$QUEUE")"
        expect="$(jq -r --argjson i "$i" '(.phase_verification // [])[$i].expect // "exit 0"' "$QUEUE")"
        n=$((n + 1))
        if run_check "$cmd" "$expect"; then
            output="${output}
### review verification $n: \`$cmd\` (expect: $expect) -> exit 0
\`\`\`
$(printf '%s' "$CHECK_OUTPUT" | tail -40)
\`\`\`
"
        else
            pv_rc=1
            output="${output}
### review verification $n: \`$cmd\` (expect: $expect) -> FAILED (exit $CHECK_RC)
\`\`\`
$(printf '%s' "$CHECK_OUTPUT" | tail -40)
\`\`\`
"
        fi
        i=$((i + 1))
    done

    {
        printf '\n## Phase review run (phase-gate.sh review-pass)\n\n'
        printf -- '- at: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf -- '- summary: %s\n' "$summary"
        printf '%s\n' "$output"
        if [[ "$pv_rc" -eq 0 ]]; then
            printf '### Review result: PASS\n'
        else
            printf '### Review result: FAIL (the Phase verification no longer passes)\n'
        fi
    } >>"$review_file"

    if [[ "$pv_rc" -ne 0 ]]; then
        die "the Phase verification failed during the review; the Phase is NOT accepted (see $review_file)"
    fi

    # PHASE.md ## Result: drop any existing Result section (wherever it sits) and
    # append the reviewed one, so nothing else in the file is lost.
    local tasks_line tmp
    tasks_line="$(jq -r '[.tasks[] | "\(.id) (\(.history | map(select(.decision=="ACCEPT")) | length)xACCEPT)"] | join(", ")' "$QUEUE")"
    tmp="$(mktemp)"
    awk '
        /^## Result[[:space:]]*$/ { skip = 1; next }
        skip && /^## / { skip = 0 }
        !skip { print }
    ' "$PHASE_DIR/PHASE.md" >"$tmp"
    {
        printf '## Result\n\n'
        printf -- '- Reviewed by: Codex phase review (recorded %s)\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf -- '- Tasks completed: %s\n' "$tasks_line"
        printf -- '- Phase verification: re-run and PASSED (see history/PHASE_REVIEW.md)\n'
        printf -- '- Review summary: %s\n' "$summary"
    } >>"$tmp"
    mv "$tmp" "$PHASE_DIR/PHASE.md"

    local note
    note="$(first_line "$summary")"
    state_patch "awaiting_human_qa" "" "phase review passed: $note" \
        "$(json_obj --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '{phase_review: "passed", phase_reviewed_at: $at}')"
    log "phase $PHASE accepted by the review; state=awaiting_human_qa"
    log "STOP for human QA: nothing starts automatically. Tell the human what to test (PHASE.md '## Human QA Required')."
    log "After the human confirms: phase-gate.sh qa-pass --note \"...\""
    log "If the human reports defects:  phase-gate.sh qa-fail --note \"...\" then add corrective Tasks and run run-phase.sh"
    exit 0
}

# --- review-fail -----------------------------------------------------------------
do_review_fail() {
    local reason="$1"
    [[ -n "$reason" ]] || die "review-fail needs --reason \"what is missing\""
    require_state "awaiting_phase_review" "only a Phase waiting for review can be sent back"
    require_phase_context
    append_adjustment "phase review failed; corrective Tasks required" "$reason"
    state_patch "running" "phase_review_failed" "review-fail: $(first_line "$reason")"
    log "phase $PHASE reopened (queue status running)"
    log "next: append the corrective Tasks to $QUEUE, then run run-phase.sh"
    exit 0
}

# --- qa-pass ---------------------------------------------------------------------
do_qa_pass() {
    local note="$1"
    [[ -n "$note" ]] || die "qa-pass needs --note \"how the human confirmed it\""
    require_state "awaiting_human_qa" "only a Phase awaiting human QA can be confirmed"
    state_patch "idle" "" "human QA passed: $(first_line "$note")" \
        "$(json_obj --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '{human_qa: "passed", human_qa_at: $at}')"
    log "human QA recorded as passed for phase $(jqv "$RUN_STATE" '.current_phase')"
    log "The next Phase is a deliberate new decision: plan it (PHASE.md + TASK_QUEUE.json), then run run-phase.sh."
    exit 0
}

# --- qa-fail ---------------------------------------------------------------------
do_qa_fail() {
    local note="$1"
    [[ -n "$note" ]] || die "qa-fail needs --note \"what the human reported\""
    require_state "awaiting_human_qa" "only a Phase awaiting human QA can be sent back"
    require_phase_context
    append_adjustment "human QA reported defects" "$note"
    state_patch "running" "human_qa_failed" "human QA defects: $(first_line "$note")" \
        "$(json_obj '{human_qa: "failed"}')"
    log "phase $PHASE reopened after human QA"
    log "next: convert each reported defect into a Task in $QUEUE, then run run-phase.sh"
    exit 0
}

# ---------------------------------------------------------------------------------
main() {
    local verb="${1:-}"
    [[ $# -gt 0 ]] && shift
    local summary="" reason="" note="" root_arg=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --summary) summary="${2:-}"; shift 2 ;;
            --reason)  reason="${2:-}"; shift 2 ;;
            --note)    note="${2:-}"; shift 2 ;;
            --root)    root_arg="${2:-}"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *)         die "unknown argument '$1' (try --help)" ;;
        esac
    done

    case "$verb" in
        ""|-h|--help) usage; exit 0 ;;
        review-pass|review-fail|qa-pass|qa-fail) : ;;
        *)            die "unknown verb '$verb' (expected review-pass|review-fail|qa-pass|qa-fail)" ;;
    esac

    command -v jq >/dev/null 2>&1 || die "jq is required"
    ROOT="$(resolve_root "$root_arg")"
    RUN_STATE="$ROOT/.agent/RUN_STATE.json"
    [[ -f "$RUN_STATE" ]] || die "no $RUN_STATE"

    case "$verb" in
        review-pass) do_review_pass "$summary" ;;
        review-fail) do_review_fail "$reason" ;;
        qa-pass)     do_qa_pass "$note" ;;
        qa-fail)     do_qa_fail "$note" ;;
    esac
}

main "$@"
