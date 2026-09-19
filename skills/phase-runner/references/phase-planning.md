# Phase Planning

## Goal

Turn one Phase of a roadmap into a **machine-runnable queue of bounded Tasks**,
once, before any worker runs: *Plan upfront, revise when evidence requires it.*

The queue is not documentation - it is the input of `run-phase.sh`. Every Task in
it must be executable and objectively verifiable by the loop without Codex in the
loop.

## Before planning

- Read `AGENTS.md`, the roadmap, and any architecture/product docs the roadmap
  points to.
- Inspect the code the Phase will touch (read-only is usually enough).
- Find the project's test/lint/build entry points. These become the Tasks'
  `verification` commands and the Phase's `phase_verification`.
- Determine the human checkpoint: the Phase ends at `awaiting_human_qa` either way.

## Task sizing rules

**Coarse by default.** Prefer a handful of substantial Tasks over many tiny ones.

A good Task is:

- **One coherent behavior** - a reviewer can describe it in one sentence.
- **One subsystem/module** - usually 1-5 files. Implementation and its tests
  belong to the SAME Task when they cover one behavior.
- **Minutes to ~30 minutes of worker time** - the worker may run unattended.
- **Independently verifiable by a command** - at least one exact, non-interactive
  command the loop can re-run. If you cannot write that command, the Task is not
  ready: split it or make the acceptance observable.
- **Bounded** - `allowed_changes` lists paths/globs; `forbidden_changes` closes
  the rest. The evidence gate checks the diff against these lists.
- **Self-contained** - everything needed is in the Task or readable in the repo.

Split only when:

- the pieces are unrelated behaviors joined by "and",
- the worker would have to plan inside the Task,
- the pieces touch different subsystems,
- one piece cannot be verified until another lands.

Do not split when the pieces share one verification and one coherent purpose.
Aim for roughly 3-8 Tasks per Phase; past ~10, merge related Tasks.

## Risk classes

| `risk` | Meaning | Loop behaviour |
| --- | --- | --- |
| `low` | ordinary implementation, tests, docs | auto-accepted when the evidence gate passes; the loop continues |
| `guarded` | architecture, public API, schema/data migration, security, permissions, credentials, deployment, irreversible operations | runs normally, but the loop **stops for a Codex review** right after the Task is accepted |

Use `guarded` whenever an unintended change would be expensive or hard to
reverse. A Task that only *might* touch those areas belongs here too - the worker
will stop with `Class CHECKPOINT` if it hits one that the Task did not authorize.

## Queue schema

`TASK_QUEUE.json` (template: `assets/templates/TASK_QUEUE.json`):

```json
{
  "phase": "C",
  "status": "ready",
  "human_checkpoint_after": true,
  "phase_verification": [
    { "cmd": "python3 -m pytest -q", "expect": "exit 0" }
  ],
  "tasks": [
    {
      "id": "C01",
      "title": "short imperative title",
      "mode": "implement",
      "risk": "low",
      "status": "pending",
      "objective": "what must be true when this Task is done",
      "context": "why now, 2-5 lines",
      "existing_behavior": "observed today",
      "desired_behavior": "after this Task",
      "relevant_files": ["app.py - the module"],
      "allowed_changes": ["app.py", "test_app.py"],
      "forbidden_changes": ["src/api/**"],
      "acceptance_criteria": ["uppercase('abc') == 'ABC'"],
      "verification": [
        { "cmd": "python3 -m pytest -q test_app.py", "expect": "exit 0" }
      ],
      "escalation_conditions": ["needs a public API change"],
      "depends_on": [],
      "history": []
    }
  ],
  "adjustments": []
}
```

Rules:

- IDs are `<PHASE><NN>`: `C01`, `C02`, ... (letters, digits, `._-` only).
- `allowed_changes` / `forbidden_changes` are paths or shell globs (`src/**`,
  `app.py`, `*.md`). A changed file must match `allowed_changes` and must not
  match `forbidden_changes`; tool artifacts (`__pycache__`, `.pytest_cache`,
  `node_modules`, ...) are ignored.
- `verification[].expect` is `exit 0` (default), `exit <N>`, or
  `contains:<text>`. Commands run with `bash -c` in the project root: keep them
  non-interactive, deterministic and fast.
- `phase_verification` is the end-to-end proof for the whole Phase; the loop runs
  it when every Task is done, and `phase-gate.sh review-pass` re-runs it.
- Task statuses: `pending` | `in_progress` | `done` | `escalated` | `dropped`.
- Order by dependency; never order by "nice to have".
- Every Task must contribute to a Phase Acceptance Criterion; otherwise cut it.
- `Non-Goals` in `PHASE.md` protects the queue from scope creep.

## Revising the queue

Revise only Tasks that are not `done` (never rewrite history). Record every change:

```json
"adjustments": [
  {
    "at": "2026-09-19T10:15:00Z",
    "change": "split C03 into C03a/C03b",
    "reason": "C02 revealed the storage layer must change first"
  }
]
```

Reasons to revise: a Task exposed an architectural problem, a dependency changed,
a Task proved too big, or new information invalidated an assumption. Anything else
is scope creep. `phase-gate.sh review-fail` and `qa-fail` write this entry for you.

## Handoff hygiene

The loop renders `.agent/current/TASK.md` from the queue, so the queue entry **is**
the Task the worker sees. Before starting the loop:

1. Re-read `allowed_changes`, `forbidden_changes`, `acceptance_criteria`,
   `verification` and `escalation_conditions` of every Task. The worker should
   need zero questions.
2. Remember that the worker only reads the rendered Task: if you cannot fill a
   field, the Task is not ready.
3. After a checkpoint, `run-phase.sh` re-renders the Task from the (possibly
   revised) queue entry, so queue and Task can never drift.
