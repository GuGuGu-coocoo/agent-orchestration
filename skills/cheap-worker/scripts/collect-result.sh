#!/usr/bin/env bash
# collect-result.sh - print the worker report (RESULT.md or ESCALATION.md) for review.
#
# Usage:
#   collect-result.sh [--root DIR] [--diff]
#
# --diff also prints `git diff --stat` and `git status --porcelain` relative to
# the recorded baseline commit (best effort).
#
# Exit codes: 0 report found, 1 no report, 2 report exists but is empty.

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

    local report="" kind=""
    if [[ -f "$current/RESULT.md" && -f "$current/ESCALATION.md" ]]; then
        printf 'collect-result: both RESULT.md and ESCALATION.md exist; showing both, Supervisor must resolve\n' >&2
    fi
    if [[ -f "$current/RESULT.md" ]]; then
        report="$current/RESULT.md"; kind="RESULT"
    elif [[ -f "$current/ESCALATION.md" ]]; then
        report="$current/ESCALATION.md"; kind="ESCALATION"
    fi

    if [[ -z "$report" ]]; then
        printf 'collect-result: no report in %s\n' "$current" >&2
        exit 1
    fi
    if [[ ! -s "$report" ]]; then
        printf 'collect-result: %s is empty\n' "$report" >&2
        exit 2
    fi

    printf '===== %s (%s) =====\n\n' "$kind" "$report"
    cat "$report"

    if [[ "$want_diff" -eq 1 ]]; then
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
    fi
    exit 0
}

main "$@"
