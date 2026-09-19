# Checkpoint Handling (Codex)

The loop stops for Codex in exactly four shapes. All of them are cheap: read the
named files, decide, adjust the queue, run the loop again. None of them allow
"just fix it yourself" outside the queue.

Read `.agent/RUN_STATE.json` first: `status` and `stop_reason` say which shape it
is.

| stop_reason | shape | what Codex does |
| --- | --- | --- |
| `guarded_task_review` | a `guarded` Task was accepted | review that Task's diff yourself (architecture / public API / schema / security / deployment); then run the loop again |
| `worker_checkpoint` | the worker asked a question (`ESCALATION.md`, Class CHECKPOINT) | answer it: revise the Task, split it, write `REVIEW.md` corrections, or ask the human |
| `worker_escalation`, `escalated_task`, `verification_failed` | blocked | fix the Task definition or the plan in the queue, then run the loop |
| `state_inconsistent` (only from a stop *inside* the loop), `report_inconsistent`, `worker_plumbing`, `worker_lock`, `worker_precondition`, `worker_exit_5`, `phase_verification_failed` | plumbing / state | inspect, fix the state, then run the loop |

## 1. `worker_checkpoint` - the worker asked for a decision

Read `.agent/current/ESCALATION.md` (`## Class` = CHECKPOINT):

- **Architecture / public API / schema / security / deployment question** -> decide
  it yourself if the roadmap already answers it; otherwise ask the human with a
  recommendation (3-5 lines).
- **Task is too big / needs splitting** -> split the queue entry (record an
  `adjustments` entry) and drop the old one, or mark it `dropped`.
- **The Task definition was unclear but the work is right** -> write
  `.agent/current/REVIEW.md` with the same Task ID and concrete corrections; the
  loop re-runs the same Task with those corrections.
- **Acceptance criteria were not objectively verifiable** -> rewrite the Task's
  `verification` commands; that is a plan bug, not a worker bug.

Then run `run-phase.sh` again. It resumes the `in_progress` Task (re-rendering
`TASK.md` from the revised queue entry).

## 2. `worker_escalation` / `escalated_task` / `verification_failed` - blocked

The Task is `escalated` in the queue. The loop refuses to run while that is true.

1. Read `ESCALATION.md` and `.agent/current/VERIFY.md` (evidence gate output).
2. Decide: revise the Task definition, split it, or `dropped` it with a recorded
   reason. Never re-send the identical Task.
3. If the *Phase plan* was wrong, fix the plan and record the reason in
   `adjustments`; do not invent a Task that no Phase criterion needs.
4. Run `run-phase.sh` again.

If the escalation is a genuine product decision, ask the human - with the
trade-off and your recommendation, not the raw log.

## 3. `guarded_task_review` - a guarded Task was accepted

The Task passed the evidence gate and is archived; the loop stopped so that a
human-owned decision does not slip through unreviewed.

- Check the diff of that Task (`.agent/history/*-<id>/RESULT.md`,
  `VERIFY-<id>.md`, and `git diff`).
- If it is what the plan intended, run the loop again.
- If not, add a corrective Task (or `review-fail` at the end of the Phase if the
  Phase is otherwise complete) - do not patch the code outside the loop.

## 4. Plumbing and inconsistent stops

A **refusal before the loop starts** (exit 5: a live worker or another phase loop,
an inconsistent state, a path the scope check cannot represent) changes nothing:
no `RUN_STATE.json` write, no `TASK.md` rewrite, no logs directory. It reports what
it found and leaves the project exactly as it was, so a live run is never disturbed.
Fix the cause, then run the loop again.

Stops **inside** the loop do record their state (`stop_reason`):

`worker_plumbing` (opencode failed, no report), `worker_lock` (another worker or
an unproven stale lock), `report_inconsistent` (stale/malformed/conflicting
report), `state_inconsistent` (check-state verdict INCONSISTENT found mid-loop),
`worker_precondition` (TASK.md invalid, dirty tree, id mismatch),
`worker_exit_5` (valid RESULT but opencode exited non-zero),
`archive_failed`, `phase_verification_failed`.

1. Run `~/.agents/skills/cheap-worker/scripts/check-state.sh` and read its verdict.
2. Fix the listed state issue (rewrite TASK.md from the queue, clear a proven-dead
   lock with `--break-lock` after verifying, resolve double reports by archiving
   the older one).
3. For `worker_exit_5`, read `RESULT.md` + `VERIFY.md`: if the change is complete
   and correct, revise the Task so the loop re-runs it (or add a corrective Task);
   never accept an unverified result by hand.
4. Run `run-phase.sh` again.

## What not to do

- Do not hand-edit `.agent/current/*` to make a stop go away (except `REVIEW.md`,
  which is yours to write).
- Do not mark a Task `done` yourself; only the evidence gate + archive does that.
- Do not run the worker for a single Task outside the loop except for a genuine
  one-off (a defect the human reported); even then, prefer a corrective Task.
- Do not start the next Phase from a checkpoint. A Phase ends only at
  `awaiting_phase_review` -> `awaiting_human_qa`.
