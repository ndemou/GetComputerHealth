# Tests

This repo uses direct PowerShell scripts as its test harness. It is intentionally simple.

## Entry Points

- Run everything: `.\tests\run-all-tests.ps1`
- Run only unit-like checks: `.\tests\run-all-tests.ps1 -Category Unit`
- Run only integration-like checks: `.\tests\run-all-tests.ps1 -Category Integration`
- Run the fastest low-risk smoke check: `.\tests\run-all-tests.ps1 -Smoke`
- Show more detail: add `-Detailed`

## Test Types

- Unit-like tests:
  Fast deterministic checks that do not need broad machine state. Right now this is mainly the `Resolve-ExecutablePath` suite.

- Integration-like tests:
  Checks that touch real services, real filesystem paths, installer behavior, or larger end-to-end flows.

## Rules For New Tests

1. Put standalone script tests in `tests\` and name them `test-*.ps1`.
2. Do not name helper files `test-*.ps1`.
3. Fail by throwing an exception with a direct message.
4. Prefer shared helpers from [`test-helpers.ps1`](C:/Users/NickDemou/dev/GetComputerHealth/tests/test-helpers.ps1).
5. Use a unique temp run root when a test writes files.
6. Clean up created temp content in a `finally` block.
7. Check prerequisites explicitly near the top of the script.
8. Keep smoke checks fast and low-risk.

## Current Conventions

- Shared assertions and path helpers live in [`test-helpers.ps1`](C:/Users/NickDemou/dev/GetComputerHealth/tests/test-helpers.ps1).
- Failure logs from the runner are written under `tests\artifacts\last-run\`.
- The runner excludes `test-helpers.ps1` from test discovery.

## Non-Goals

- No requirement to migrate to Pester now.
- No requirement for mocking or structured reports right now.
- Keep the system script-first and easy to debug.
