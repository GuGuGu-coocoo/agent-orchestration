# Human Checkpoint

## What it is

The point where the Supervisor stops even though it *could* continue. Typical
user instruction:

> "用 $phase-runner 按现有 roadmap 完成 Phase C。普通技术问题自行处理。
> Phase C 完成以后停止，我来测试。"

Meaning: run the whole Phase autonomously, handle ordinary problems without
asking, stop exactly at the end of Phase C, and wait for manual QA.

## At the checkpoint

The Supervisor must:

1. Have all Tasks `done` and the phase verification green.
2. Write `PHASE.md` `## Result` and update `TASK_QUEUE.json` to `status: done`.
3. Write `.agent/RUN_STATE.json`:

```json
{
  "target_phase": "C",
  "current_phase": "C",
  "current_task": "",
  "status": "awaiting_human_qa",
  "human_checkpoint": "after_phase_C"
}
```

4. Report to the human:
   - what the Phase delivered (bullets, from the diff and criteria),
   - what was verified automatically and how,
   - what the human should test manually (`Human QA Required`),
   - anything the human should know before deciding (risks, deviations,
     deferred ideas),
   - what the next Phase would be - clearly marked as *not started*.
5. **Stop.** No next Phase, no opportunistic fixes, no extra Tasks.

## While `awaiting_human_qa`

Allowed:

- Answer questions about the work.
- Run read-only inspection commands for the human.
- Fix defects the human reports - but only as **new Tasks** appended to the phase
  queue (or a follow-up phase), with the same one-Task-at-a-time worker loop.
- Record the human's verdict in `RUN_STATE.json` (`status: qa_passed` or back to
  `running` with a note).

Not allowed:

- Start the next Phase or any roadmap work outside this Phase.
- "Polish" code the human did not report.
- Re-plan the completed phase to look better.
- Resume autonomous work because "momentum".

## Resuming after QA

If the human says "continue", resume like this:

1. Read `RUN_STATE.json` and the roadmap.
2. Confirm which Phase is now in scope (usually the next one).
3. Run the normal phase workflow from intake.

If the human reports defects, do not reopen the phase broadly: convert each defect
into a concrete Task, run the worker loop on them, re-run phase verification, then
return to `awaiting_human_qa`.

## Checkpoints the human did not ask for

When there is no explicit checkpoint instruction:

- Still stop after the phase and report; do not drift into the next Phase.
- Interrupt early only for: genuine product decisions, unsafe/irreversible actions,
  contradictory roadmap, or repeated escalation with no convergent plan.

Everything else is the Supervisor's job to resolve.
