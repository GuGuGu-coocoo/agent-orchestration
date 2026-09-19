# Stop Policy (checkpoint vs escalation)

## Principle

The worker finishes ordinary work; it does not make decisions that belong to
Codex or the human. Stopping with a report is a **successful** outcome when the
Task genuinely needs a decision.

The loop (`run-phase.sh`) stops on both classes and hands over to Codex. The
difference only tells Codex how urgent and how blocked the Task is.

## Class CHECKPOINT - a decision is needed (progress is possible)

Write `ESCALATION.md` with `## Class` = `CHECKPOINT` and stop when:

- the Task turns out to need architecture, public API, schema/data migration,
  security, permission, credential or deployment decisions;
- the Task's scope is clearly larger than `Allowed Changes` (scope growth);
- the acceptance criteria cannot be verified objectively with the given commands;
- the Task contradicts `AGENTS.md` or `Forbidden Changes`;
- product intent, naming/branding, or roadmap changes are needed;
- the Task turns out to be several Tasks;
- you are materially unsure that the change is correct, even though commands pass;
- a guarded change (architecture / public API / schema / security / deployment)
  would have to be made that the Task does not explicitly authorize.

## Class ESCALATE - blocked

Write `ESCALATION.md` with `## Class` = `ESCALATE` and stop when:

- two genuinely different attempts failed;
- the Task is contradictory or impossible (for example a frozen test fixture
  asserts behavior the Task asks to change);
- the only way to satisfy the Task is to violate the safety policy, delete or
  weaken tests, hardcode a value, or touch credentials/production systems;
- the repository state prevents any honest progress.

A missing `## Class` is treated as `ESCALATE`.

## Do not stop for

- a compile error, typo, missing import, or failing test you can debug;
- an unclear variable name you can decide within `Allowed Changes`;
- a tool that needs a slightly different invocation;
- missing optional context you can find by reading the repo.

## Attempt budget

```
Attempt 1 -> fails -> Attempt 2 (genuinely different) -> fails -> ESCALATE and stop
```

"Genuinely different" means a different hypothesis or mechanism, not a re-run
with a tweak. Maximum two approaches. Evidence of both attempts goes into
`ESCALATION.md`.

## After writing the report

- Stop. Do not keep editing "just in case".
- Do not commit, stash, or clean up the working tree.
- Leave the repository in a state where a human can inspect the evidence.

## What Codex does with it

- **CHECKPOINT** -> Codex answers the question: revise the Task definition,
  split it, write `.agent/current/REVIEW.md` corrections (same Task ID), record a
  queue adjustment, or ask the human for a genuine product decision. Then the
  loop runs again.
- **ESCALATE** -> the Task is `escalated` in the queue; Codex must revise, split
  or drop it before the loop can continue. Never re-send the identical Task.
- Repeated stops on the same Task -> split the Task or change the approach.
