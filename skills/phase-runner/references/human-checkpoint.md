# Human Checkpoint

## What it is

The point where autonomous work stops even though it *could* continue. Typical
user instruction:

> "用 $phase-runner 按现有 roadmap 完成 Phase C。普通技术问题自行处理。
> Phase C 完成以后停止，我来测试。"

Meaning: run the whole Phase autonomously, handle ordinary problems without
asking, stop exactly at the end of Phase C, and wait for manual QA.

The end of every Phase is a checkpoint by construction:

```
Tasks done -> awaiting_phase_review -> (Codex review) -> awaiting_human_qa -> (human)
```

## At the checkpoint

The loop stops by itself at `awaiting_phase_review`; Codex then:

1. Runs the Phase-level integration review (`references/phase-review.md`).
2. Accepts it with `phase-gate.sh review-pass --summary "..."`, which re-runs the
   Phase verification for real, writes `PHASE.md` `## Result` and sets
   `RUN_STATE.json`:

```json
{
  "target_phase": "C",
  "current_phase": "C",
  "current_task": "",
  "status": "awaiting_human_qa",
  "stop_reason": "",
  "phase_review": "passed",
  "human_checkpoint": "after_phase_C"
}
```

3. Reports to the human:
   - what the Phase delivered (bullets, from the diff and criteria),
   - what was verified automatically and how,
   - what the human should test manually (`Human QA Required`),
   - anything the human should know before deciding (risks, deviations, deferred
     ideas),
   - what the next Phase would be - clearly marked as *not started*.
4. **Stops.** `run-phase.sh` refuses to run while the state is
   `awaiting_human_qa`, so "momentum" cannot start anything.

## While `awaiting_human_qa`

Allowed:

- Answer questions about the work.
- Run read-only inspection commands for the human.
- Fix defects the human reports - but only as **new Tasks** appended to the phase
  queue: `phase-gate.sh qa-fail --note "..."` reopens the queue, the Tasks are
  added, `run-phase.sh` runs them, the Phase verification runs again, and the
  Phase returns to `awaiting_phase_review` -> `awaiting_human_qa`.

Not allowed:

- Start the next Phase or any roadmap work outside this Phase.
- "Polish" code the human did not report.
- Re-plan the completed Phase to look better.
- Resume autonomous work because "momentum".

## After the human confirms

```sh
phase-gate.sh qa-pass --note "how the human confirmed it"
```

That records the verdict and clears the state to `idle`. Planning the next Phase
is then a deliberate, separate step: read the roadmap, do the intake again, write
the new `PHASE.md` + `TASK_QUEUE.json`, and start the loop. Nothing starts by
itself.

If the human reports defects, use `qa-fail` (see above) - never reopen the Phase
broadly.

## Checkpoints the human did not ask for

When there is no explicit checkpoint instruction:

- Still stop after the Phase and report; do not drift into the next Phase.
- The loop interrupts earlier on its own rules (checkpoint / escalation / guarded
  Task), and Codex resolves those before continuing.
- Interrupt the human early only for: genuine product decisions, unsafe or
  irreversible actions, a contradictory roadmap, or repeated escalation with no
  convergent plan.
