# Roadmap Policy

## Finding the roadmap

Check, in order, and stop at the first real roadmap:

1. `ROADMAP.md` (project root)
2. `docs/ROADMAP.md`
3. `docs/roadmap.md`
4. `docs/internal/next/roadmap.md`
5. `.agent/ROADMAP.md`
6. A pointer in `AGENTS.md` (e.g. "roadmap lives in `plans/roadmap-v3.md`")

Then read it, plus any architecture/product docs it references. Use `docs/` or
`plans/` conventions if the project has them.

If several candidates exist, pick the current one by content, headers ("current",
"v2", "active") and recency. Ask the human only if you truly cannot tell. Never
merge two roadmaps into a third.

## Authority order

```
Human intent (explicit instruction this session)
  > AGENTS.md (project rules)
    > the roadmap
      > PHASE.md (the current phase contract)
        > TASK_QUEUE.json / TASK.md
```

Lower layers never override higher ones. If they conflict, stop and ask - do not
silently pick.

## What a Phase is

A roadmap groups work into Phases (A, B, C, ...), each with a goal and acceptance
criteria. Codex executes **one Phase per run**, unless the human asks for more.
A Phase is done only when:

1. every Task in the queue is `done` (or `dropped` with a recorded reason),
2. the Phase Acceptance Criteria pass with real evidence,
3. the Required Phase Verification passes (the loop runs it, the review re-runs it),
4. the phase result is written down,
5. the human checkpoint is reached (`awaiting_human_qa` + the human's verdict).

The loop enforces the ordering: `awaiting_phase_review` -> `awaiting_human_qa` ->
`idle`. Skipping a step means `run-phase.sh` refuses to run.

## Scope rules

- Do not add Tasks that no Phase Acceptance Criterion needs.
- Do not pull work forward from a later Phase. Note it instead.
- Do not rename/re-scope Phases to make them easier.
- If the roadmap is wrong, say so and propose a change; do not execute the change
  yourself.
- The roadmap is read-only for the worker and the loop during execution.

## Phase documents

When a Phase starts, create `.agent/phases/<PHASE>/PHASE.md` (template in
`assets/templates/PHASE.md`) and the machine-readable
`.agent/phases/<PHASE>/TASK_QUEUE.json`. Keep them current:

- `## Existing State` / `## Target State` are written before planning.
- `## Phase Acceptance Criteria` and `## Required Phase Verification` drive the
  final review. The verification commands are duplicated in the queue as
  `phase_verification` (that is what the scripts run).
- `## Human QA Required` captures what the human must test manually.
- `## Result` is written by `phase-gate.sh review-pass`, not by hand.

`PHASE.md` is the Phase contract. If reality forces a change to it, record the
change and the reason; do not quietly edit acceptance criteria to match whatever
was built.
