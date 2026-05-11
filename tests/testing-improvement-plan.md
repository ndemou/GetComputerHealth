# Test Improvement Plan

This repo does not need a full testing framework migration right now. The current script-based approach is acceptable, but a few small changes would make it materially better in reliability, maintainability, diagnostics, and day-to-day usage.

## Goal

Keep the current "run PowerShell scripts directly" model, but make failures easier to trust, easier to debug, and less dependent on one specific machine state.

## Phase 1: Make Test Results More Consistent

1. Standardize pass/fail behavior across all tests.
   Every test script should either:
   - return `$true` / `$false`, or
   - throw on failure and stay silent on success.
   
   Pick one style and use it everywhere. For this repo, "throw on failure" is the simplest.

2. Add a tiny shared assertion helper file.
   Create something like `tests/test-helpers.ps1` with a few functions:
   - `Assert-True`
   - `Assert-Equal`
   - `Assert-PathExists`
   - `Fail-Test`
   
   This removes repeated `if (...) { throw ... }` blocks and makes failures read more clearly.

3. Make `run-all-tests.ps1` print a final summary with counts.
   It already does this partly. Tighten it so the output always clearly shows:
   - total test groups run
   - passed groups
   - failed groups
   - which scripts failed

## Phase 2: Reduce Environment Fragility

4. Stop hardcoding test working paths in multiple files.
   Centralize paths like:
   - `C:\it\temp-gch\bin`
   - `C:\it\temp-gch\config`
   - `C:\Users\NickDemou\dev\GetComputerHealth-v0.0.1.zip`
   
   Put them in one helper function or one config section at the top of the runner.

5. Prefer unique temp folders for test runs when possible.
   `test-Get-ComputerHealth.ps1` and `test-installer.ps1` currently reuse fixed folders. That makes cleanup and parallel runs harder.
   
   Improve this slightly by creating a per-run folder under `%TEMP%` or by allowing an override path parameter.

6. Add explicit prerequisite checks up front.
   Before a test starts, verify required dependencies and fail with a direct message:
   - required scripts exist
   - required helper file exists
   - required commands are available
   - required writable directories are accessible
   
   This turns confusing runtime failures into obvious setup failures.

## Phase 3: Improve Debuggability

7. Add a `-Verbose` or `-Detailed` mode to the runner.
   Default output should stay short.
   When detailed mode is enabled, print:
   - which test is starting
   - important paths being used
   - captured exception details
   - optional extra diagnostics

8. Capture the exact failing command context.
   When a script fails, print:
   - the test name
   - the exception message
   - the file and line if available
   - the main input values involved

9. Save failure logs to a predictable location.
   Example: `tests\artifacts\last-run\`
   
   This does not need to be elaborate. Even a text log per failed script is enough.

## Phase 4: Make Tests Easier to Extend

10. Split `run-all-tests.ps1` responsibilities a bit more.
    Keep it as the entry point, but move reusable logic into helpers:
    - discovery of test scripts
    - result recording
    - summary printing
    - temporary directory creation

11. Separate "unit-ish" tests from "machine/integration" tests.
    You already have both types mixed together.
    
    A simple improvement is naming or grouping:
    - `test-unit-*.ps1`
    - `test-integration-*.ps1`
    
    Then let the runner support:
    - run everything
    - run only unit-like tests
    - run only integration-like tests

12. Document the contract for new tests.
    Add a short section in this file or another `README.md` saying:
    - where new tests go
    - how they should fail
    - what helpers to use
    - what side effects they are allowed to have

## Phase 5: Add One Small Safety Layer

13. Add cleanup in `finally` blocks for every test that creates files.
    Some cleanup exists already, but it should be consistent everywhere.
    Each test that creates temp folders, zips, or copied scripts should own its cleanup.

14. Make destructive operations more obviously test-scoped.
    For example:
    - never delete broad fixed paths unless they were created by the current run
    - avoid `robocopy /mir` against paths that are not clearly test-only

15. Add a lightweight "smoke only" mode.
    Some checks are expensive or machine-sensitive. Add a switch so the runner can execute just the fastest, lowest-risk checks when needed.

## Recommended Order

If you only do a little work now, do these first:

1. Add `tests/test-helpers.ps1` with a few assertion functions.
2. Centralize test paths and temp folder creation.
3. Improve failure messages and final summary in `run-all-tests.ps1`.
4. Add prerequisite checks at the start of each standalone test.
5. Separate unit-like tests from integration tests by naming convention.

## What "Materially Better" Looks Like

After the changes above, the test system should still feel simple, but it should be noticeably better because:

- failures will be easier to understand
- test scripts will be easier to write consistently
- path and environment assumptions will be clearer
- cleanup will be safer
- running a subset of tests will be possible
- future additions will be less ad hoc

## Explicit Non-Goals

These are not necessary right now:

- migrating everything to Pester
- adding mocking frameworks
- producing CI-grade structured reports
- removing all machine-specific integration testing

The right target is not "fancy". The right target is "same simplicity, fewer sharp edges".
