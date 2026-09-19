# Phase Planning

## Goal

Turn one Phase of a roadmap into a short, ordered queue of **atomic Tasks**, once,
before any worker runs: *Plan upfront, revise when evidence requires it.*

## Before planning

- Read `AGENTS.md`, the roadmap, and any architecture/product docs the roadmap
  points to.
- Inspect the code the Phase will touch (read-only is usually enough).
- Note the current test/lint/build entry points: every Task needs a real
  verification command.
- Determine the human checkpoint: if the user said "stop after Phase C", that is
  the queue's `human_checkpoint_after_phase`.

## Task sizing rules

**Coarse by default.** Prefer a handful of substantial Tasks over many tiny ones;
every Task costs a Supervisor review round.

A good Task is:

- **One coherent behavior** - a reviewer can describe it in one sentence.
- **One subsystem/module** - usually 1-5 files. Implementation and its tests belong
  to the SAME Task when they cover one behavior; do not split them mechanically.
- **Minutes to ~30 minutes of worker time** - the worker may run unattended, so a
  Task that needs hours is too big.
- **Independently verifiable** - at least one exact command with an expected result.
- **Bounded** - `Allowed Changes` lists files/dirs; `Forbidden Changes` closes the rest.
- **Self-contained** - everything needed is in the Task or readable in the repo.

Split only when:

- the pieces are unrelated behaviors joined by "and",
- the worker would have to plan inside the Task,
- the pieces touch different subsystems,
- one piece cannot be verified until another lands.

Do not split when the pieces share one verification and one coherent purpose.
Aim for roughly 3-8 Tasks per Phase; if the queue grows past ~10, merge related Tasks.

## Suggested Task archetypes

Only when a Phase genuinely has stages, the common shapes are (not a template to force):

1. base implementation / wiring
2. integration with existing behavior
3. edge cases and failure behavior
4. automated tests for the above
5. docs/config touch-ups required by the change

## Writing the queue

`TASK_QUEUE.json` fields per Task:

```json
{
  "id": "C01",
  "title": "short imperative title",
  "mode": "implement",
  "status": "pending",
  "acceptance_summary": "one line the final review can check",
  "depends_on": [],
  "history": []
}
```

Statuses: `pending` | `in_progress` | `done` | `escalated` | `dropped`.

Rules:

- IDs are `<PHASE><NN>`: `C01`, `C02`, ...
- Order by dependency; never order by "nice to have".
- Every Task must contribute to a Phase Acceptance Criterion. If it does not, cut it.
- `Non-Goals` in `PHASE.md` protects the queue from scope creep.
- The queue is complete enough to run without re-planning after every Task, but the
  Supervisor may revise **pending** Tasks when evidence requires it.

## Revising the queue

Revise only `pending` Tasks (never rewrite history). Record every change:

```json
"adjustments": [
  {
    "at": "2026-09-19T10:15:00Z",
    "after_task": "C02",
    "change": "split C03 into C03a/C03b",
    "reason": "C02 revealed the storage layer must change first"
  }
]
```

Reasons to revise: a Task exposed an architectural problem, a dependency changed,
a Task proved too big, or new information invalidated an assumption. Anything else
is scope creep.

## Handoff hygiene

For each Task, before calling the worker:

1. Render `.agent/current/TASK.md` with all sections filled - especially
   `Allowed Changes`, `Forbidden Changes`, `Acceptance Criteria`,
   `Required Verification`, `Escalation Conditions`.
2. Save a copy under `.agent/phases/<PHASE>/history/`:
   `TASK-<id>.md`.
3. Update queue/run state to `in_progress`.
4. Then run `cheap-worker/scripts/run-worker.sh --mode <mode>`.

The worker should need zero questions. If you cannot fill a section, the Task is
not ready.
