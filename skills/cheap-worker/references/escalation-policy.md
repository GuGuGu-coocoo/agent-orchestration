# Escalation Policy

## Principle

The worker is paid to finish ordinary work, not to be brave. Escalation is a
successful outcome when the Task genuinely needs a Supervisor decision.

## Escalate immediately (do not attempt a fix first)

- The Task requires modifying a public API, database schema, or data format
  that the Task does not explicitly authorize.
- The Task requires deleting/weakening tests, or the only way to pass is to
  hardcode a value.
- Two genuinely different attempts have failed.
- The Task contradicts `AGENTS.md`, `Forbidden Changes`, or the safety policy.
- The Task needs product intent, naming/branding decisions, or roadmap changes.
- The Task turns out to be multiple Tasks (scope explosion).
- Credentials, secrets, or production systems are involved.
- The acceptance criteria are mutually contradictory or impossible (for
  example: a frozen test fixture asserts behavior that the Task asks to change).

## Do not escalate for

- A compile error, typo, missing import, or failing test you can debug.
- An unclear variable name you can decide within `Allowed Changes`.
- A tool that needs a slightly different invocation.
- Missing optional context you can find by reading the repo.

## Attempt budget

```
Attempt 1 -> fails -> Attempt 2 (genuinely different) -> fails -> ESCALATE and stop
```

"Genuinely different" means a different hypothesis or mechanism, not a re-run
with a tweak. Maximum two approaches. Evidence of both attempts goes into
`ESCALATION.md`.

## After escalating

- Write `.agent/current/ESCALATION.md`.
- Stop. Do not keep editing "just in case".
- Do not commit, stash, or clean up the working tree.
- Leave the repository in a state where a human can inspect the evidence.

## Supervisor handling (phase-runner side)

- Technical/architectural problem -> Supervisor solves it, rewrites the Task,
  re-runs the worker.
- True product decision -> Supervisor asks the human, with a recommendation.
- Repeated escalation on the same Task -> split the Task or change the approach;
  never just re-send the identical Task.
