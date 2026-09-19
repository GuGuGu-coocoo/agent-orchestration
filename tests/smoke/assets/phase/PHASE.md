# Phase A

## Objective
Complete the greeting utility: uppercase, shutdown, farewell.

## Existing State
app.py defines uppercase() only. test_app.py is a frozen acceptance suite.

## Target State
app.py implements uppercase(), shutdown(seconds) and farewell(name); test_app.py passes.

## Scope
- app.py additions for A02 and A03

## Non-Goals
- packaging, CLI, anything in Phase B

## Phase Acceptance Criteria
- [ ] python3 test_app.py passes
- [ ] all three functions behave as specified

## Required Phase Verification
- `python3 test_app.py` - exits 0 with "test_app: OK"

## Human QA Required
- run `python3 test_app.py` manually and confirm output

## Result
<!-- written at phase completion -->
