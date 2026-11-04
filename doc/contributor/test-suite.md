# Test Suite Guide

*(Information for developers only)*

This guide explains the test and validation scripts in this repository in simple language.

For the full documentation routing table, see [`README.md`](../README.md).

Run the commands below from the repository root in Windows PowerShell 5.1. The unit suite requires Pester 5 or newer. The full suite and `-Category Unit` also call PSScriptAnalyzer; install that module before using its results.

It is written for:

- human contributors
- LLM agents
- PowerShell beginners who want to know which script to run and why

## Big Picture

This repo uses two main testing styles:

- Pester unit tests for fast, focused checks
- standalone PowerShell test scripts for broader real-world validation

Some checks are fully isolated and deterministic.

Some checks depend on the local machine, the filesystem, installed services, or the installer/update flow.

Routine unit, smoke, and integration checks must not enable `-IReallyWantToRunTestsThatChangeState`. Mock active operations or use a dedicated test computer when active validation is explicitly required. Integration checks still make diagnostic queries and create temporary installation files; they are not isolated unit tests.

Because of that, the normal order is:

1. `.\tests\run-unit-tests.ps1`
2. `.\tests\run-all-tests.ps1 -Smoke`
3. `.\tests\run-all-tests.ps1 -Category Integration` when needed
4. `.\tests\run-all-tests.ps1` when you want the full set

## Main Test Commands

### `.\tests\run-unit-tests.ps1`

This is the fastest normal test command.

What it does:

- checks that Pester 5 or newer is installed
- loads Pester
- runs all tests under [`tests/Unit`](../../tests/Unit)

Use it when:

- you changed a small piece of logic
- you changed a helper function
- you added or edited a Pester test
- you want quick feedback before doing anything slower

Do not expect it to:

- test the full installer flow
- test broader machine-coupled behavior
- validate the whole repo end to end

This should usually be your first test run.

### `.\tests\run-all-tests.ps1 -Smoke`

This is the quick “broader confidence” command.

What it does:

- runs the repo-wide PowerShell syntax pass
- runs the unit test suite
- runs a small standalone integration-style test set
- currently includes the installer packaging/update check

Use it when:

- you changed installer or updater behavior
- you changed package layout assumptions
- you changed service or environment-sensitive code and want more than unit coverage
- you want a quick second step after unit tests

This is the best balance between speed and coverage for many changes.

### `.\tests\run-all-tests.ps1 -Category Integration`

This runs the broader integration-like checks only.

What it does:

- runs machine-coupled validation
- runs standalone `test*.ps1` scripts in [`tests`](../../tests), excluding `test-helpers.ps1`
- runs the real-service executable resolution check

Use it when:

- you changed service path resolution
- you changed installer/update behavior
- you changed code that depends on the real machine state
- you need broader validation than smoke mode

This can be slower and more environment-sensitive than the unit suite.

`-Category Integration` does not run the syntax parser, ScriptAnalyzer, or Pester. Run smoke or unit coverage separately when those checks are needed.

### `.\tests\run-all-tests.ps1`

This is the main “run everything in the normal suite” command.

What it does:

- runs repo-wide syntax validation
- runs the ScriptAnalyzer wrapper; inspect individual findings with the direct command described below
- runs unit-like coverage
- runs integration-like coverage
- combines the checks from both categories

Use it when:

- you want broad local confidence before pushing
- your change touches several parts of the repo
- you want to exercise the standard combined test path

### `.\tests\run-all-tests.ps1 -Detailed`

This is the same broad suite, but with more output. `-Detailed` can also be combined with `-Smoke` or `-Category` without changing their selection.

What it does:

- runs the same combined test selection
- prints extra detail
- prints artifact/log locations for failures

Use it when:

- a test failed and you want better visibility
- you want easier troubleshooting
- you want the closest local view to the detailed CI path

### Selection reference

| Command | Syntax | ScriptAnalyzer wrapper | Pester | Real-service resolution | Standalone scripts |
| --- | --- | --- | --- | --- | --- |
| `run-unit-tests.ps1` | No | No | Yes | No | No |
| `run-all-tests.ps1 -Smoke` | Yes | No | Yes | No | Installer only, two versioned-zip scenarios |
| `run-all-tests.ps1 -Category Unit` | Yes | Yes | Yes | No | No |
| `run-all-tests.ps1 -Category Integration` | No | No | No | Yes | All, including versionless-zip installer scenario |
| `run-all-tests.ps1` | Yes | Yes | Yes | Yes | All, including versionless-zip installer scenario |

`-Smoke` takes precedence over `-Category` if both are supplied. The real-service check is skipped whenever `GITHUB_ACTIONS` equals `true`.

## What `run-all-tests.ps1` Actually Runs

The main runner groups its work into a few buckets.

### 1. Repo syntax parser pass

This is the `Repo PowerShell syntax` test group inside the runner.

In practice, it calls [`scripts/syntax/Test-RepoPowerShellSyntax.ps1`](../../scripts/syntax/Test-RepoPowerShellSyntax.ps1), which parses repository PowerShell files and reports syntax errors.

Use this group when:

- you changed many `.ps1` files
- you renamed or moved scripts
- you want a fast repo-wide parser sanity check

### 2. ScriptAnalyzer wrapper

This is the `ScriptAnalyzer` test group inside the runner.

In practice, it calls [`tests/script-analysis.ps1`](../../tests/script-analysis.ps1), which runs `Invoke-ScriptAnalyzer -Path .\ -Severity Error` without `-Recurse`, checking the current directory rather than every repository subdirectory. The wrapper does not throw when findings exist. The main runner also discards the individual diagnostic objects while keeping the wrapper's final success value, so it can print an error banner and still mark the group passed. Run `.\tests\script-analysis.ps1` directly from the repository root to inspect the findings.

Use this group when:

- you want static-analysis feedback as part of the normal suite
- you changed script structure or patterns that may trip analyzer rules

### 3. Unit runner

This is the `Pester unit suite` test group inside the runner.

In practice, it calls [`tests/run-unit-tests.ps1`](../../tests/run-unit-tests.ps1), which runs the Pester unit tests under [`tests/Unit`](../../tests/Unit).

Use this group when:

- you changed small pieces of PowerShell logic
- you changed parsing or path-resolution behavior
- you changed code already covered by the Pester tests

### 4. Real service executable resolution check

This is the `Resolve-ServiceExecutable` group inside [`tests/run-all-tests.ps1`](../../tests/run-all-tests.ps1).

What it does:

- loads code from [`health-tests/helper-regarding-service-and-executable-resolution.ps1`](../../health-tests/helper-regarding-service-and-executable-resolution.ps1)
- enumerates real Windows services with `Get-CimInstance Win32_Service`
- checks whether service executable paths can be resolved correctly on the current machine

Use it when:

- you changed service path parsing logic
- you changed `Resolve-ServiceExecutable`
- you changed logic that must work against real installed services

Important note:

- this is machine-coupled
- it is skipped when `GITHUB_ACTIONS` is `true`, including self-hosted Actions jobs
- it is not part of smoke mode

### 5. Standalone script tests

The runner also executes files matching `test*.ps1` directly under [`tests`](../../tests), explicitly excluding `test-helpers.ps1`. New helpers must not use names that match this discovery pattern.

These are script-based integration-style tests.

Failures caught by this standalone runner are saved under `tests\artifacts\last-run\`. The directory is reset at the start of each main-runner invocation. The other test groups report to the console and do not use this failure-log path.

## Standalone Test Scripts

### [`tests/test-installer.ps1`](../../tests/test-installer.ps1)

This is the most important installer/update validation script.

What it does:

- creates a temporary test area
- copies the repo into that area and builds a zip package from the source checkout
- invokes `Update-GetHealthCode.ps1` from a temp install location or from the repo with an explicit test installation root
- runs the updater against the generated zip
- checks legacy custom-script migration and the persisted disk-format version
- cleans up its per-scenario temporary directories and archives in `finally`

Why it matters:

- it checks that the repo can be packaged correctly
- it checks that the updater can consume that package
- it protects the packaging and update flow from regressions

Use it when:

- you changed `Update-GetHealthCode.ps1`
- you changed installer or updater behavior
- you changed release/package layout assumptions
- you changed zip-related logic

Important note:

- this script is included in smoke mode
- it always checks a versioned zip with both installation-root approaches
- full and integration runs also enable the versionless-zip scenario with an explicit `-Version`
- to include that third scenario when running the script directly, use `.\tests\test-installer.ps1 -IncludeVersionlessZipScenario`
- zip creation stages files in a temporary sibling of the source checkout, so that parent directory must also be writable

### [`tests/test-Get-ComputerHealth.ps1`](../../tests/test-Get-ComputerHealth.ps1)

This is a broader “does the main script still run sanely?” check.

What it does:

- creates a temporary test area
- copies the repo into a temp install location
- runs `Get-ComputerHealth.ps1`
- uses `-RunWithoutElevation`
- excludes some slower or more environment-sensitive health tests
- fails if the script throws
- fails if output contains “program error” findings
- expects a large amount of output so the run is not silently incomplete

Why it matters:

- it checks the main script as a whole, not just one small helper
- it catches startup or orchestration problems
- it gives confidence that the main script still produces a substantial result set

Use it when:

- you changed `Get-ComputerHealth.ps1`
- you changed how health tests are orchestrated
- you changed output generation
- you want broader validation beyond smoke mode

Important note:

- this is broader and slower than the installer smoke test
- it is not part of the smoke selection

## Pester Unit Tests

These live under [`tests/Unit`](../../tests/Unit).

### [`tests/Unit/Resolve-ExecutablePath.Tests.ps1`](../../tests/Unit/Resolve-ExecutablePath.Tests.ps1)

This test file checks executable path resolution behavior.

Examples it covers:

- quoted paths
- `%WINDIR%` expansion
- missing extensions such as `.exe` or `.bat`
- PATH lookup
- paths with spaces
- literal wildcard handling
- invalid path characters
- non-existent commands

Use it when:

- you changed executable path resolution logic
- you changed quoting behavior
- you changed PATH probing logic
- you changed related helper code in `helper-regarding-service-and-executable-resolution.ps1`

### [`tests/Unit/Invoke-GetComputerHealth.EmailSignature.Tests.ps1`](../../tests/Unit/Invoke-GetComputerHealth.EmailSignature.Tests.ps1)

This test file checks the email-signature helper functions in `reporting.ps1`, used by `Invoke-GetComputerHealth.ps1`.

Examples it covers:

- reading the version from a `VERSION` file
- falling back to the embedded script version
- using timestamps correctly
- appending signature text to plain text and HTML bodies

Use it when:

- you changed alert email formatting
- you changed version-signature behavior
- you changed email helper functions in `reporting.ps1`

### [`tests/Unit/HealthTest-ListInstalledPrograms.Classification.Tests.ps1`](../../tests/Unit/HealthTest-ListInstalledPrograms.Classification.Tests.ps1)

This test file checks how installed software entries are classified.

Examples it covers:

- detecting Microsoft update-like entries
- distinguishing updates from normal product installs
- assigning finding severity such as `info` vs `notice`

Use it when:

- you changed installed software classification logic
- you changed keyword rules for updates
- you changed severity mapping for these findings

### [`tests/Unit/HealthTestHelpBlock.Tests.ps1`](../../tests/Unit/HealthTestHelpBlock.Tests.ps1)

This test file checks contributor-facing structure rules for built-in `HealthTest-*` functions.

It verifies things like:

- each `HealthTest-*` function has a help block
- the help block is in the correct place
- the required fields exist
- the fields are in the correct order
- old legacy help-block style is not used there

Use it when:

- you add a new built-in `HealthTest-*` function
- you edit help blocks in `health-tests\*.ps1`
- you change contributor conventions for built-in health tests

This is a structure/quality check, not a runtime behavior check.

## Extra Validation Scripts

These scripts are useful. Both scripts below are now included by [`tests/run-all-tests.ps1`](../../tests/run-all-tests.ps1) in the full suite. The syntax pass is also included in smoke mode.

### [`scripts/syntax/Test-RepoPowerShellSyntax.ps1`](../../scripts/syntax/Test-RepoPowerShellSyntax.ps1)

Command:

```powershell
.\scripts\syntax\Test-RepoPowerShellSyntax.ps1
```

What it does:

- parses every `.ps1` file in the repo
- skips generated content under `.git` and `temp`
- reports syntax errors in a clear per-file format
- caches file timestamps and previous parse results
- only re-checks changed files on later runs

Use it when:

- you changed many PowerShell files
- you did a broad refactor
- you want a repo-wide syntax sanity check
- an LLM made widespread edits and you want a fast parser-based review

This is a very useful safety net because syntax errors can appear in files that do not yet have dedicated runtime tests.

### [`tests/script-analysis.ps1`](../../tests/script-analysis.ps1)

What it does:

- runs `Invoke-ScriptAnalyzer` against the current directory without recursion
- reports errors from ScriptAnalyzer
- ignores one specific rule: `PSAvoidUsingConvertToSecureStringWithPlainText`
- prints matching findings without turning them into a failed test group

Use it when:

- you want static-analysis feedback
- you are cleaning up PowerShell quality issues
- you want rule-based feedback in addition to parser-based syntax checks

Important note:

- PSScriptAnalyzer must be available. Run `.\tests\script-analysis.ps1` directly to review its diagnostic rows even when the main runner exits successfully.

## Support Files Used by Tests

### [`tests/test-helpers.ps1`](../../tests/test-helpers.ps1)

This is a shared helper module for standalone script tests.

It provides things like:

- assertions
- temp test-root creation
- standard test paths
- cleanup helpers

Use it when:

- you add a new `test-*.ps1` file
- you need repeatable temporary test setup
- you want to follow existing standalone test style

### [`tests/helpers-files.ps1`](../../tests/helpers-files.ps1)

This file contains file and zip helpers used by tests.

It provides things like:

- zip creation helpers
- file-copy utilities
- packaging helpers used by installer-related tests

Use it when:

- you write a packaging test
- you need zip-based setup in a standalone test

## How To Choose The Right Test

If you changed only a small helper or a small logic branch:

- run `.\tests\run-unit-tests.ps1`

If you changed installer, updater, packaging, or release behavior:

- run `.\tests\run-unit-tests.ps1`
- then run `.\tests\run-all-tests.ps1 -Smoke`
- often also run `.\tests\run-all-tests.ps1 -Category Integration`

If you changed service executable resolution:

- run `.\tests\run-unit-tests.ps1`
- then run `.\tests\run-all-tests.ps1 -Category Integration`

If you changed built-in `HealthTest-*` functions:

- run `.\tests\run-unit-tests.ps1`
- if the change depends on real machine behavior, also run broader integration checks

If you changed `Get-ComputerHealth.ps1` orchestration or output flow:

- run `.\tests\run-unit-tests.ps1`
- then run `.\tests\run-all-tests.ps1`

If you changed many `.ps1` files or did a broad refactor:

- run `.\tests\run-all-tests.ps1 -Smoke`
- then run `.\tests\run-all-tests.ps1`

If you are preparing a release:

- run `.\tests\run-unit-tests.ps1`
- run `.\tests\run-all-tests.ps1 -Smoke`
- run broader integration coverage if the release touches machine-coupled behavior
- use [`scripts/release/New-GetComputerHealthRelease.ps1`](../../scripts/release/New-GetComputerHealthRelease.ps1) for the release workflow itself
