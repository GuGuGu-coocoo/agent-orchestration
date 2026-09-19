#!/usr/bin/env bash
# doctor.sh - environment health check for the cheap-worker skill.
#
# Usage:
#   doctor.sh [--root DIR]
#
# Reports (never changes anything):
#   - opencode version and the non-interactive flags the worker relies on
#   - the shared background service used for OpenCode Desktop observability
#   - git / jq / python3 availability
#   - skill install location and required files
#   - current .agent state for the project (if any)
#
# Exit codes: 0 healthy (warnings allowed), 1 problems found.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBLEMS=0
WARNINGS=0

ok()   { printf '  ok      %s\n' "$*"; }
warn() { printf '  warn    %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
bad()  { printf '  FAIL    %s\n' "$*"; PROBLEMS=$((PROBLEMS + 1)); }
die()  { printf 'doctor: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

skill_root() {
    local root="$SCRIPT_DIR/.."
    [[ -f "$root/SKILL.md" ]] && { printf '%s\n' "$(cd "$root" && pwd)"; return 0; }
    [[ -f "$HOME/.agents/skills/cheap-worker/SKILL.md" ]] && { printf '%s\n' "$HOME/.agents/skills/cheap-worker"; return 0; }
    return 1
}

main() {
    local root_arg=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --root)  root_arg="${2:-}"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown argument '$1' (try --help)" ;;
        esac
    done

    printf 'cheap-worker doctor\n'
    printf '===================\n'

    printf 'tools\n'
    if command -v opencode >/dev/null 2>&1; then
        local ov
        ov="$(opencode --version 2>/dev/null | head -1)"
        ok "opencode $ov ($(command -v opencode))"
        for flag in --title --agent --format; do
            if opencode run --help 2>&1 | grep -q -- "$flag"; then
                ok "opencode run supports $flag"
            else
                bad "opencode run does NOT list $flag; this worker version expects OpenCode 2.x"
            fi
        done
    else
        bad "opencode not found on PATH"
    fi
    command -v git    >/dev/null 2>&1 && ok "git $(git --version | awk '{print $3}')"      || bad "git not found"
    command -v jq     >/dev/null 2>&1 && ok "jq $(jq --version)"                            || bad "jq not found (required)"
    command -v python3 >/dev/null 2>&1 && ok "python3 $(python3 --version 2>&1 | awk '{print $2}')" || warn "python3 not found (only needed for python projects)"

    printf 'backend (OpenCode shared service, used for Desktop observability)\n'
    if command -v opencode >/dev/null 2>&1; then
        local svc
        if svc="$(opencode service status 2>/dev/null)" && [[ -n "$svc" ]]; then
            ok "background service reachable at $svc"
            ok "worker sessions appear in OpenCode Desktop"
        else
            warn "background service not reachable; 'opencode service start' may be needed"
        fi
        # Check the actual code, ignoring comments that name the forbidden flags.
        local rw_code=""
        [[ -f "$SCRIPT_DIR/run-worker.sh" ]] && rw_code="$(grep -v '^[[:space:]]*#' "$SCRIPT_DIR/run-worker.sh" || true)"
        if printf '%s\n' "$rw_code" | grep -q -- '--standalone'; then
            bad "run-worker.sh passes --standalone; the worker must use the shared service"
        else
            ok "run-worker.sh never uses --standalone"
        fi
        if printf '%s\n' "$rw_code" | grep -q -- '--model'; then
            bad "run-worker.sh passes --model; the worker must use OpenCode's configured default model"
        else
            ok "run-worker.sh never passes --model (model comes from OpenCode config)"
        fi
    fi

    printf 'notify backend (optional: background handoff + Codex wake-up)\n'
    local codex_bin=""
    if [[ -n "${CODEX_BIN:-}" && -x "${CODEX_BIN:-}" ]]; then
        codex_bin="$CODEX_BIN"
    elif command -v codex >/dev/null 2>&1; then
        codex_bin="$(command -v codex)"
    elif [[ -x "/Applications/ChatGPT.app/Contents/Resources/codex" ]]; then
        codex_bin="/Applications/ChatGPT.app/Contents/Resources/codex"
    fi
    if [[ -n "$codex_bin" ]]; then
        ok "codex CLI found: $codex_bin"
        if "$codex_bin" queue --help >/dev/null 2>&1; then
            ok "codex queue available (wake-up supported)"
        else
            warn "codex CLI found but 'queue' is unavailable; worker-notify will fall back to NOTIFY_FAILED.md"
        fi
    else
        warn "codex CLI not found; worker-notify will write NOTIFY_FAILED.md instead of waking a session"
    fi
    command -v caffeinate >/dev/null 2>&1 && ok "caffeinate available (no-sleep assertion while a worker runs)" || warn "caffeinate not found (macOS sleep may pause unattended runs)"

    printf 'skill files\n'
    local sk
    if sk="$(skill_root)"; then
        ok "skill root: $sk"
        [[ -f "$sk/SKILL.md" ]]                              && ok "SKILL.md"                          || bad "SKILL.md missing"
        [[ -f "$sk/references/worker-contract.md" ]]         && ok "references/worker-contract.md"     || bad "references/worker-contract.md missing"
        [[ -f "$sk/references/worker-prompt.md" ]]           && ok "references/worker-prompt.md"       || bad "references/worker-prompt.md missing"
        [[ -f "$sk/references/safety-policy.md" ]]           && ok "references/safety-policy.md"       || bad "references/safety-policy.md missing"
        [[ -f "$sk/references/escalation-policy.md" ]]       && ok "references/escalation-policy.md"   || bad "references/escalation-policy.md missing"
        for s in doctor.sh run-worker.sh worker-notify.sh status.sh check-state.sh collect-result.sh archive-task.sh; do
            [[ -f "$sk/scripts/$s" ]] && ok "scripts/$s" || bad "scripts/$s missing"
        done
        if [[ "$sk" == "$HOME/.agents/skills/cheap-worker" ]]; then
            ok "installed globally for OpenCode skill discovery"
        else
            warn "running from source tree, not the global install (~/.agents/skills/cheap-worker)"
        fi
    else
        bad "cannot locate cheap-worker skill root"
    fi

    printf 'project state\n'
    local project_root
    if [[ -n "$root_arg" ]]; then
        project_root="$(cd "$root_arg" && pwd)" || die "cannot cd into '$root_arg'"
    elif git rev-parse --show-toplevel >/dev/null 2>&1; then
        project_root="$(git rev-parse --show-toplevel)"
    else
        project_root="$(pwd)"
    fi
    ok "project root: $project_root"
    local agent_dir="$project_root/.agent"
    if [[ -d "$agent_dir" ]]; then
        ok ".agent/ exists"
        [[ -f "$agent_dir/current/TASK.md" ]]       && ok "TASK.md present"       || warn "no .agent/current/TASK.md"
        [[ -f "$agent_dir/current/RESULT.md" ]]     && ok "RESULT.md present"     || true
        [[ -f "$agent_dir/current/ESCALATION.md" ]] && ok "ESCALATION.md present" || true
        if [[ -f "$agent_dir/RUN_STATE.json" ]]; then
            if command -v jq >/dev/null 2>&1 && jq empty "$agent_dir/RUN_STATE.json" >/dev/null 2>&1; then
                ok "RUN_STATE.json valid JSON"
            else
                bad "RUN_STATE.json is not valid JSON"
            fi
        fi
    else
        warn ".agent/ does not exist yet (created on first Supervisor/worker run)"
    fi

    printf '\nresult: %d problem(s), %d warning(s)\n' "$PROBLEMS" "$WARNINGS"
    [[ "$PROBLEMS" -eq 0 ]]
}

main "$@"
