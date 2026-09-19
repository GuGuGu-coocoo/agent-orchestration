#!/usr/bin/env bash
# install-skills.sh - install/update the two skills managed by this project.
#
#   agent-orchestration -> ~/.agents/skills/cheap-worker
#   agent-orchestration -> ~/.agents/skills/phase-runner
#
# Guarantees:
#   - only these two skill directories are touched
#   - other skills in ~/.agents/skills are never read, moved or deleted
#   - fail fast, no swallowed errors, repeatable / idempotent
#   - verifies SKILL.md exists in source and target after install
#   - never deletes or replaces a target that exists but is not ours
#     (a pre-existing directory without our marker is only installed with --force
#      after being backed up)
#
# Usage:
#   install-skills.sh [--dry-run] [--force] [--target DIR] [--quiet]
#
# Exit codes: 0 success, 1 failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_ROOT="$REPO_ROOT/skills"
TARGET_ROOT="${HOME}/.agents/skills"
DEFAULT_TARGET="$TARGET_ROOT"
SKILLS=("cheap-worker" "phase-runner")
MARKER=".installed-by-agent-orchestration"

DRY_RUN=0
FORCE=0
QUIET=0
TARGET_EXPLICIT=0

log()  { [[ "$QUIET" -eq 1 ]] || printf '%s\n' "$*"; }
step() { log "[install-skills] $*"; }
die()  { printf '[install-skills] ERROR: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --force)   FORCE=1; shift ;;
        --quiet)   QUIET=1; shift ;;
        --target)  [[ $# -ge 2 ]] || die "--target requires a directory"; TARGET_ROOT="${2:?}"; TARGET_EXPLICIT=1; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *)         die "unknown argument '$1' (try --help)" ;;
    esac
done

# ---------------------------------------------------------------------------
# Safety validation
# ---------------------------------------------------------------------------

[[ -d "$SRC_ROOT" ]] || die "source skills directory not found: $SRC_ROOT"
[[ "$TARGET_ROOT" == /* ]] || die "target root must be absolute: $TARGET_ROOT"
[[ "$TARGET_ROOT" != "/" ]] || die "refusing to install into '/'"

# The managed install target is fixed; --target exists only for isolated tests.
if [[ "$TARGET_EXPLICIT" -eq 1 && "${AGENT_ORCHESTRATION_TEST_TARGET:-0}" != "1" ]]; then
    die "--target is a test-only mechanism (set AGENT_ORCHESTRATION_TEST_TARGET=1 to use it); the normal target is $DEFAULT_TARGET"
fi
[[ "$(basename "$TARGET_ROOT")" == "skills" ]] || die "target must be a 'skills' directory: $TARGET_ROOT"

for skill in "${SKILLS[@]}"; do
    [[ -d "$SRC_ROOT/$skill" ]]     || die "missing source skill directory: $SRC_ROOT/$skill"
    [[ -f "$SRC_ROOT/$skill/SKILL.md" ]] || die "missing source SKILL.md: $SRC_ROOT/$skill/SKILL.md"
done

# Resolve the prospective physical target BEFORE creating anything (M05):
# walk up to the deepest existing ancestor, canonicalize it, and append the
# not-yet-existing remainder.
if [[ -e "$TARGET_ROOT" ]]; then
    PROPOSED_RESOLVED="$(cd "$TARGET_ROOT" && pwd -P)"
else
    ANC="$TARGET_ROOT"
    while [[ ! -e "$ANC" && "$ANC" != "/" ]]; do ANC="$(dirname "$ANC")"; done
    PROPOSED_RESOLVED="$(cd "$ANC" && pwd -P)${TARGET_ROOT#"$ANC"}"
fi

# Never let the target be the source tree or a parent of it.
RD="$(cd "$REPO_ROOT" && pwd -P)"
[[ "$PROPOSED_RESOLVED" != "$RD" ]] || die "target root equals the source repo"
case "$RD" in "$PROPOSED_RESOLVED"/*) die "target root is inside the source repo: $PROPOSED_RESOLVED" ;; esac
case "$PROPOSED_RESOLVED" in "$RD"/*) die "target root contains the source repo: $PROPOSED_RESOLVED" ;; esac

# Physical target policy: the managed target lives under $HOME. A parent symlink
# that resolves outside home is refused (test redirects need the explicit gate).
HOME_PHYS_TR="$(cd "$HOME" 2>/dev/null && pwd -P || printf '%s' "$HOME")"
if [[ "$PROPOSED_RESOLVED" != "$HOME"/* && "$PROPOSED_RESOLVED" != "$HOME_PHYS_TR"/* && "${AGENT_ORCHESTRATION_TEST_TARGET:-0}" != "1" ]]; then
    die "resolved target $PROPOSED_RESOLVED is outside \$HOME; parent-symlink escapes are refused (test-only gate: AGENT_ORCHESTRATION_TEST_TARGET=1)"
fi

# Only now create the target (and any missing parents, e.g. a fresh ~/.agents).
if [[ "$DRY_RUN" -eq 0 ]]; then
    mkdir -p "$TARGET_ROOT" || die "cannot create $TARGET_ROOT"
fi
TR_RESOLVED="$PROPOSED_RESOLVED"
if [[ -e "$TARGET_ROOT" ]]; then
    TR_RESOLVED="$(cd "$TARGET_ROOT" && pwd -P)"
fi
[[ "$TR_RESOLVED" == "$PROPOSED_RESOLVED" ]] || die "target changed while creating it ($TR_RESOLVED != $PROPOSED_RESOLVED); refusing"

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

count_skills() {
    local n=0 d
    if [[ -d "$TARGET_ROOT" ]]; then
        for d in "$TARGET_ROOT"/*/; do
            [[ -d "$d" ]] && n=$((n + 1))
        done
    fi
    printf '%s' "$n"
}

step "source : $SRC_ROOT"
step "target : $TARGET_ROOT  (currently $(count_skills) skill director(y|ies))"
[[ "$DRY_RUN" -eq 1 ]] && step "mode   : DRY RUN (no changes)"
[[ "$FORCE" -eq 1 ]]   && step "mode   : FORCE (pre-existing foreign directories are backed up, then replaced)"

INSTALLED=()
SKIPPED=()
BACKED_UP=()

for skill in "${SKILLS[@]}"; do
    src="$SRC_ROOT/$skill"
    dst="$TARGET_ROOT/$skill"
    step "--- $skill ---"
    step "  from: $src"
    step "  to  : $dst"

    if [[ -L "$dst" ]]; then
        die "$dst is a symlink; refusing to modify it (remove it manually or use --force)"
    fi

    if [[ -e "$dst" && ! -d "$dst" ]]; then
        die "$dst exists and is not a directory; refusing to overwrite"
    fi

    if [[ -d "$dst" && ! -f "$dst/SKILL.md" && ! -f "$dst/$MARKER" ]]; then
        # A directory that is not clearly ours (no SKILL.md at all = malformed).
        if [[ "$FORCE" -eq 0 ]]; then
            die "$dst exists but does not look like a managed skill (no SKILL.md); re-run with --force to back it up and replace"
        fi
        backup="$dst.backup-$(date -u '+%Y%m%dT%H%M%SZ')"
        step "  backup: $dst -> $backup (foreign directory)"
        if [[ "$DRY_RUN" -eq 0 ]]; then
            mv "$dst" "$backup" || die "failed to back up $dst"
        fi
        BACKED_UP+=("$backup")
    elif [[ -d "$dst" && -f "$dst/SKILL.md" && ! -f "$dst/$MARKER" ]]; then
        # Has a SKILL.md but no marker: could be a foreign skill with the same name.
        if [[ "$FORCE" -eq 0 ]]; then
            if diff -rq "$src" "$dst" >/dev/null 2>&1; then
                step "  note: existing $dst matches source content; adopting it as managed"
            else
                die "$dst exists, is not marked as managed, and differs from source; re-run with --force to back it up and replace"
            fi
        else
            backup="$dst.backup-$(date -u '+%Y%m%dT%H%M%SZ')"
            step "  backup: $dst -> $backup (unmarked skill)"
            if [[ "$DRY_RUN" -eq 0 ]]; then
                mv "$dst" "$backup" || die "failed to back up $dst"
            fi
            BACKED_UP+=("$backup")
        fi
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        step "  [dry-run] would sync $src/ -> $dst/"
        INSTALLED+=("$dst")
        continue
    fi

    mkdir -p "$dst" || die "cannot create $dst"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete --exclude "$MARKER" "$src/" "$dst/" || die "rsync failed for $skill"
    else
        # Safe fallback: copy source over the destination without deleting anything
        # that is not a stale file from a previous install of this same skill.
        cp -R "$src/." "$dst/" || die "cp failed for $skill"
    fi
    printf 'installed %s from %s at %s\n' "$skill" "$REPO_ROOT" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$dst/$MARKER" \
        || die "cannot write marker $dst/$MARKER"

    [[ -f "$dst/SKILL.md" ]] || die "post-install verification failed: $dst/SKILL.md missing"
    INSTALLED+=("$dst")
    step "  installed and verified ($(find "$dst" -type f | wc -l | tr -d ' ') files)"
done

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

log ""
step "result:"
for d in ${INSTALLED[@]+"${INSTALLED[@]}"}; do
    if [[ "$DRY_RUN" -eq 1 ]]; then
        step "  would install: $d"
    else
        step "  installed    : $d"
    fi
done
for d in ${SKIPPED[@]+"${SKIPPED[@]}"}; do
    step "  skipped      : $d"
done
for d in ${BACKED_UP[@]+"${BACKED_UP[@]}"}; do
    step "  backed up    : $d"
done
step "other skills in $TARGET_ROOT were not modified ($(count_skills) total now)"

if [[ "$DRY_RUN" -eq 0 ]]; then
    step "done. Run: cheap-worker doctor"
fi
exit 0
