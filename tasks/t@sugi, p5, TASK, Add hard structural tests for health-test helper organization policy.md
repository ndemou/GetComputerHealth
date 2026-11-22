<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:43.662Z","completions":[]} -->

GitHub source: [#77](https://github.com/ndemou/GetComputerHealth/issues/77)
Related TAT task: [t@tk1w Review the repository test suite](./t%40tk1w%2C%20p5%2C%20TASK%2C%20Review%20the%20repository%20test%20suite.md)

## Goal

Add automated tests that verify the hard constraints for code under `health-tests` are being met.

Definitions used by the policy:

- A **specific HealthTest helper function** is needed only for one health test.
- A **domain helper function** is needed for a class of domain-specific health tests, such as scheduled-task helpers used by scheduled-task health tests.
- A **generic helper function** is needed for a range of unrelated health tests, such as `Get-PropValue`.

Important caveat: generic vs domain vs specific is partly semantic. We can enforce it reliably only if we use naming conventions, a small manifest, allowlists, or metadata comments. Without that, tests can prove structure and dependency correctness, but cannot perfectly infer intent.

## Proposed Tests

### 1. File Layout Test

Checks:

- every non-`HealthTest-*.ps1` file under `health-tests` is either `helpers-for-healthtests.ps1` or `helper-regarding-*.ps1`
- casing matches the policy exactly if we decide the canonical form is `helper-regarding-...` or `Helpers-regarding-...`
- no old grouped helper files exist

### 2. Function Ownership Test

Checks:

- every `HealthTest-*` function exists in exactly one file
- that file is `health-tests/HealthTest-Name.ps1`
- helper files contain no `HealthTest-*` functions
- every `HealthTest-*.ps1` contains exactly one `HealthTest-*` function
- no duplicate function names exist under `health-tests`

### 3. Direct Execution Guard Test

For every `HealthTest-*.ps1`, check that the file ends with the direct-run pattern:

```powershell
if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-Name
}
```

This can be AST-based or strict text-based. Prefer a fairly strict test because this is a policy constraint.

### 4. Dependency Declaration Test

For each `HealthTest-*.ps1`:

- parse all function calls in the file
- build a map of all helper function definitions from `helpers-for-healthtests.ps1` and `helper-regarding-*.ps1`
- for every external helper call, verify there is a matching guard:

```powershell
if (-not (Get-Command -Name 'Foo' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'bar.ps1')
}
```

Also verify `bar.ps1` is the file that actually defines `Foo`.

### 5. Specific Helper Leakage Test

For every helper function outside `HealthTest-*.ps1`, count which `HealthTest-*` files can reach it. If exactly one health test uses it, fail unless it is explicitly allowed.

This catches specific helpers left in a shared helper file.

Caveat: shared internal helper chains can make this tricky. If helper `A` is only called by domain helper `B`, and `B` is only used by one health test, then `A` is effectively specific too.

### 6. Generic Helper Allowlist Test

Because “generic” is semantic, use an allowlist for `helpers-for-healthtests.ps1`.

Current expected generic/shared helper candidates:

- `Get-PropValue`
- `Test-IsVirtualMachine`
- `Test-IsLaptopOrMobile`
- `Compress-HealthDiagnosticOutputLines`
- `Get-PolicyListShortHash`
- `Normalize-PolicyListText`

The test should fail if any other function appears there.

### 7. Domain Helper Manifest Or Metadata Test

For domain helpers, add either a manifest or header metadata.

Example:

```powershell
# HelperDomain: scheduled-tasks
```

Then test:

- every `helper-regarding-*.ps1` has exactly one domain
- all functions in it are used by at least two health tests, or are internal helpers reachable from a shared domain entry point
- no domain helper file mixes declared domains
- filename matches the declared domain slug

Without metadata, we can check filename shape, but cannot prove domain classification.

### 8. Standalone Execution Smoke Test

For every `HealthTest-*.ps1`, ideally run it in a fresh PowerShell process.

Because some health tests touch real machine/environment state, this may be too expensive or brittle for unit tests. Better compromise:

- static tests verify direct-run guard and dependencies for all health tests
- smoke tests directly execute a curated representative subset

### 9. No Old Imports Test

Search all repo `.ps1` and `.md` files for deleted or obsolete helper names, such as:

- `win-os-hyg.ps1`
- `os-perf-hw.ps1`
- `srvc-exe-resolve.ps1`
- `ScheduledTaskHelpers.ps1`

This prevents stale dependency docs and broken test imports.

## Suggested Placement

Create a new Pester file:

- `tests/Unit/HealthTestOrganization.Tests.ps1`

Keep help-block formatting tests in the existing `tests/Unit/HealthTestHelpBlock.Tests.ps1`.
