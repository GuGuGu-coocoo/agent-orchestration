#!/usr/bin/env bash
# collect-result.sh - print the worker report (RESULT.md or ESCALATION.md) for review.
#
# Usage:
#   collect-result.sh [--root DIR] [--diff]
#
# --diff also prints `git diff --stat` and `git status --porcelain` relative to
# the recorded baseline commit (best effort).
#
# Exit codes: 0 report found, 1 no report, 2 report exists but is empty,
#             4 both reports exist and are non-empty (conflict; both printed).

set -euo pipefail

usage() { sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

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

main() {
    local root_arg="" want_diff=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --root) root_arg="${2:-}"; shift 2 ;;
            --diff) want_diff=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) printf 'collect-result: unknown argument %s\n' "$1" >&2; exit 1 ;;
        esac
    done

    local root current
    root="$(resolve_root "$root_arg")"
    current="$root/.agent/current"

    local has_result=0 has_escalation=0 result_empty=0 escalation_empty=0
    if [[ -e "$current/RESULT.md" ]]; then
        if [[ -s "$current/RESULT.md" ]]; then has_result=1; else result_empty=1; fi
    fi
    if [[ -e "$current/ESCALATION.md" ]]; then
        if [[ -s "$current/ESCALATION.md" ]]; then has_escalation=1; else escalation_empty=1; fi
    fi

    if [[ "$result_empty" -eq 1 || "$escalation_empty" -eq 1 ]]; then
        printf 'collect-result: an empty report file exists in %s\n' "$current" >&2
        exit 2
    fi
    if [[ "$has_result" -eq 0 && "$has_escalation" -eq 0 ]]; then
        printf 'collect-result: no report in %s\n' "$current" >&2
        exit 1
    fi
    if [[ "$has_result" -eq 1 && "$has_escalation" -eq 1 ]]; then
        printf 'collect-result: CONFLICT both RESULT.md and ESCALATION.md exist; showing both, Supervisor must resolve\n' >&2
        printf '\n===== RESULT (%s) =====\n\n' "$current/RESULT.md"
        cat "$current/RESULT.md"
        printf '\n===== ESCALATION (%s) =====\n\n' "$current/ESCALATION.md"
        cat "$current/ESCALATION.md"
        if [[ "$want_diff" -eq 1 ]]; then
            print_diff "$root"
        fi
        exit 4
    fi

    local report kind
    if [[ "$has_result" -eq 1 ]]; then
        report="$current/RESULT.md"; kind="RESULT"
    else
        report="$current/ESCALATION.md"; kind="ESCALATION"
    fi

    printf '===== %s (%s) =====\n\n' "$kind" "$report"
    cat "$report"

    if [[ "$want_diff" -eq 1 ]]; then
        print_diff "$root"
    fi
    exit 0
}

print_diff() {
    local root="$1"
    printf '\n===== git =====\n'
    if git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1; then
        printf -- '--- git status --porcelain ---\n'
        git -C "$root" status --porcelain || true
        printf -- '--- git diff --stat ---\n'
        git -C "$root" diff --stat || true
        printf -- '--- git diff --stat --cached ---\n'
        git -C "$root" diff --cached --stat || true
    else
        printf 'not a git repository\n'
    fi
}

main "$@"
