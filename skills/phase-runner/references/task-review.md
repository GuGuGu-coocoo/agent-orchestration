# Task Review

Review happens after every worker run. It is a **Supervisor-owned** decision and
ends in exactly one of: **ACCEPT**, **REWORK**, **ESCALATE**.

## Minimum reading set

Do not rescan the whole repo per Task. Read:

1. `.agent/current/TASK.md` - what was asked (plus `REVIEW.md` if it was a rework)
2. `.agent/current/RESULT.md` or `ESCALATION.md` - what was reported
3. `git diff --stat` and `git diff` - what actually changed
4. The Task's Required Verification output (or re-run it - see below)
5. Only the changed files needed to judge correctness or intent

Treat the worker's report as a claim, not as evidence. The diff and the test
output are the evidence.

## Check list

- **Scope**: does the diff touch only `Allowed Changes`? Anything outside is a
  finding, even if it looks like an improvement.
- **Behavior**: does it implement `Desired Behavior`, not something adjacent?
- **Criteria**: is every Acceptance Criterion actually satisfied? Re-derive each
  one from the diff/commands, don't trust the ticks.
- **Verification**: were the Required Verification commands run? Re-run the cheap
  or suspicious ones yourself. Never accept "all tests pass" without output.
- **Tests**: no deletions, no weakened assertions, no hardcoded values added to
  make something pass.
- **Safety**: no commits/pushes, no unrelated formatters, no secret changes, no
  hidden catch-all error swallowing.
- **Residue**: nothing left behind that shouldn't be (debug prints, temp files in
  tracked paths, TODO stubs that silently no-op).

## Decisions

### ACCEPT

All criteria satisfied, scope clean, verification real.

1. `archive-task.sh --yes --decision ACCEPT` **first** (archive, then done: an
   interruption then leaves an archived Task that is still `in_progress`, which
   `check-state.sh` reports as "already archived, verify then mark done").
2. `TASK_QUEUE.json`: Task -> `done`, append a history entry
   (`{at, decision: "ACCEPT", note}`). Write via temp file + rename.
3. `RUN_STATE.json`: `current_task` = next Task (or empty at phase end).
4. Start the next Task immediately. **Do not ask the human whether to continue.**

### REWORK

The Task is right but the execution is not: wrong/incomplete behavior, missing
tests, scope violation, weak evidence.

1. Write `.agent/current/REVIEW.md`:

```markdown
# Review

## Task ID
C03

## Decision
REWORK

## Findings
- <file:line> - <what is wrong and why it matters>

## Required Corrections
- <imperative, checkable item>
- <imperative, checkable item>

## Keep
- <what must not be undone>
```

2. Keep the Task `in_progress`; append history entry
   (`{at, decision: "REWORK", note}`).
3. Re-run the worker for the same Task. The worker must read REVIEW.md.
4. Bound the loop: 2 REWORKs on the same Task with no convergence -> treat as an
   ESCALATE (the Task is wrong, not the worker).

Do not rewrite TASK.md in place for a rework; if the *Task definition* is wrong,
that is an escalation/plan adjustment, not a rework.

### ESCALATE

Either the worker escalated, or you (Supervisor) find a systemic blocker.

1. Read `ESCALATION.md` (if the worker wrote one); verify its evidence instead of
   trusting it.
2. Decide the class:
   - **Technical/architectural** - change the plan: split the Task, add context,
     choose a different approach, or fix a wrong assumption. Never re-send the
     identical Task.
   - **Product** - only now involve the human, with a recommendation and the
     trade-off in 3-5 lines.
3. Record in `TASK_QUEUE.json`: Task -> `escalated` (or back to `pending` after a
   plan change), plus an `adjustments` entry when the plan changes.
4. If the whole Phase is blocked, set `RUN_STATE.json.status = blocked` and report.

## Phase-level review (after the last Task)

1. Run the Phase Acceptance Criteria from `PHASE.md` end to end.
2. Run the Required Phase Verification (full suite/build/lint/smoke).
3. Confirm `TASK_QUEUE.json` has no `pending`/`in_progress` Tasks.
4. Write the `## Result` section of `PHASE.md`.
5. Set `RUN_STATE.json.status = awaiting_human_qa`.
6. Stop and report. Do not begin the next Phase.
