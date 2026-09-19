#!/usr/bin/env bash
# run-phase.sh - execute one Phase's bounded Tasks, one OpenCode session per Task.
#
# This loop replaces the old "Codex reviews every Task" step with a deterministic
# evidence gate. It never plans, never re-scopes and never starts another Phase.
#
#   for each pending Task of the Phase (in queue order):
#     1. render .agent/current/TASK.md from the queue definition
#     2. run exactly one OpenCode worker session (cheap-worker/run-worker.sh)
#     3. decide with the deterministic evidence gate (no LLM, no Codex):
#          - RESULT.md is fresh, belongs to this Task, Status DONE,
#            every Acceptance Criterion ticked
#          - every Required Verification command from the queue re-runs green
#          - changed files are inside Allowed Changes, none Forbidden
#          - the Supervisor artifacts (queue/RUN_STATE/PHASE.md/TASK.md) unchanged
#        PASS -> archive + mark done -> continue with the next Task automatically
#        STOP -> checkpoint or escalate; the loop ends and Codex decides
#   when no Task is left:
#     run the Phase verification, then STOP at awaiting_phase_review
#     (Codex phase review first; never the next Phase, never human QA directly)
#
# Worker exit codes (see cheap-worker/scripts/run-worker.sh) are classified as:
#   0        evidence gate                              (continue on PASS)
#   5        valid RESULT but opencode failed           checkpoint
#   10       ESCALATION.md: Class CHECKPOINT -> checkpoint, Class ESCALATE -> escalate
#   1        precondition / invalid Task / state         checkpoint
#   2,3,4,6  no or inconsistent report (plumbing)        inconsistent stop
#   7,8      another worker / unproven stale lock        inconsistent stop
#
# Usage:
#   run-phase.sh [--root DIR] [--max-tasks N] [--dry-run] [--break-lock]
#                [--no-check-state]
#
# Exit codes:
#   0  the Phase reached awaiting_phase_review (STOP: Codex phase review)
#   1  invalid invocation, invalid plan, or a state gate refused the run
#   2  stopped at a checkpoint (Codex decision needed)
#   3  stopped at an escalation (blocked; Codex decision needed)
#   4  refused: the Phase is already at a gate (phase review or human QA pending)
#   5  stopped at an inconsistent/plumbing state (no or conflicting report, lock)
#
# This script never commits, pushes, merges or deletes anything.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PHASE_LOCK_OWNED=0
RUN_ID=""
ROOT=""
RUN_STATE=""
QUEUE=""
PHASE=""
PHASE_DIR=""
CURRENT=""
STOP_TASK=""
GATE_FAILURES=""
GATE_NOTES=""
plan_error=""

die()  { printf 'run-phase: %s\n' "$*" >&2; exit 1; }
log()  { printf 'run-phase: %s\n' "$*"; }
warn() { printf 'run-phase: %s\n' "$*" >&2; }

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; }

# ---------------------------------------------------------------------------
# Locations
# ---------------------------------------------------------------------------

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

# locate_run <script> <installed-fallback> <env-override> - sibling skill first
# (source tree), then the global install.
locate_run() {
    local rel="$1" fallback="$2" from_env="$3"
    if [[ -n "$from_env" ]]; then
        [[ -x "$from_env" ]] || die "the environment override points at a non-executable file: $from_env"
        printf '%s\n' "$from_env"
        return 0
    fi
    if [[ -x "$SCRIPT_DIR/../../cheap-worker/scripts/$rel" ]]; then
        printf '%s\n' "$(cd "$SCRIPT_DIR/../../cheap-worker/scripts" && pwd)/$rel"
        return 0
    fi
    if [[ -x "$fallback" ]]; then
        printf '%s\n' "$fallback"
        return 0
    fi
    die "cannot locate $rel (install the skills, or point the environment override at it)"
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

hash_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    else
        printf 'no-hash-tool'
    fi
}

file_mtime() {
    stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || printf '0'
}

# ---------------------------------------------------------------------------
# Queue helpers (temp file + rename: an interrupted write never truncates state)
# ---------------------------------------------------------------------------

queue_update_task() {  # queue_update_task <id> <jq-expr>
    local id="$1" expr="$2" tmp
    tmp="$(mktemp)"
    if jq --arg id "$id" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        "(.tasks[] | select(.id == \$id)) |= ($expr) | .updated_at = \$now" "$QUEUE" >"$tmp"; then
        mv "$tmp" "$QUEUE"
    else
        rm -f "$tmp"
        die "cannot update $QUEUE"
    fi
}

queue_task_field() {  # queue_task_field <id> <jq-filter>
    jq -r --arg id "$1" ".tasks[] | select(.id == \$id) | $2" "$QUEUE"
}

queue_task_status() { queue_task_field "$1" '.status'; }

queue_append_history() {  # queue_append_history <id> <decision> <note>
    local id="$1" decision="$2" note="$3" d n
    d="$(jq -Rn --arg v "$decision" '$v')"
    n="$(jq -Rn --arg v "$note" '$v')"
    queue_update_task "$id" \
        ".history += [{at: \$now, decision: $d, note: $n, by: \"run-phase.sh\"}]"
}

queue_set_status() {  # queue_set_status <ready|running|done> [<jq-extra>]
    local status="$1" extra="${2:-}" tmp
    tmp="$(mktemp)"
    if jq --arg s "$status" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        ".status = \$s | .updated_at = \$now $extra" "$QUEUE" >"$tmp"; then
        mv "$tmp" "$QUEUE"
    else
        rm -f "$tmp"
        die "cannot update $QUEUE"
    fi
}

next_task_id() {
    local id
    id="$(jq -r '[.tasks[] | select(.status == "in_progress")][0].id // empty' "$QUEUE")"
    if [[ -z "$id" ]]; then
        id="$(jq -r '[.tasks[] | select(.status == "pending")][0].id // empty' "$QUEUE")"
    fi
    printf '%s' "$id"
}

# ---------------------------------------------------------------------------
# RUN_STATE / lock
# ---------------------------------------------------------------------------

read_run_state() { jqv "$RUN_STATE" '.status' ''; }

update_run_state() {  # update_run_state <status> <task> <stop_reason> <notes>
    local status="$1" task="$2" reason="$3" notes="$4" tmp
    tmp="$(mktemp)"
    if jq --arg s "$status" --arg t "$task" --arg r "$reason" --arg n "$notes" \
        --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        '.status = $s | .current_task = $t | .stop_reason = $r | .notes = $n | .updated_at = $now' \
        "$RUN_STATE" >"$tmp"; then
        mv "$tmp" "$RUN_STATE"
    else
        rm -f "$tmp"
        die "cannot update $RUN_STATE"
    fi
}

PHASE_LOCK_DIR_NAME=".phase.lock"

acquire_phase_lock() {
    local break_lock="$1" lock="$ROOT/.agent/current/$PHASE_LOCK_DIR_NAME" lpid="" info=""
    if mkdir "$lock" 2>/dev/null; then
        printf 'pid=%s\nrun_id=%s\nphase=%s\nstarted_at=%s\n' \
            "$$" "$RUN_ID" "$PHASE" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$lock/info"
        PHASE_LOCK_OWNED=1
        return 0
    fi
    if [[ -f "$lock/info" ]]; then
        info="$(tr '\n' ' ' <"$lock/info")"
        lpid="$(awk -F= '/^pid=/{print $2}' "$lock/info" | head -1)"
    fi
    if [[ -n "$lpid" ]] && kill -0 "$lpid" 2>/dev/null; then
        warn "another phase loop is running for this project (pid $lpid; $info)"
        exit 5
    fi
    if [[ "$break_lock" -ne 1 ]]; then
        warn "stale phase lock, and the previous loop cannot be proven dead: ${info:-<no lock info>}"
        warn "verify nothing is running, then re-run with --break-lock"
        exit 5
    fi
    warn "--break-lock given; moving the stale phase lock aside"
    local stale="$ROOT/.agent/history/attempts/stale-locks/phase-$(date -u '+%Y%m%dT%H%M%SZ')-${lpid:-unknown}"
    mkdir -p "$stale" && mv "$lock" "$stale/" || die "cannot move the stale phase lock"
    mkdir "$lock" 2>/dev/null || { warn "another phase loop is already running"; exit 5; }
    printf 'pid=%s\nrun_id=%s\nphase=%s\nstarted_at=%s\n' \
        "$$" "$RUN_ID" "$PHASE" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$lock/info"
    PHASE_LOCK_OWNED=1
}

release_phase_lock() {
    local lock="$ROOT/.agent/current/$PHASE_LOCK_DIR_NAME"
    [[ "$PHASE_LOCK_OWNED" -eq 1 ]] || return 0
    if [[ -f "$lock/info" ]] && grep -q "^pid=$$$" "$lock/info" 2>/dev/null; then
        rm -rf "$lock" 2>/dev/null || true
    fi
    PHASE_LOCK_OWNED=0
    return 0
}

# ---------------------------------------------------------------------------
# Plan validation: a Task that cannot be verified objectively is not runnable
# ---------------------------------------------------------------------------

validate_plan() {
    if ! jq -e 'type == "object" and ((.tasks | type) == "array")' "$QUEUE" >/dev/null 2>&1; then
        plan_error="queue is not a JSON object with a tasks array"
        return 1
    fi
    if [[ "$(jq -r '.tasks | length' "$QUEUE")" -eq 0 ]]; then
        plan_error="queue has no Tasks"
        return 1
    fi
    if [[ "$(jq -r '[(.phase_verification // [])[] | select((.cmd // "") != "")] | length' "$QUEUE")" -eq 0 ]]; then
        plan_error="queue has no phase_verification command; the Phase cannot be verified objectively"
        return 1
    fi
    local bad
    bad="$(jq -r '
        [ .tasks[] | . as $t | select(
            (($t.id | type) != "string")
            or (($t.id | length) == 0)
            or (($t.id | tostring | gsub("[A-Za-z0-9._-]"; "")) != "")
            or ((["pending","in_progress","done","escalated","dropped"] | index($t.status)) == null)
            or ((["implement","investigate","fix","verify"] | index($t.mode)) == null)
            or ((["low","guarded"] | index($t.risk // "low")) == null)
            or (((($t.verification // []) | map(select((.cmd // "") != ""))) | length) == 0)
            or ((($t.acceptance_criteria // []) | length) == 0)
            or ((($t.allowed_changes // []) | type) != "array")
            or ((($t.title // "") | length) == 0)
            or ((($t.objective // "") | length) == 0)
            or ((($t.desired_behavior // "") | length) == 0)
        ) | ($t.id // "?") ] | join(",")' "$QUEUE" 2>/dev/null || true)"
    if [[ -n "$bad" ]]; then
        plan_error="Task(s) '$bad' are not executable/verifiable: every Task needs a safe id, title, status, mode, risk (low|guarded), objective, desired_behavior, acceptance_criteria, allowed_changes and at least one verification command"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# TASK.md rendering (the worker only ever sees .agent/current/TASK.md)
# ---------------------------------------------------------------------------

render_task_md() {
    local id="$1" target="$2" tmp="$2.tmp"
    if jq -r --arg id "$id" '
        def bullets($a): ($a // []) | map("- " + .) | join("\n");
        (.tasks[] | select(.id == $id)) as $t
        | "# Task\n\n"
        + "## Task ID\n" + $t.id + "\n\n"
        + "## Mode\n" + $t.mode + "\n\n"
        + "## Risk\n" + ($t.risk // "low") + "\n\n"
        + "## Objective\n" + (($t.objective // "") | if . == "" then $t.title else . end) + "\n\n"
        + "## Context\n" + (($t.context // "") | if . == "" then "See the Objective." else . end) + "\n\n"
        + "## Existing Behavior\n" + (($t.existing_behavior // "") | if . == "" then "See the Objective and Context." else . end) + "\n\n"
        + "## Desired Behavior\n" + (($t.desired_behavior // "") | if . == "" then ($t.objective // $t.title) else . end) + "\n\n"
        + "## Relevant Files\n" + bullets($t.relevant_files) + "\n\n"
        + "## Allowed Changes\n" + bullets($t.allowed_changes) + "\n\n"
        + "## Forbidden Changes\n" + bullets(($t.forbidden_changes // []) + ["any file outside Allowed Changes", "the .agent/ state written by the Supervisor"]) + "\n\n"
        + "## Acceptance Criteria\n" + (($t.acceptance_criteria // []) | map("- [ ] " + .) | join("\n")) + "\n\n"
        + "## Required Verification\n" + (($t.verification // []) | map("- `" + .cmd + "`" + (if (.expect // "exit 0") == "exit 0" then "" else " (expect: " + .expect + ")" end)) | join("\n")) + "\n\n"
        + "## Escalation Conditions\n" + bullets(($t.escalation_conditions // ["the change needs a decision the Task does not authorize", "two genuinely different attempts failed", "the change would need architecture, public API, schema, security or deployment changes"])) + "\n"
    ' "$QUEUE" >"$tmp"; then
        mv "$tmp" "$target"
    else
        rm -f "$tmp"
        die "cannot render $target from $QUEUE"
    fi
}

# quarantine_stale_reports <keep-task-id> - move a report left over from another
# Task aside, exactly like run-worker.sh does before a run, so the resume
# diagnostics see a coherent current/ directory.
quarantine_stale_reports() {
    local keep="$1" f t dest stamp
    [[ -d "$CURRENT" ]] || return 0
    stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
    for f in RESULT.md ESCALATION.md VERIFY.md REVIEW.md; do
        [[ -s "$CURRENT/$f" ]] || continue
        t="$(awk '/^## Task ID[[:space:]]*$/{getline; gsub(/[[:space:]]/,""); print; exit}' "$CURRENT/$f")"
        [[ -z "$t" || "$t" == "$keep" ]] && continue
        dest="$ROOT/.agent/history/attempts/$t/${stamp}-phase"
        mkdir -p "$dest" && mv "$CURRENT/$f" "$dest/$f"
        log "quarantined stale $f (Task $t) -> ${dest#"$ROOT"/}"
    done
}

# ---------------------------------------------------------------------------
# Evidence gate
# ---------------------------------------------------------------------------

git_paths() {  # changed paths, .agent/ excluded, sorted
    git -C "$ROOT" status --porcelain=v1 -uall 2>/dev/null | while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        local p="${line:3}"
        case "$line" in *" -> "*) p="${p##* -> }" ;; esac
        case "$p" in
            \"*\") p="${p#\"}"; p="${p%\"}" ;;
        esac
        case "$p" in .agent/*|.git/*) continue ;; esac
        [[ -n "$p" ]] && printf '%s\n' "$p"
    done | LC_ALL=C sort -u
}

snapshot_hashes() {  # Supervisor artifacts the worker must never edit
    local f
    for f in "$RUN_STATE" "$QUEUE" "$PHASE_DIR/PHASE.md" "$CURRENT/TASK.md"; do
        [[ -f "$f" ]] && printf '%s %s\n' "$(hash_file "$f")" "${f#"$ROOT"/}"
    done
    return 0
}

junk_path() {  # tool artifacts that carry no behavior
    case "$1" in
        */__pycache__/*|__pycache__/*|*.pyc) return 0 ;;
        */.pytest_cache/*|.pytest_cache/*|*/.mypy_cache/*|.mypy_cache/*) return 0 ;;
        */.ruff_cache/*|.ruff_cache/*|*/.cache/*|.cache/*) return 0 ;;
        */node_modules/*|node_modules/*|*/.venv/*|.venv/*|*/venv/*|venv/*) return 0 ;;
        *.DS_Store|.DS_Store|*.log|*.tmp) return 0 ;;
    esac
    return 1
}

path_matches() {  # path_matches <path> <pattern...>
    local p="$1"; shift
    local pat
    for pat in "$@"; do
        [[ -z "$pat" ]] && continue
        # shellcheck disable=SC2254
        case "$p" in
            $pat) return 0 ;;
            "$pat"/*) return 0 ;;
        esac
    done
    return 1
}

gate_fail() {
    if [[ -n "$GATE_FAILURES" ]]; then
        GATE_FAILURES="$GATE_FAILURES
- $1"
    else
        GATE_FAILURES="- $1"
    fi
}

gate_note() {
    if [[ -n "$GATE_NOTES" ]]; then
        GATE_NOTES="$GATE_NOTES
- $1"
    else
        GATE_NOTES="- $1"
    fi
}

# run_check <cmd> <expect> -> 0/1; combined output in CHECK_OUTPUT, exit in CHECK_RC
run_check() {
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

# gate_task <id> <run-started-epoch> <before-paths> <before-hashes> <worker-rc>
gate_task() {
    local id="$1" started="$2" before_paths="$3" before_hashes="$4" worker_rc="$5"
    GATE_FAILURES=""
    GATE_NOTES=""
    local result="$CURRENT/RESULT.md"
    local mode risk
    mode="$(queue_task_field "$id" '.mode')"
    risk="$(queue_task_field "$id" '.risk // "low"')"

    # --- the worker's own report -----------------------------------------------------
    if [[ ! -s "$result" ]]; then
        gate_fail "RESULT.md is missing or empty"
    else
        local mtime rid rstatus
        mtime="$(file_mtime "$result")"
        rid="$(awk '/^## Task ID[[:space:]]*$/{getline; gsub(/[[:space:]]/,""); print; exit}' "$result")"
        rstatus="$(awk '/^## Status[[:space:]]*$/{getline; gsub(/^[[:space:]]+|[[:space:]]+$/,""); print; exit}' "$result")"
        if [[ "$mtime" =~ ^[0-9]+$ ]] && [[ "$mtime" -lt $((started - 1)) ]]; then
            gate_fail "RESULT.md is stale (written before this run)"
        fi
        [[ "$rid" == "$id" ]] || gate_fail "RESULT.md belongs to Task '$rid', not '$id'"
        [[ "$rstatus" == "DONE" ]] || gate_fail "RESULT.md Status is '${rstatus:-<none>}', not DONE"
        if grep -q '^- \[ \]' "$result"; then
            gate_fail "RESULT.md still has unticked Acceptance Criteria (- [ ])"
        fi
        if ! awk '/^## Verification Performed[[:space:]]*$/{f=1;next} /^## /{f=0} f&&NF{print;exit}' "$result" | grep -q .; then
            gate_fail "RESULT.md has no '## Verification Performed' evidence"
        fi
    fi

    # --- re-run the Task's Required Verification (independent of the report) ----------
    local total n=0 verify_output=""
    total="$(jq -r --arg id "$id" '[.tasks[] | select(.id==$id) | (.verification // [])[]] | length' "$QUEUE")"
    local i=0 cmd expect
    while [[ "$i" -lt "$total" ]]; do
        cmd="$(jq -r --arg id "$id" --argjson i "$i" '.tasks[] | select(.id==$id) | (.verification // [])[$i] | .cmd' "$QUEUE")"
        expect="$(jq -r --arg id "$id" --argjson i "$i" '.tasks[] | select(.id==$id) | (.verification // [])[$i] | .expect // "exit 0"' "$QUEUE")"
        n=$((n + 1))
        if run_check "$cmd" "$expect"; then
            gate_note "verification $n/$total: \`$cmd\` (expect: $expect) -> exit $CHECK_RC"
        else
            gate_fail "verification $n/$total FAILED: \`$cmd\` (expect: $expect) -> exit $CHECK_RC"
        fi
        verify_output="${verify_output}
### verification $n: \`$cmd\` (expect: $expect)
\`\`\`
$(printf '%s' "$CHECK_OUTPUT" | tail -30)
\`\`\`
"
        i=$((i + 1))
    done

    # --- scope gate ---------------------------------------------------------------------
    local after_paths changed
    after_paths="$(mktemp)"
    git_paths >"$after_paths"
    changed="$(comm -13 "$before_paths" "$after_paths" 2>/dev/null | grep -v '^$' || true)"
    rm -f "$after_paths"

    local allowed=() forbidden=()
    while IFS= read -r line; do [[ -n "$line" ]] && allowed+=("$line"); done \
        < <(jq -r --arg id "$id" '.tasks[] | select(.id==$id) | (.allowed_changes // [])[]' "$QUEUE")
    while IFS= read -r line; do [[ -n "$line" ]] && forbidden+=("$line"); done \
        < <(jq -r --arg id "$id" '.tasks[] | select(.id==$id) | (.forbidden_changes // [])[]' "$QUEUE")

    local changed_list="" p
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        changed_list="${changed_list}${changed_list:+, }$p"
        if junk_path "$p"; then
            gate_note "ignored tool artifact: $p"
        elif (( ${#forbidden[@]} > 0 )) && path_matches "$p" "${forbidden[@]}"; then
            gate_fail "changed file '$p' is on the Forbidden Changes list"
        elif (( ${#allowed[@]} == 0 )); then
            gate_fail "changed file '$p' but Allowed Changes is empty (mode=$mode)"
        elif ! path_matches "$p" "${allowed[@]}"; then
            gate_fail "changed file '$p' is outside Allowed Changes"
        fi
    done <<<"$changed"
    [[ -n "$changed_list" ]] || changed_list="(none)"

    # --- the worker must not touch Supervisor artifacts ----------------------------------
    local after_hashes line
    after_hashes="$(mktemp)"
    snapshot_hashes >"$after_hashes"
    if ! diff -q "$before_hashes" "$after_hashes" >/dev/null 2>&1; then
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            grep -qF "$line" "$before_hashes" || gate_fail "the worker modified a Supervisor artifact ($line)"
        done <"$after_hashes"
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            grep -qF "$line" "$after_hashes" || gate_fail "a Supervisor artifact was removed during the run ($line)"
        done <"$before_hashes"
    fi
    rm -f "$after_hashes"

    if [[ "$worker_rc" -ne 0 ]]; then
        gate_fail "opencode exited $worker_rc for this run (never auto-accepted)"
    fi

    # --- evidence artifact -----------------------------------------------------------------
    local verdict="PASS"
    [[ -n "$GATE_FAILURES" ]] && verdict="FAIL"
    {
        printf '# Task verification (evidence gate)\n\n'
        printf -- '- Task ID: %s\n' "$id"
        printf -- '- Mode / risk: %s / %s\n' "$mode" "$risk"
        printf -- '- Checked at: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf -- '- Checked by: run-phase.sh (deterministic, no LLM)\n'
        printf -- '- Worker exit code: %s\n\n' "$worker_rc"
        printf '## Checks\n\n'
        if [[ -n "$GATE_NOTES" ]]; then printf '%s\n' "$GATE_NOTES"; fi
        printf -- '- changed files: %s\n' "$changed_list"
        printf -- '- result: %s\n\n' "$verdict"
        printf '## Verification output\n%s\n' "$verify_output"
        printf '## Changed files\n\n'
        printf '%s\n' "$changed_list" | tr ',' '\n' | sed 's/^ *//; s/^/- /'
        printf '\n## Result\n\n'
        if [[ "$verdict" == "PASS" ]]; then
            printf 'PASS - every check passed; the Task is auto-accepted.\n'
        else
            printf 'FAIL\n\n%s\n' "$GATE_FAILURES"
        fi
    } >"$CURRENT/VERIFY.md"

    [[ "$verdict" == "PASS" ]]
}

# ---------------------------------------------------------------------------
# Stops
# ---------------------------------------------------------------------------

stop_phase() {  # stop_phase <exit-code> <run-state-status> <reason> <message>
    local code="$1" status="$2" reason="$3" message="$4"
    update_run_state "$status" "${STOP_TASK:-}" "$reason" "$message"
    printf '\nrun-phase: STOP (%s): %s\n' "$reason" "$message" >&2
    printf 'run-phase: state=%s; read .agent/RUN_STATE.json, .agent/current/ and .agent/phases/%s/history/\n' \
        "$status" "$PHASE" >&2
    release_phase_lock
    exit "$code"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    local root_arg="" max_tasks=0 dry_run=0 break_lock=0 skip_check_state=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --root)           root_arg="${2:-}"; shift 2 ;;
            --max-tasks)      max_tasks="${2:-0}"; shift 2 ;;
            --dry-run)        dry_run=1; shift ;;
            --break-lock)     break_lock=1; shift ;;
            --no-check-state) skip_check_state=1; shift ;;
            -h|--help)        usage; exit 0 ;;
            *)                die "unknown argument '$1' (try --help)" ;;
        esac
    done
    [[ "$max_tasks" =~ ^[0-9]+$ ]] || die "--max-tasks must be a number"

    command -v jq >/dev/null 2>&1 || die "jq is required"
    ROOT="$(resolve_root "$root_arg")"
    RUN_STATE="$ROOT/.agent/RUN_STATE.json"
    CURRENT="$ROOT/.agent/current"
    local worker_override="${RUN_PHASE_WORKER:-}"
    local archiver_override="${RUN_PHASE_ARCHIVER:-}"
    local check_state_override="${RUN_PHASE_CHECK_STATE:-}"
    local WORKER ARCHIVER CHECK_STATE
    WORKER="$(locate_run run-worker.sh "$HOME/.agents/skills/cheap-worker/scripts/run-worker.sh" "$worker_override")"
    ARCHIVER="$(locate_run archive-task.sh "$HOME/.agents/skills/cheap-worker/scripts/archive-task.sh" "$archiver_override")"
    CHECK_STATE=""
    if [[ "$skip_check_state" -eq 0 ]]; then
        CHECK_STATE="$(locate_run check-state.sh "$HOME/.agents/skills/cheap-worker/scripts/check-state.sh" "$check_state_override")"
    fi

    [[ -f "$RUN_STATE" ]] || die "no $RUN_STATE (plan the Phase first)"

    local state_status
    state_status="$(read_run_state)"
    case "$state_status" in
        idle|running|checkpoint|escalated) : ;;
        awaiting_phase_review)
            warn "the Phase is at awaiting_phase_review: the Codex phase review comes first"
            warn "  phase-gate.sh review-pass --summary \"...\"   (accept the Phase)"
            warn "  phase-gate.sh review-fail --reason \"...\"    (add corrective Tasks and continue)"
            exit 4 ;;
        awaiting_human_qa)
            warn "the Phase is at awaiting_human_qa: wait for the human QA verdict first"
            warn "  phase-gate.sh qa-pass --note \"...\"  /  phase-gate.sh qa-fail --note \"...\""
            exit 4 ;;
        *)
            die "RUN_STATE.status is '${state_status:-<empty>}' (unknown state; fix $RUN_STATE)" ;;
    esac

    # --- locate the phase + queue --------------------------------------------------------
    PHASE="$(jqv "$RUN_STATE" '.current_phase')"
    if [[ -z "$PHASE" && -d "$ROOT/.agent/phases" ]]; then
        local dirs count
        dirs="$(find "$ROOT/.agent/phases" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort || true)"
        count="$(printf '%s\n' "$dirs" | grep -c . || true)"
        [[ "$count" == "1" ]] && PHASE="$(basename "$dirs")"
    fi
    [[ -n "$PHASE" ]] || die "RUN_STATE has no current_phase and .agent/phases/ is not unambiguous"
    PHASE_DIR="$ROOT/.agent/phases/$PHASE"
    QUEUE="$PHASE_DIR/TASK_QUEUE.json"
    [[ -f "$QUEUE" ]] || die "no $QUEUE (plan the Phase into a queue first)"

    if ! validate_plan; then
        warn "the Phase plan is not executable: $plan_error"
        warn "Codex must fix $QUEUE (checkpoint; nothing was run)"
        exit 2
    fi

    local escalated ip_count
    escalated="$(jq -r '[.tasks[] | select(.status == "escalated") | .id] | join(",")' "$QUEUE")"
    ip_count="$(jq -r '[.tasks[] | select(.status == "in_progress")] | length' "$QUEUE")"
    if (( ip_count > 1 )); then
        die "queue has $ip_count Tasks in_progress; only one may be (fix the queue)"
    fi

    RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
    local phase_log="$CURRENT/logs/phase-${PHASE}-${RUN_ID}.log"
    mkdir -p "$CURRENT/logs" "$PHASE_DIR/history"

    log "phase=$PHASE status=$state_status tasks: $(jq -r '[.tasks[]|select(.status=="done")]|length' "$QUEUE") done, $(jq -r '[.tasks[]|select(.status=="pending")]|length' "$QUEUE") pending, $(jq -r '[.tasks[]|select(.status=="in_progress")]|length' "$QUEUE") in_progress"
    log "phase verification: $(jq -r '(.phase_verification // []) | map(.cmd) | join(" ; ")' "$QUEUE")"
    log "log=$phase_log"

    if [[ -n "$escalated" ]]; then
        STOP_TASK="${escalated%%,*}"
        stop_phase 3 escalated "escalated_task" "Task(s) $escalated are escalated; Codex must resolve them in the queue (revise, split or drop) before the loop runs again"
    fi

    if [[ "$dry_run" -eq 1 ]]; then
        log "dry-run: no worker is started"
        jq -r '.tasks[] | "  \(.id)  \(.status)  risk=\(.risk // "low")  \(.title)"' "$QUEUE"
        exit 0
    fi

    # --- resume diagnostics run BEFORE the loop lock is taken: check-state must
    #     never see this process's own .phase.lock as "another loop is alive".
    if [[ -n "$CHECK_STATE" ]]; then
        local preflight
        preflight="$(next_task_id)"
        if [[ -n "$preflight" ]]; then
            # Render TASK.md for the Task about to run and move any report left
            # over from another Task aside, so the diagnostics see the state the
            # loop is actually resuming from (the loop re-renders, idempotently).
            render_task_md "$preflight" "$CURRENT/TASK.md"
            quarantine_stale_reports "$preflight"
        fi
        local cs_out="" cs_rc=0 cs_verdict
        cs_out="$(cd "$ROOT" && "$CHECK_STATE" 2>&1)" || cs_rc=$?
        cs_verdict="$(printf '%s' "$cs_out" | awk -F': ' '/^verdict: /{print $2}' | awk '{print $1}')"
        case "$cs_verdict" in
            INCONSISTENT|WORKER_RUNNING)
                printf '%s\n' "$cs_out" >&2
                stop_phase 5 checkpoint "state_inconsistent" "check-state verdict $cs_verdict: fix the state before the loop runs" ;;
        esac
    fi

    acquire_phase_lock "$break_lock"
    trap 'release_phase_lock' EXIT

    # --- task loop -------------------------------------------------------------------------
    local ran=0
    while :; do
        local next_id
        next_id="$(next_task_id)"
        [[ -z "$next_id" ]] && break
        if [[ "$max_tasks" -gt 0 && "$ran" -ge "$max_tasks" ]]; then
            STOP_TASK="$next_id"
            stop_phase 2 checkpoint "max_tasks_reached" "--max-tasks $max_tasks reached; the next Task is $next_id"
        fi

        local mode risk title resumed=no
        mode="$(queue_task_field "$next_id" '.mode')"
        risk="$(queue_task_field "$next_id" '.risk // "low"')"
        title="$(queue_task_field "$next_id" '.title')"
        [[ "$(queue_task_status "$next_id")" == "in_progress" ]] && resumed=yes

        # 1. render TASK.md from the queue definition (idempotent on resume)
        render_task_md "$next_id" "$CURRENT/TASK.md"
        cp "$CURRENT/TASK.md" "$PHASE_DIR/history/TASK-$next_id.md"
        # 2. mark in_progress after rendering: an interruption then leaves a Task
        #    that is still pending, never a queue pointing at a missing definition
        [[ "$resumed" == "no" ]] && queue_update_task "$next_id" '.status = "in_progress"'
        queue_set_status "running"
        STOP_TASK="$next_id"
        update_run_state "running" "$next_id" "" ""
        log "$next_id start (mode=$mode risk=$risk resumed=$resumed): $title"

        # 3. one Task = one OpenCode session
        local before_paths before_hashes started rc=0
        before_paths="$(mktemp)"
        before_hashes="$(mktemp)"
        git_paths >"$before_paths"
        snapshot_hashes >"$before_hashes"
        started="$(date +%s)"
        "$WORKER" --root "$ROOT" --allow-dirty --mode "$mode" --task-id "$next_id" --title "$title" \
            2>&1 | tee -a "$phase_log" || rc=$?
        log "$next_id worker exit=$rc"

        # 4. deterministic outcome classification
        local gate_ok=0
        case "$rc" in
        0)
            gate_task "$next_id" "$started" "$before_paths" "$before_hashes" "$rc" && gate_ok=1 || gate_ok=0
            ;;
        5)
            gate_task "$next_id" "$started" "$before_paths" "$before_hashes" "$rc" || true
            rm -f "$before_paths" "$before_hashes"
            stop_phase 2 checkpoint "worker_exit_5" "$next_id wrote a RESULT.md but opencode exited non-zero; read .agent/current/RESULT.md and VERIFY.md before accepting"
            ;;
        10)
            rm -f "$before_paths" "$before_hashes"
            local esc_class
            esc_class="$(awk '/^## Class[[:space:]]*$/{getline; gsub(/^[[:space:]]+|[[:space:]]+$/,""); print; exit}' "$CURRENT/ESCALATION.md")"
            esc_class="${esc_class:-ESCALATE}"
            case "$esc_class" in
                CHECKPOINT)
                    queue_append_history "$next_id" "CHECKPOINT" "the worker stopped and asked for a decision"
                    stop_phase 2 checkpoint "worker_checkpoint" "$next_id stopped and asked for a decision; read .agent/current/ESCALATION.md" ;;
                *)
                    queue_update_task "$next_id" '.status = "escalated"'
                    queue_append_history "$next_id" "ESCALATE" "the worker escalated: $(awk '/^## Current Blocker[[:space:]]*$/{getline; print; exit}' "$CURRENT/ESCALATION.md" | cut -c1-120)"
                    stop_phase 3 escalated "worker_escalation" "$next_id escalated; read .agent/current/ESCALATION.md and resolve the blocker" ;;
            esac
            ;;
        4|6)
            rm -f "$before_paths" "$before_hashes"
            stop_phase 5 checkpoint "report_inconsistent" "$next_id produced a stale, malformed or conflicting report (exit $rc); inspect .agent/current/ and history/attempts/"
            ;;
        7|8)
            rm -f "$before_paths" "$before_hashes"
            stop_phase 5 checkpoint "worker_lock" "$next_id could not start (exit $rc): another worker or an unproven stale lock; run check-state.sh, then retry"
            ;;
        2|3)
            rm -f "$before_paths" "$before_hashes"
            stop_phase 5 checkpoint "worker_plumbing" "$next_id produced no report (opencode exit=$rc, plumbing); see $phase_log"
            ;;
        *)
            rm -f "$before_paths" "$before_hashes"
            stop_phase 2 checkpoint "worker_precondition" "$next_id could not run (exit $rc); fix the Task/state, then run the loop again"
            ;;
        esac
        rm -f "$before_paths" "$before_hashes"

        if [[ "$gate_ok" -ne 1 ]]; then
            queue_update_task "$next_id" '.status = "escalated"'
            queue_append_history "$next_id" "ESCALATE" "the evidence gate failed"
            stop_phase 3 escalated "verification_failed" "$next_id did not pass the evidence gate; see .agent/current/VERIFY.md (Codex must fix the Task, the code or the plan)"
        fi

        # 5. auto-accept: archive first, then mark done (interruption-safe ordering)
        cp "$CURRENT/VERIFY.md" "$PHASE_DIR/history/VERIFY-$next_id.md"
        local archive_out="" archive_path="" archive_rel=""
        archive_out="$(cd "$ROOT" && "$ARCHIVER" --yes --task-id "$next_id" --decision ACCEPT 2>&1)" \
            || stop_phase 2 checkpoint "archive_failed" "$next_id passed the evidence gate but could not be archived: $archive_out"
        archive_path="$(printf '%s\n' "$archive_out" | sed -n 's/.*archived task [^ ]* -> //p' | tail -1)"
        [[ -n "$archive_path" ]] && archive_rel="${archive_path#"$ROOT"/}"
        queue_update_task "$next_id" '.status = "done"'
        queue_append_history "$next_id" "ACCEPT" "auto-accepted by the evidence gate${archive_rel:+ (evidence: $archive_rel/VERIFY.md)}"
        ran=$((ran + 1))
        log "$next_id DONE (evidence gate PASS)${archive_rel:+ -> $archive_rel}"

        if [[ "$risk" == "guarded" ]]; then
            STOP_TASK=""
            stop_phase 2 checkpoint "guarded_task_review" "$next_id is a guarded Task (architecture/public API/schema/security/deployment); Codex must review it before the loop continues"
        fi
        STOP_TASK=""
        log "next: $(next_task_id || true)"
    done

    # --- phase end: run the real Phase verification, then STOP ----------------------------
    local unfinished
    unfinished="$(jq -r '[.tasks[] | select(.status=="pending" or .status=="in_progress") | .id] | join(",")' "$QUEUE")"
    if [[ -n "$unfinished" ]]; then
        STOP_TASK="${unfinished%%,*}"
        stop_phase 2 checkpoint "unfinished_tasks" "Tasks still pending/in_progress: $unfinished"
    fi

    log "no Tasks left: running the Phase verification for real"
    local pv_total pv_rc=0 pv_output="" pv_n=0
    pv_total="$(jq -r '(.phase_verification // []) | length' "$QUEUE")"
    local i=0 cmd expect
    while [[ "$i" -lt "$pv_total" ]]; do
        cmd="$(jq -r --argjson i "$i" '(.phase_verification // [])[$i].cmd' "$QUEUE")"
        expect="$(jq -r --argjson i "$i" '(.phase_verification // [])[$i].expect // "exit 0"' "$QUEUE")"
        pv_n=$((pv_n + 1))
        if run_check "$cmd" "$expect"; then
            pv_output="${pv_output}
### phase verification $pv_n: \`$cmd\` (expect: $expect)
\`\`\`
$(printf '%s' "$CHECK_OUTPUT" | tail -40)
\`\`\`
"
        else
            pv_rc=1
            pv_output="${pv_output}
### phase verification $pv_n: \`$cmd\` (expect: $expect) -> FAILED (exit $CHECK_RC)
\`\`\`
$(printf '%s' "$CHECK_OUTPUT" | tail -40)
\`\`\`
"
        fi
        i=$((i + 1))
    done

    {
        printf '# Phase verification run\n\n'
        printf -- '- Phase: %s\n' "$PHASE"
        printf -- '- at: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf -- '- Runner: run-phase.sh (deterministic, no LLM)\n'
        printf -- '- Tasks: %s\n\n' "$(jq -r '[.tasks[] | "\(.id)=\(.status)"] | join(", ")' "$QUEUE")"
        printf '## Output\n%s\n' "$pv_output"
        printf '## Result\n\n'
        if [[ "$pv_rc" -eq 0 ]]; then
            printf 'PASS (exit 0). Phase %s is ready for the Codex phase review.\n' "$PHASE"
        else
            printf 'FAIL. The Phase verification did not pass; Codex must decide (corrective Task or re-plan).\n'
        fi
    } >"$PHASE_DIR/PHASE_REVIEW.md"

    if [[ "$pv_rc" -ne 0 ]]; then
        STOP_TASK=""
        stop_phase 2 checkpoint "phase_verification_failed" "the Phase verification failed; see .agent/phases/$PHASE/PHASE_REVIEW.md"
    fi

    queue_set_status "done"
    STOP_TASK=""
    update_run_state "awaiting_phase_review" "" "phase_complete" "all Tasks done and the Phase verification passed; the Codex phase review comes next"
    release_phase_lock
    log "PHASE $PHASE: all Tasks done, Phase verification PASS"
    log "STOP: awaiting_phase_review - Codex must do the phase-level review"
    log "  phase-gate.sh review-pass --summary \"...\"   (accept the Phase)"
    log "  phase-gate.sh review-fail --reason \"...\"    (add corrective Tasks and continue)"
    printf 'run-phase: awaiting_phase_review\n'
    exit 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
    esac
    main "$@"
fi
