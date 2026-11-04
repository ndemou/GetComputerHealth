# Tests

Canonical testing docs:

- [`../doc/contributor/test-suite.md`](../doc/contributor/test-suite.md) explains what each runner does and when to use it.
- [`../CONTRIBUTING.md`](../CONTRIBUTING.md) contains the contributor workflow, conventions, and CI policy.

Run commands from the repository root in Windows PowerShell 5.1. The unit suite requires Pester 5 or newer.

Quick command reference:

- Run unit tests:
  `.\tests\run-unit-tests.ps1`
- Run smoke tests:
  `.\tests\run-all-tests.ps1 -Smoke`
- Run machine-coupled integration checks:
  `.\tests\run-all-tests.ps1 -Category Integration`
- Run all tests:
  `.\tests\run-all-tests.ps1`

Routine test runs do not enable `-IReallyWantToRunTestsThatChangeState`. Integration checks still query the local machine and create temporary installation files. See the canonical guide for coverage and limitations.
