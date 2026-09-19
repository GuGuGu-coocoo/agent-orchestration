# Roadmap Policy

## Finding the roadmap

Check, in order, and stop at the first real roadmap:

1. `ROADMAP.md` (project root)
2. `docs/ROADMAP.md`
3. `docs/roadmap.md`
4. `.agent/ROADMAP.md`
5. A pointer in `AGENTS.md` (e.g. "roadmap lives in `plans/roadmap-v3.md`")

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
criteria. The Supervisor executes **one Phase per run**, unless the human asks for
more. A Phase is done only when:

1. every Task in the queue is `done`,
2. the Phase Acceptance Criteria pass with real evidence,
3. the Required Phase Verification passes,
4. the phase result is written down,
5. the human checkpoint (if requested) is reached.

## Scope rules

- Do not add Tasks that no Phase Acceptance Criterion needs.
- Do not pull work forward from a later Phase. Note it instead.
- Do not rename/re-scope Phases to make them easier.
- If the roadmap is wrong, say so and propose a change; do not execute the change
  yourself.
- The roadmap is read-only for worker and Supervisor during execution.

## Phase documents

When a Phase starts, create `.agent/phases/<PHASE>/PHASE.md` (template in
`assets/templates/PHASE.md`) and keep it current:

- `## Existing State` / `## Target State` are written before planning.
- `## Phase Acceptance Criteria` and `## Required Phase Verification` drive the
  final review.
- `## Human QA Required` captures what the human must test manually.
- `## Result` is written only at phase completion.

`PHASE.md` is the Phase contract. If reality forces a change to it, record the
change and the reason; do not quietly edit acceptance criteria to match whatever
was built.
