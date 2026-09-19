# Task

<!-- Rendered by phase-runner/scripts/run-phase.sh from the Phase's
     TASK_QUEUE.json. Do not hand-edit a rendered Task: change the queue entry
     instead, so the definition and what the worker saw stay identical. -->

## Task ID
<PHASE>-<NN>            <!-- e.g. C01 -->

## Mode
implement | investigate | fix | verify

## Risk
low | guarded      <!-- guarded: architecture / public API / schema / security /
                         deployment. The loop stops for a Codex review right
                         after a guarded Task is accepted. -->

## Objective
<one or two sentences: what must be true when this Task is done>

## Context
<why this Task exists now; 2-5 bullet lines max. No roadmap dump.>

## Existing Behavior
<what the system does today, observed - not assumed>

## Desired Behavior
<what it must do after this Task>

## Relevant Files
- <path> - <why it matters>

## Allowed Changes
- <exact files/directories/globs the worker may modify; the evidence gate checks the diff against this list>
- <what kinds of edits are expected>

## Forbidden Changes
- <paths or globs that must not change>
- <defaults: public API, schema, data formats, unrelated files, tests deletion>

## Acceptance Criteria
- [ ] <observable, checkable criterion>
- [ ] <observable, checkable criterion>

## Required Verification
- <exact commands to run, e.g. `python3 -m pytest -q`>
- <expected result, e.g. all tests pass>

## Escalation Conditions
- <condition that must stop the worker and produce ESCALATION.md>
- <defaults: needs public API change, needs schema change, 2 attempts failed>

<!--
Rules for whoever writes this Task (Codex, in the queue):
- One Task = one coherent change with one verification story. Never a whole Phase.
- The Required Verification commands are machine-read by run-phase.sh: they must
  be exact, non-interactive, and fast enough to re-run.
- Never write "and then decide what to do next" - decisions belong to Codex.
-->
