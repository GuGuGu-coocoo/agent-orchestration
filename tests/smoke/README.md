# Smoke tests

All tests build throwaway git repositories under the system temp directory. They
never read or modify a real project, and they run the scripts from **this
repository** (`skills/*/scripts`), not from `~/.agents/skills`, so a development
checkout is verified before it is installed. Nothing is installed by the tests and
nothing is committed to this repository.

| Script | What it covers | Model calls |
| --- | --- | --- |
| `run-offline.sh` | script-level contracts with fake workers: doctor, frontmatter, fail-fast, dry-run, status, collect-result, archive, notify (task and `--phase` wording, fake-codex delivery, NOTIFY_FAILED hints, exit 14/15, detached notify, session identity), the run-worker safety harness (fake opencode: report validation, stale-report quarantine, lock identity incl. surviving worker pid and `--break-lock`, **real SIGTERM cancellation keeps the lock**, TASK.md + REVIEW.md validation, dirty baseline, cwd pinning), **the phase loop end to end against a fake worker** (A auto-continue over three Tasks, B guarded/checkpoint stops, C escalation stop + blocking, D failing phase verification, E review/human gates, F resume + stale-report quarantine), the evidence gate (verification re-run, diff scope, unticked criteria, Supervisor-artifact tampering), plan validation, the check-state fail-closed matrix for the new states, phase-gate refusals, install/uninstall boundaries | no |
| `run-a-single-task.sh` | A: one implement Task ("hello" -> "hello worker"): edit, run, verify, RESULT.md, clean diff | yes |
| `run-b-investigate.sh` | B: investigate mode: finding reported, zero business code changes | yes |
| `run-c-escalation.sh` | C: a genuinely contradictory frozen stdout test forces ESCALATION.md, no edits, exit 10 (the fixture is proven contradictory before the run) | yes |
| `run-d-phase-runner.sh` | D: three bounded Tasks executed by the real `run-phase.sh` with the real model - one OpenCode session each, evidence gate per Task, automatic continuation, STOP at `awaiting_phase_review`, `phase-gate.sh review-pass` -> `awaiting_human_qa`, loop refuses to run, `qa-pass` records the human verdict | yes |
| `run-e-resume.sh` | F: an interrupted `in_progress` Task is resumed by the real loop (A01 never re-run, blank TASK.md rebuilt from the queue, stale report quarantined), then A03 continues automatically to `awaiting_phase_review` | yes |
| `run-live.sh` | convenience wrapper: `a`, `b`, `c`, `d`, `e`, or all | - |
| `run-all.sh` | offline, then all live | - |

## Environment notes

The suite creates throwaway repos and commits fixtures in them. If the sandbox
refuses to create commits (a gated `git` shim), the two assertions that need a real
`HEAD` are reported as `SKIP` instead of failing - the summary line then reads
`N passed, M failed, K skipped`. Everything else must still pass.

## Running

```sh
tests/smoke/run-offline.sh
tests/smoke/run-all.sh
tests/smoke/run-live.sh d
tests/smoke/run-live.sh e

# keep the generated repos for inspection
SMOKE_KEEP_REPOS=1 tests/smoke/run-live.sh
```

Live tests use OpenCode's configured default model (there is no test-side model
override). If your default model is not reachable, live tests fail with the
provider error - that is the same behavior the worker would have.

To run live tests against a specific model without changing your global config,
point `TMPDIR` at a directory with a project-local OpenCode config (OpenCode's
config discovery walks up from each repo):

```sh
mkdir -p /tmp/oc-live/.opencode
printf '{"model":"<provider/model>"}' > /tmp/oc-live/.opencode/opencode.json
TMPDIR=/tmp/oc-live tests/smoke/run-live.sh
```

This is test scaffolding only - the worker itself never passes `--model`.

Outputs (worker JSON event logs, loop logs, doctor output) land in
`tests/smoke/.out/` and can be deleted at any time.

Each worker run creates one titled OpenCode session (`cheap-worker · <task> · ...`)
on the shared background service, so live test runs are also visible in OpenCode
Desktop.

## What the tests do and do not prove

- The offline suite proves what the **scripts** do: the evidence gate, the state
  machine, the stops, the resume. It uses a deterministic fake worker, so it says
  nothing about model quality.
- The live suite proves that the same flow works with a real model, one session
  per Task.
- Neither proves that Codex follows `phase-runner/SKILL.md`; that text is reviewed
  by reading it. The scripts enforce the parts that must not depend on discipline:
  no per-Task review, the `awaiting_phase_review` -> `awaiting_human_qa` gates, and
  the refusal to start the next Phase.
