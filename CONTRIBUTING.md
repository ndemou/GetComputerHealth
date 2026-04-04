# Contributing

This project is intentionally small and script-first. Contributions should preserve that style: direct PowerShell, minimal abstraction, and behavior that is easy to debug on a real Windows machine.

This guide is for contributors. If you want to add your own out-of-tree checks as a user, use [`doc/how-to-add-custom-tests.md`](./doc/how-to-add-custom-tests.md) instead.

## Environment

- Primary target environment: Windows
- Preferred shell for development and CI: Windows PowerShell 5.1
- CI runner: GitHub Actions on `windows-2022`

The codebase is Windows-specific in important places. Do not assume Linux compatibility.

## Repository Layout

- [`Get-ComputerHealth.ps1`](./Get-ComputerHealth.ps1): local runner on the target host
- [`Invoke-GetComputerHealth.ps1`](./Invoke-GetComputerHealth.ps1): orchestration entry point
- [`Update-GetHealthCode.ps1`](./Update-GetHealthCode.ps1): updater/installer
- [`health-tests`](./health-tests): built-in `HealthTest-*` functions
- [`tests`](./tests): script-based test harness and standalone tests
- [`.github/workflows/tests.yml`](./.github/workflows/tests.yml): CI workflow

## Development Workflow

1. Make the smallest coherent change you can.
2. Run the relevant local tests.
3. If you touched shared behavior, run the full suite.
4. Keep side effects explicit and test-scoped.
5. Prefer readable PowerShell over clever PowerShell.

## Testing

The repository uses a direct PowerShell test harness, not Pester.

### Main Commands

- Run everything:
  `.\tests\run-all-tests.ps1`
- Run everything with more detail:
  `.\tests\run-all-tests.ps1 -Detailed`
- Run unit-like checks only:
  `.\tests\run-all-tests.ps1 -Category Unit`
- Run integration-like checks only:
  `.\tests\run-all-tests.ps1 -Category Integration`
- Run the fastest low-risk smoke set:
  `.\tests\run-all-tests.ps1 -Smoke`

### Test Categories

- Unit-like:
  Fast deterministic checks with limited machine coupling. Right now this is mainly the `Resolve-ExecutablePath` suite.
- Integration-like:
  Checks that touch real services, installer behavior, or broader filesystem / machine state.

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

If you want to contribute a built-in check that ships in `health-tests\*.ps1` and appears in `-ListAllBuiltInTests`, follow the rules below.

### Function Shape

Use the structure and surrounding style of nearby tests in the same file.

```powershell
function HealthTest-YourTestName {
<#
.SYNOPSIS
Short purpose and key signal logic.

.DESCRIPTION
AppliesTo: Server
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Some-Cmdlet
#>
    # gather data
    # evaluate
    # emit findings
}
```

Use PascalCase after the `HealthTest-` prefix, for example `HealthTest-PagefileSanity`.

### Required Help Block

Every built-in `HealthTest-*` function must include an in-function comment-based help block immediately after the opening `{`.

Rules:
- `.SYNOPSIS` is mandatory and must be 320 characters or fewer.
- `.DESCRIPTION` is mandatory and must be 900 characters or fewer.
- Do not add extra help sections such as `.PARAMETER`, `.OUTPUTS`, or `.EXAMPLE`.

Inside `.DESCRIPTION`, use plain text with one field per line in this exact order:

1. `AppliesTo:` one of `All`, `VM`, `Mobile`, `DomainJoined`, `Server`, `Workstation`, `DC`, `PDC`
2. `Scope:` one of `Computer`, `Domain`, `Forest`
3. `Category:` primary plus optional secondary category
4. `Impact:` `Medium` or `High`, with resource dimension if needed, such as `CPU`, `Disk`, `Network`, `Time`
5. `Uses:` up to three essential external cmdlets/executables, or `Uses: None.`
6. `FalsePositives:` optional short note

Allowed `Category` values:
- `Availability / Server Down Signals`
- `Security & Stability Risks`
- `Configuration Hygiene & Best Practices`
- `Audit / Compliance / Informational`

### Behavior Rules

- Keep side effects at zero.
  Health tests should inspect and report, not change machine state.
- Report through the framework’s expected message pattern.
  Follow nearby built-in tests and emit stable suppression-friendly messages.
- Keep stable identity in the main message.
  Put volatile details in comment/detail text rather than changing the stable signature each run.
- Be explicit about scope and prerequisites.
  If a test only applies to DCs, domain-joined machines, laptops, and so on, short-circuit early.
- Catch exceptions only when you can recover or downgrade cleanly.
  Otherwise let the framework report the thrown error.

### Tags In Test Names

You can attach tags directly in the function name by adding `__` and one or more letters or digits after the base name.

Examples:
- `HealthTest-SomeName__SP`
- `HealthTest-LargeDirectories__S`

Supported tags:
- `S`: Slow test, skipped by `-SkipSlowTests`
- `E`: Quick and essential test
- `P`: Policy inventory test
- `D`: Domain-wide test, reserved and not yet in use

### Policy Inventory Tests

Use the `P` tag for tests that inventory a system aspect where current state may be accepted as baseline.

Examples include:
- open ports
- installed software
- enabled services

Special handling on first run:
- if `-DontAutosetPolicy` is not used, the first run automatically suppresses `[warning]` and `[notice]` findings from that policy test
- `[failure]` findings are not auto-suppressed
- a marker line is appended to `Get-ComputerHealth.sigs-to-suppress.txt` so future runs are treated normally

### Placement

Append the function to the most suitable script under [`health-tests`](./health-tests). Those files are grouped by topic.

### Local Validation

Useful local loop while iterating:

```powershell
C:\IT\bin\Get-ComputerHealth.ps1 -OnlyTheseTests HealthTest-YourTestName -OutputConsoleMessages -OutputObjects -Hide DIP
C:\IT\bin\Get-ComputerHealth.ps1 -ListAllBuiltInTests
```

Also run the repository test harness when your change affects shared behavior:

```powershell
.\tests\run-all-tests.ps1
```

## Documentation Expectations

When contributor-facing behavior changes, update the relevant docs:
- this file for contributor workflow, CI, and testing
- [`README.md`](./README.md) for user-facing usage
- keep [`doc/how-to-add-custom-tests.md`](./doc/how-to-add-custom-tests.md) focused on users writing custom tests

## Non-Goals

These are not current project goals:
- migrating the test harness to Pester
- hiding Windows-specific assumptions
- making health tests mutate machine state
- replacing simple scripts with a heavy framework
