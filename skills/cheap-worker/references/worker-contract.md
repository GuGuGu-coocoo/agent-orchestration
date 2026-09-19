# Worker Contract

This is the normative contract for one `cheap-worker` run. If anything here
conflicts with the project `AGENTS.md`, the project `AGENTS.md` wins for
project-specific facts; the contract wins for worker discipline.

## Input

- `.agent/current/TASK.md` - the single Task to execute. Required.
- `.agent/current/REVIEW.md` - optional corrections from a Supervisor REWORK
  decision. If present, its `Required Corrections` are mandatory.
- `AGENTS.md` at the project root - optional project rules. Must be read if present.
- `references/safety-policy.md` - default safety boundaries. Always binding.

## Output

Exactly one of:

- `.agent/current/RESULT.md` - task finished and verified. Status must be `DONE`.
- `.agent/current/ESCALATION.md` - stopped after at most 2 failed distinct
  attempts, or the Task requires a decision the worker is not allowed to make.

Never write both. Never write neither. Never keep editing after writing either.

## Execution protocol

1. Read `AGENTS.md` (if present) and `.agent/current/TASK.md` (mandatory).
2. Read `.agent/current/REVIEW.md` (if present).
3. `git status` + `git rev-parse HEAD` - record the baseline.
4. Read the minimum set of files needed.
5. Confirm the current behavior.
6. Post a short plan (3-6 lines).
7. Make the minimal change inside `Allowed Changes`.
8. Run `Required Verification`.
9. Ordinary failure: debug yourself. Maximum **two distinct approaches**.
10. Re-run verification after every change.
11. `git diff` and `git status` - confirm only intended files changed.
12. Walk through `Acceptance Criteria` item by item.
13. Write RESULT.md or ESCALATION.md. Stop.

## Attempt budget

| Attempt | Trigger |
| --- | --- |
| Attempt 1 | first reasonable approach |
| Attempt 2 | one genuinely different approach / hypothesis |
| - | Attempt 2 fails, or evidence contradicts all hypotheses -> ESCALATE |

A "third attempt" is forbidden. Retrying the same approach with cosmetic tweaks is
not a new attempt and is forbidden too.

## RESULT.md format

```markdown
# Result

## Task ID
<id>

## Status
DONE

## Summary
<2-6 sentences: what changed and why>

## Files Changed
- <path> - <one phrase>

## Behavior Changed
<what behavior is now different; "none" for investigate/verify>

## Acceptance Criteria
- [x] <criterion> - <how it was checked>
- [ ] ...

## Verification Performed
- <command> -> <result>

## Test Results
<pass/fail counts, failing names, or "no test suite present">

## Known Risks
<none | list>

## Remaining Questions
<none | list>

## Git Diff Summary
<output of git diff --stat>
```

## ESCALATION.md format

```markdown
# Escalation

## Task ID
<id>

## Goal
<what the Task asked for>

## Current Blocker
<the single thing that stops progress>

## Attempt 1
<approach, command/evidence, why it failed>

## Attempt 2
<different approach, command/evidence, why it failed>

## Evidence
<commands run + key outputs, trimmed to the essential lines>

## Relevant Files
- <path> - <why it matters>

## Current Hypotheses
<what you believe is true and what you cannot verify>

## Supervisor Decision Needed
<the exact decision or permission required>

## Recommended Next Action
<your best proposal, clearly marked as a proposal>
```

## What must never appear in reports

- chain-of-thought / internal reasoning
- full model transcripts
- thousands of lines of terminal logs
- restatements of the whole project
- plans for future Tasks or Phases

Only keep facts a Supervisor needs to review the Task.
