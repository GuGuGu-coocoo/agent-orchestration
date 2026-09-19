# Task

## Task ID
<PHASE>-<NN>            <!-- e.g. C01 -->

## Mode
implement | investigate | fix | verify

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
- <exact files/directories the worker may modify>
- <what kinds of edits are expected>

## Forbidden Changes
- <paths or behaviors that must not change>
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
Rules for whoever writes this Task (Supervisor):
- One Task = one coherent change. Never a whole Phase.
- Keep it small enough for one cheap-worker run.
- Never write "and then decide what to do next" - decisions belong to the Supervisor.
-->
