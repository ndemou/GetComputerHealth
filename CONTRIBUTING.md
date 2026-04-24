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
  Fast deterministic checks with limited machine coupling. Right now this is mainly the `Resolve-ExecutablePath` Pester suite.
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
...(see Required Help Block)
#>
    # gather data
    # evaluate
    # emit findings
}
```

Use PascalCase after the `HealthTest-` prefix, for example `HealthTest-PagefileSanity`.

### Required Help Block

Every built-in `HealthTest-*` function must include an in-function comment-based help block with standarized `field: value` lines immediately after the opening `{`.

Example:
```
function HealthTest-LargeDirectories {
<#
Description: Finds directories with more than 10000 files.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Time), Medium(Disk)
Tags: Essential
Uses: Get-ChildItem.

<OPTIONAL DETAILED DESCRIPTION>
<...>
#>
...
```

The `Field: Value` lines follow this exact order (note that some are optional):
   1. `Description:` What kind of issues it detects or what findings it uncovers (160 chars max).
   2. `AppliesTo:`. Options are `All`, `VM`, `Mobile`, `DomainJoined`, `Server`, `Workstation`, `DC`, `PDC`
   3. `Scope:`. Options are `Computer`, `Domain`, `Forest`
   4. `Category:` primary plus optional secondary category. Options are: `Availability/Server Down Signals`,`Security & Stability Risks`,`Configuration Hygiene & Best Practices`,`Audit/Compliance/Informational`
   5. `Impact:` either "low" if there's low impact on all dimensions, or one or more "<level>(<dimension>)" pairs where <lever> is either "Medium" or "High" and  dimension is one of "CPU","Disk","Network","RAM","Time"
   6. `Tags:` optional comma-separated values. Supported values: `Essential`, `Policy`.
   7. `Uses:` optional, up to three essential external cmdlets or executables if any.
   8. `FalsePositives:` optional short note only if False Positives are to be expected

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

### Tags In Help Blocks

Tag health tests using the `Tags:` field in the in-function help block.

Examples:
- `Tags: Essential`
- `Tags: Essential, Policy`

Supported tags:
- `Essential`: quick and essential test
- `Policy`: policy inventory test

Slow tests are indicated by impact (`Impact: ... High(Time)`), and `-SkipSlowTests` uses that impact marker.

### Policy Inventory Tests

Use `Tags: Policy` for tests that inventory a system aspect where current state may be accepted as baseline. For example:
- Open ports
- Installed software
- Enabled services

Health tests with this tag have special handling on first run:
- The first run automatically suppresses `[WARNING]` and `[NOTICE]` findings from that policy test (except if `-DontAutosetPolicy` is used)
- `[FAILURE]` findings are not auto-suppressed
- A flag is appended to `Get-ComputerHealth.sigs-to-suppress.txt` so future runs are treated normally

### Placement

Append the function to the most suitable script under [`health-tests`](./health-tests). Those files are grouped by topic.

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
- keep [`doc/how-to-add-custom-tests.md`](./doc/how-to-add-custom-tests.md) focused on users writing custom tests

## Non-Goals

These are not current project goals:
- hiding Windows-specific assumptions
- making health tests mutate machine state
- replacing simple scripts with a heavy framework
