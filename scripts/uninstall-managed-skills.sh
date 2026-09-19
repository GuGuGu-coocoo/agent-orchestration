#!/usr/bin/env bash
# uninstall-managed-skills.sh - remove ONLY the two skills managed by this project.
#
#   ~/.agents/skills/cheap-worker
#   ~/.agents/skills/phase-runner
#
# Guarantees:
#   - exact literal paths only; no globs, no pattern matching, no find -delete
#   - never removes ~/.agents/skills or its parents
#   - never touches any other skill (docx, pdf, pptx, xlsx, ...)
#   - shows exactly what will be removed before doing it
#   - every target must be marked as managed by this project; unmarked
#     directories are refused unless --force is given explicitly
#
# Usage:
#   uninstall-managed-skills.sh [--yes] [--dry-run] [--force] [--target DIR]
#
# Exit codes: 0 success, 1 failure / user-abort.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_ROOT="${HOME}/.agents/skills"
SKILLS=("cheap-worker" "phase-runner")
MARKER=".installed-by-agent-orchestration"

CONFIRMED=0
DRY_RUN=0
FORCE=0

step() { printf '[uninstall-skills] %s\n' "$*"; }
die()  { printf '[uninstall-skills] ERROR: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y)  CONFIRMED=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --force)   FORCE=1; shift ;;
        --target)  [[ $# -ge 2 ]] || die "--target requires a directory"; TARGET_ROOT="${2:?}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *)         die "unknown argument '$1' (try --help)" ;;
    esac
done

[[ "$TARGET_ROOT" == /* ]] || die "target root must be absolute: $TARGET_ROOT"
[[ "$TARGET_ROOT" != "/" ]] || die "refusing to operate on '/'"
[[ -d "$TARGET_ROOT" ]] || { step "target root does not exist: $TARGET_ROOT (nothing to do)"; exit 0; }
TARGET_ROOT="$(cd "$TARGET_ROOT" && pwd -P)"
[[ "$(basename "$TARGET_ROOT")" == "skills" ]] || die "safety check failed: target root must end in '/skills': $TARGET_ROOT"

TO_REMOVE=()
for skill in "${SKILLS[@]}"; do
    dst="$TARGET_ROOT/$skill"
    if [[ ! -e "$dst" ]]; then
        step "not present, skipping: $dst"
        continue
    fi
    # Literal-path safety: the resolved path must be exactly <root>/<skill>.
    resolved="$(cd "$(dirname "$dst")" && pwd -P)/$(basename "$dst")"
    [[ "$resolved" == "$TARGET_ROOT/$skill" ]] || die "safety check failed: $dst resolves to $resolved"
    [[ -d "$dst" ]] || die "$dst is not a directory; refusing to remove"

    if [[ -f "$dst/$MARKER" ]]; then
        TO_REMOVE+=("$dst")
    elif [[ "$FORCE" -eq 1 ]]; then
        step "WARNING: $dst is not marked as managed by this project; removing anyway because --force was given"
        TO_REMOVE+=("$dst")
    else
        die "$dst is not marked as managed by this project ($MARKER missing); refusing (use --force only if you are certain)"
    fi
done

if [[ "${#TO_REMOVE[@]}" -eq 0 ]]; then
    step "nothing to remove."
    exit 0
fi

step "will remove exactly these paths:"
for d in "${TO_REMOVE[@]}"; do
    step "  $d"
done
step "other skills in $TARGET_ROOT will NOT be touched:"
for d in "$TARGET_ROOT"/*/; do
    [[ -d "$d" ]] || continue
    case "$(basename "$d")" in
        cheap-worker|phase-runner) continue ;;
    esac
    step "  keep: ${d%/}"
done

if [[ "$DRY_RUN" -eq 1 ]]; then
    step "dry-run: no changes made."
    exit 0
fi

if [[ "$CONFIRMED" -eq 0 ]]; then
    step "not removed. Re-run with --yes to confirm (this is deliberate: no accidental deletions)."
    exit 1
fi

for d in "${TO_REMOVE[@]}"; do
    [[ "$d" != "$TARGET_ROOT" ]] || die "refusing to remove the skills root itself"
    [[ "$d" == "$TARGET_ROOT"/cheap-worker || "$d" == "$TARGET_ROOT"/phase-runner ]] || die "unexpected path: $d"
    rm -r "$d" || die "failed to remove $d"
    step "removed: $d"
done

step "done. Remaining skill directories in $TARGET_ROOT:"
for d in "$TARGET_ROOT"/*/; do
    [[ -d "$d" ]] && step "  ${d%/}"
done
exit 0
