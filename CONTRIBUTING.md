# Contributing

This project is intentionally small and script-first. Contributions should preserve that style: direct PowerShell, minimal abstraction, and behavior that is easy to debug on a real Windows machine.

This guide is for contributors. If you want to add your own out-of-tree checks as a user, see [`doc/user/custom-tests.md`](./doc/user/custom-tests.md) instead.

## Environment

- Primary target environment: Windows
- Preferred shell for development and CI: Windows PowerShell 5.1
- CI runner: GitHub Actions on `windows-2022`

The codebase is Windows-specific in important places. Do not assume Linux compatibility.

## Repository Layout

- [`Get-ComputerHealth.ps1`](./Get-ComputerHealth.ps1): local runner on the target host
- [`Invoke-GetComputerHealth.ps1`](./Invoke-GetComputerHealth.ps1): orchestration entry point
- [`Update-GetHealthCode.ps1`](./Update-GetHealthCode.ps1): updater/installer
- [`doc`](./doc): focused user, contributor, and design guides; start with [`doc/README.md`](./doc/README.md)
- [`health-tests`](./health-tests): built-in `HealthTest-*` functions and the helper code needed to run them
- [`tests`](./tests): script-based test harness and standalone tests
- [`.github/workflows/tests.yml`](./.github/workflows/tests.yml): CI workflow

## Development Workflow

1. Make the smallest coherent change you can.
2. Run the relevant local tests.
3. Start with fast unit tests, then smoke tests, then full machine tests only when needed.
4. Keep side effects explicit and test-scoped.
5. Prefer readable PowerShell over clever PowerShell.

## Testing

The repository uses a mixed testing model:

- unit-like tests use Pester
- integration-style validation remains script-based for now

### Main Commands

- Run fast unit tests first:
  `.\tests\run-unit-tests.ps1`
- Run the smoke set second:
  `.\tests\run-all-tests.ps1 -Smoke`
- Run integration-like checks only when you need broader validation:
  `.\tests\run-all-tests.ps1 -Category Integration`
- Run everything:
  `.\tests\run-all-tests.ps1`
- Run everything with more detail:
  `.\tests\run-all-tests.ps1 -Detailed`

### Test Categories

- Unit-like:
  Fast deterministic checks with limited machine coupling. This includes the repo-wide syntax pass, the ScriptAnalyzer wrapper, and the Pester suite.
- Integration-like:
  Checks that touch real services, installer behavior, or broader filesystem / machine state.

### Recommended Local Validation Order

1. `.\tests\run-unit-tests.ps1`
2. `.\tests\run-all-tests.ps1 -Smoke`
3. `.\tests\run-all-tests.ps1 -Category Integration` only when your change affects broader machine behavior
4. `.\tests\run-all-tests.ps1` when you want the whole repo check

### Test Conventions

- Put standalone script tests in `tests\` and name them `test-*.ps1`.
- Do not name helper files `test-*.ps1`.
- Fail by throwing an exception with a direct message.
- Prefer shared helpers from [`tests/test-helpers.ps1`](./tests/test-helpers.ps1).
- Use a unique temp run root when a test writes files.
- Clean up temporary content in a `finally` block.
- Check prerequisites explicitly near the top of the script.
- Keep smoke checks fast and low-risk.

### Test Harness Notes

- Shared assertions and path helpers live in [`tests/test-helpers.ps1`](./tests/test-helpers.ps1).
- Pester unit tests live under [`tests/Unit`](./tests/Unit).
- `.\tests\run-all-tests.ps1 -Smoke` includes the repo-wide syntax parser.
- `.\tests\run-all-tests.ps1` includes the syntax parser, ScriptAnalyzer, unit tests, service-resolution checks, and standalone `test-*.ps1` scripts.
- Failure logs from the runner are written under `tests\artifacts\last-run\`.
- The test runner excludes `test-helpers.ps1` from discovery.

## CI

GitHub Actions is configured in [`.github/workflows/tests.yml`](./.github/workflows/tests.yml).

- Pull requests run:
  `.\tests\run-all-tests.ps1 -Smoke`
- Pushes to `main` run:
  `.\tests\run-all-tests.ps1 -Detailed`
- Manual runs execute the full detailed suite as well.

If you change test entry points or required environment assumptions, update the workflow.

## Adding Built-In `HealthTest-*` Functions

If you want to contribute a built-in check that ships in `health-tests\*.ps1` and appears in `-ListAllBuiltInTests`, follow these guidelines:

- [`doc/user/custom-tests.md`](./doc/user/custom-tests.md) explains the user-facing custom-test model.
- [`doc/contributor/built-in-health-tests.md`](./doc/contributor/built-in-health-tests.md) contains the detailed built-in health-test conventions.

### Placement

All code needed to run built-in health tests, and only that code, belongs under [`health-tests`](./health-tests). If a helper is shared by `Get-ComputerHealth.ps1` and health tests, keep it under `health-tests` and dot-source it from the caller that needs it.

Every `HealthTest-*` function must live in its own `.ps1` file under `health-tests`, and the file name must match the function name, for example `health-tests\HealthTest-ScheduledTasks.ps1`.

Each same-name health-test file must be directly executable. A user who wants to run one specific built-in health test must be able to run only that `.ps1` file. To make this work, dot-source every dependency from the health-test file itself.

Use explicit conditional dependency declarations near the top of the file. Prefer this style for every needed helper function:

```powershell
if (-not (Get-Command -Name 'Get-ScheduledTaskFacts' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'ScheduledTaskHelpers.ps1')
}
```

At the end of the health-test file, execute the function only when the file was run directly rather than dot-sourced:

```powershell
if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-YourTestName
}
```

Existing grouped health-test files are being migrated incrementally. Do not add new `HealthTest-*` functions to grouped files.

### Helper Placement

Use these categories when placing helper functions:

- A specific health-test helper is needed by only one health test. Keep it in that health test's same-name `.ps1` file.
- A domain helper is needed by a class of domain-specific health tests. Put it in its own domain helper file under `health-tests`, for example `ScheduledTaskHelpers.ps1`.
- A generic helper is useful across unrelated health tests. Put it in `health-tests\helpers-for-healthtests.ps1`.

### Local Validation

Useful local loop while iterating:

```powershell
C:\IT\bin\Get-ComputerHealth.ps1 -OnlyTheseTests HealthTest-YourTestName -OutputConsoleMessages -OutputObjects -Hide DIP
C:\IT\bin\Get-ComputerHealth.ps1 -ListAllBuiltInTests
```

Also run the unit tests first when your change affects shared behavior:

```powershell
.\tests\run-unit-tests.ps1
```

Then run broader validation when needed:

```powershell
.\tests\run-all-tests.ps1
```

## Documentation Expectations

When contributor-facing behavior changes, update the relevant docs:
- this file for contributor workflow, CI, and testing
- [`README.md`](./README.md) for user-facing usage
- keep [`doc/user/custom-tests.md`](./doc/user/custom-tests.md) focused on users writing custom tests
- keep [`doc/README.md`](./doc/README.md) current when adding, moving, or changing ownership of Markdown docs

Use the documentation map as the source of truth for where durable documentation belongs. Avoid duplicating long guidance across files; link to the canonical document instead.

## Non-Goals

These are not current project goals:
- hiding Windows-specific assumptions
- making health tests mutate machine state
- replacing simple scripts with a heavy framework
