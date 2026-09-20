# Testing

[← Back to README](../../README.md) · [简体中文](../zh-CN/testing.md) · [Français](../fr/testing.md)

How this project is verified, what the suites prove, and what they deliberately
do not.

## The offline suite

```sh
tests/smoke/run-offline.sh                  # no model calls, no credentials (~380 checks)
```

`tests/smoke/` creates throwaway git repositories under the system temp
directory and runs the scripts from **this source tree** — never from
`~/.agents/skills`, so a development checkout is verified before it is
installed. Nothing is installed, and no real project is touched.

The offline suite drives every script with a **deterministic fake worker**, so
it needs no model, no credentials and no network. It covers:

- the doctor, the SKILL.md frontmatter, and the guarantee that no script ever
  passes `--model` or `--standalone`;
- the run-worker safety harness: report validation, stale-report quarantine,
  lock identity (including a surviving worker pid and `--break-lock`), real
  `SIGTERM` cancellation keeping the lock, TASK.md/REVIEW.md validation, dirty
  baselines, cwd pinning;
- **the Phase loop end to end** against the fake worker: auto-continue over
  three Tasks, guarded/checkpoint stops, an escalation stop, a failing Phase
  verification, the review and human gates, and resume;
- the evidence gate itself: verification re-runs, diff scope, unticked criteria,
  and Supervisor-artifact tampering;
- the `check-state.sh` fail-closed matrix;
- install/uninstall boundaries, including a fixture-HOME proof that the
  installer leaves other skills byte-identical.

It needs `opencode` on `PATH`, because `doctor.sh` checks the real CLI. It makes
no model calls.

## The live suite

```sh
tests/smoke/run-live.sh                     # all live tests (OpenCode default model)
tests/smoke/run-live.sh d                   # one suite (a, b, c, d, e)
SMOKE_KEEP_REPOS=1 tests/smoke/run-live.sh  # keep the generated repos
```

Live tests use OpenCode's configured default model — there is no test-side model
override, exactly like the worker itself. They retry transient provider quota
errors (HTTP 429) and otherwise fail loudly; they never silently pass.

| Suite | What it proves |
| --- | --- |
| `a` | one implement Task end to end: edit, run, verify, RESULT.md, clean diff |
| `b` | investigate mode: a finding reported, zero business-code changes |
| `c` | a genuinely contradictory frozen test forces `ESCALATION.md`, no edits, exit 10 |
| `d` | three bounded Tasks through the real `run-phase.sh` with the real model: one session each, evidence gate per Task, automatic continuation, STOP at `awaiting_phase_review`, then the review and QA gates |
| `e` | an interrupted `in_progress` Task is resumed by the real loop (done Tasks never re-run, blank TASK.md rebuilt, stale report quarantined) |

Each worker run creates one titled OpenCode session on the shared background
service, so live test runs are also visible in OpenCode Desktop.

To run live tests against a specific model without touching your global config,
point `TMPDIR` at a directory with a project-local OpenCode config:

```sh
mkdir -p /tmp/oc-live/.opencode
printf '{"model":"<provider/model>"}' > /tmp/oc-live/.opencode/opencode.json
TMPDIR=/tmp/oc-live tests/smoke/run-live.sh
```

## What the suites do and do not prove

- The **offline suite** proves what the *scripts* do: the evidence gate, the
  state machine, the stops, the resume. It uses a fake worker, so it says
  nothing about model quality.
- The **live suite** proves that the same flow works with a real model, one
  session per Task.
- Neither proves that Codex *follows* `phase-runner/SKILL.md`; that text is
  reviewed by reading it. The scripts enforce the parts that must not depend on
  discipline: no per-Task review, the `awaiting_phase_review` →
  `awaiting_human_qa` gates, and the refusal to start the next Phase.

## CI

[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) runs the offline
suite on `ubuntu-latest` and `macos-latest` for every push and pull request. It
installs the real OpenCode CLI (the doctor checks it) and uploads
`tests/smoke/.out` as an artifact when a job fails.

The two runners cover both bash generations the project supports: bash 3.2 on
macOS and bash 5 on Linux.

## Environment notes

The suite creates throwaway repos and commits fixtures in them. If the sandbox
refuses to create commits (a gated `git` shim), the checks that need a real
`HEAD` are reported as `SKIP` instead of failing — the summary line then reads
`N passed, M failed, K skipped`. Everything else must still pass.

Outputs (worker JSON event logs, loop logs, doctor output) land in
`tests/smoke/.out/` and can be deleted at any time.
