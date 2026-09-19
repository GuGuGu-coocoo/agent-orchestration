#!/usr/bin/env bash
# fake-task.sh - offline stand-in for one worker Task's implementation step,
# used with FAKE_OPENCODE_MODE=script. It reads the Task ID from TASK.md and:
#
#   $FAKE_TASK_DIR/<id>.escalation   first line is the Class -> writes ESCALATION.md
#   $FAKE_TASK_DIR/<id>.sh           runs that script (the "implementation")
#   otherwise                        writes a default DONE RESULT.md
#
# FAKE_TASK_DIR must point OUTSIDE the project (the fixtures must not show up as
# untracked files, or the diff-scope check would trip over them).
#
# The verification commands in the fixture queue are real shell commands, so the
# deterministic evidence gate in run-phase.sh is exercised for real.

set -euo pipefail

fixture_dir="${FAKE_TASK_DIR:-.smoke}"
id="$(awk '/^## Task ID[[:space:]]*$/{getline; gsub(/[[:space:]]/,""); print; exit}' .agent/current/TASK.md)"

if [[ -f "$fixture_dir/$id.escalation" ]]; then
    class="$(head -1 "$fixture_dir/$id.escalation")"
    {
        printf '# Escalation\n\n'
        printf '## Task ID\n%s\n\n' "$id"
        printf '## Class\n%s\n\n' "$class"
        printf '## Current Blocker\nfixture blocker for %s\n' "$id"
    } >.agent/current/ESCALATION.md
    exit 0
fi

if [[ -f "$fixture_dir/$id.sh" ]]; then
    bash "$fixture_dir/$id.sh"
fi

if [[ ! -s .agent/current/RESULT.md && ! -s .agent/current/ESCALATION.md ]]; then
    {
        printf '# Result\n\n'
        printf '## Task ID\n%s\n\n' "$id"
        printf '## Status\nDONE\n\n'
        printf '## Summary\noffline fixture result for %s\n\n' "$id"
        printf '## Acceptance Criteria\n- [x] fixture criterion - checked by the fixture\n\n'
        printf '## Verification Performed\n- `true` -> exit 0\n'
    } >.agent/current/RESULT.md
fi

exit 0
