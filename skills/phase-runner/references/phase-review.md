# Phase Review (Codex, once per Phase)

The Phase-level integration review is the **only** mandatory Codex review. It
happens once, when the loop stops at `awaiting_phase_review`, and it is the gate
between "all Tasks passed" and "the human looks at it".

Task-level acceptance already happened in the loop: every Task was verified by
re-running its `verification` commands, checking the diff against
`allowed_changes`, and checking the ticked criteria. Do not redo that per Task;
look for what only a whole-Phase view can see.

## What to read

1. `.agent/RUN_STATE.json` - status, `stop_reason`, `current_phase`.
2. `.agent/phases/<P>/TASK_QUEUE.json` - task statuses and each Task's history
   (ACCEPT entries carry the archive path of its evidence).
3. `.agent/phases/<P>/PHASE_REVIEW.md` - the loop's Phase verification run.
4. `.agent/phases/<P>/history/` - every `VERIFY-<task>.md` (the deterministic
   evidence per Task) and `TASK-<task>.md` (what the worker saw).
5. `.agent/history/*-<task>/` - the archived `RESULT.md` files.
6. `git diff` / `git diff --stat` of the whole Phase against the baseline the
   Phase started from.
7. `.agent/phases/<P>/PHASE.md` - the acceptance criteria you are signing off.

## Check list (integration level)

- **Phase criteria**: is each `## Phase Acceptance Criteria` item actually true of
  the final tree, not just of one Task?
- **Coherence**: do the Tasks fit together - naming, error handling, config, docs -
  or does each look locally reasonable but globally inconsistent?
- **Scope**: did anything change that no Task asked for? Did a `dropped` Task get
  silently implemented or silently skipped?
- **Evidence**: does every `done` Task have an archive with a real `RESULT.md` and
  `VERIFY.md`? Any `ACCEPT` whose evidence is thin deserves a look at the diff.
- **Guarded Tasks**: if a Task was `guarded` (architecture / public API / schema /
  security / deployment), inspect that diff yourself before signing off.
- **Adjustments**: read `adjustments` - planned work that changed shape is how
  scope creep usually appears.
- **Residue**: debug prints, temporary files, TODOs that silently no-op, weakened
  tests, disabled CI checks.
- **Phase verification**: re-run it yourself (the gate does it too, but read the
  output).

## The decision

```sh
# accept the Phase -> awaiting_human_qa (STOP; the human decides next)
phase-gate.sh review-pass --summary "what you actually checked and re-ran"

# not acceptable -> the queue is reopened for corrective Tasks
phase-gate.sh review-fail --reason "what is missing or wrong"
```

- `review-pass` requires: status `awaiting_phase_review`, no pending/in_progress/
  escalated Tasks, `PHASE_REVIEW.md` present, and the `phase_verification`
  commands passing **again** (it re-runs them). It writes the `## Result` section
  of `PHASE.md` and moves the state to `awaiting_human_qa`.
- `review-fail` records a queue `adjustments` entry and sets status `running`.
  Append the corrective Tasks to the queue, then run `run-phase.sh` again - the
  loop resumes with the new Tasks. Never silently "fix" the phase yourself: a fix
  is a Task like any other.
- If a Task definition was wrong (not the execution), revise the queue entry and
  let the loop re-run it; do not hand-edit the code outside the loop.

## After `review-pass`

Report to the human:

- what the Phase delivered (bullets),
- what was verified automatically and how (commands + results),
- what the human should test by hand (from `PHASE.md` `## Human QA Required`),
- risks, deviations and deferred ideas,
- what the next Phase would be - clearly marked as *not started*.

Then stop. `awaiting_human_qa` is a hard gate: no next Phase, no opportunistic
fixes, no extra Tasks.
