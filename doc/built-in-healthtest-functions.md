## Built-in HealthTest functions

*(Information for developers only)*

### Behavior Rules

- Keep side effects at zero.
  Functions **must never** change machine state, only inspect and report.
- Report using the expected `Write-Warning` pattern:
  ```
  Write-Warning "[LEVEL] Description of the issue"
  Write-Warning ("[LEVEL] Description of the issue" + "`n" + $details)
  ```
  Where `LEVEL` is one of `PASS`, `INFO`, `NOTICE`, `WARNING`, or `FAILURE`. See [`how-to-add-custom-tests.md`](how-to-add-custom-tests.md) for more information.
- Be explicit about scope and prerequisites.
  If a test only applies to DCs, domain-joined machines, laptops, and so on, use the special fields in the top-level help block. If they don't cover your situation, short-circuit early.
- Catch exceptions only when you can recover or downgrade cleanly. Otherwise, do nothing because the framework that invokes the functions catches exceptions, reports them, and aborts the rest of the HealthTest code. A typical example is iterating over a list and testing each item, where you do not want an exception for one item to skip all the others.

### Function Shape

Use this structure and PascalCase after the `HealthTest-` prefix:
```powershell
function HealthTest-YourTestName {
<#
Description: Finds directories with more than 10000 files.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Time), Medium(Disk)
Tags: Essential
Uses: Get-ChildItem.

<OPTIONAL DETAILED DESCRIPTION>
#>
    # gather data
    # evaluate
    # emit findings
}
```

The function **must** include the top-level help block immediately after the opening `{`, and it must use standardized `field: value` lines.

The `Field: Value` lines follow this exact order (note that some are optional):
   1. `Description:` What kind of issues it detects or what findings it uncovers (160 chars max).
   2. `AppliesTo:`. Options are `All`, `VM`, `Mobile`, `DomainJoined`, `Server`, `Workstation`, `DC`, `PDC`, `HyperV`
      `Hyper-V` is accepted as an alias spelling for `HyperV`, but use `HyperV` in new help blocks for consistency.
   3. `Scope:`. Options are `Computer`, `Domain`, `Forest`
   4. `Category:` primary plus optional secondary category. Options are: `Availability/Server Down Signals`,`Security & Stability Risks`,`Configuration Hygiene & Best Practices`,`Audit/Compliance/Informational`
   5. `Impact:` either "low" when all dimensions have low impact, or one or more "<level>(<dimension>)" pairs. In those pairs, <level> is either "Medium" or "High", and <dimension> is one of "CPU", "Disk", "Network", "RAM", or "Time".
   6. `Tags:` optional comma-separated values. Supported values: `Essential`, `Policy`, `Suppressed`.
   7. `Uses:` optional, up to three essential non-built-in commands or helper functions used by the test.
   8. `FalsePositives:` optional short note, only if false positives are expected.

  Use `Uses:` to list the main non-built-in commands or helper functions the HealthTest depends on, for example:

  - module cmdlets such as `Get-ADUser`, `Get-DnsServerZone`, `Get-WindowsFeature`
  - external executables such as `dcdiag.exe`, `repadmin.exe`, `w32tm.exe`, `certutil.exe`
  - repo helper functions such as `Get-ServiceVendors`, `Test-NetConnectionFast`, `Get-InstalledSW`
  - helper functions defined elsewhere in the same file or repo, as long as they are not defined inside the `HealthTest-*` function body itself

  Do not list:

  - built-in PowerShell language constructs or common built-in cmdlets
  - helper functions defined inside the `HealthTest-*` function itself
  - vague prose descriptions instead of concrete command/function names

### About the Tags field

Use it to tag health tests. Examples:
- `Tags: Essential`
- `Tags: Essential, Policy`

Supported tags:
- `Essential`: indicates an essential test
- `Policy`: indicates a policy inventory test (see below)
- `Suppressed`: indicates an inventory/audit test whose emitted non-debug messages should be treated as suppressed by default (see below)

### Slow tests

If your test needs more than 3 seconds to complete, indicate that in the Impact field (`Impact: ... High(Time)`).
`-SkipSlowTests` uses that marker.

### Suppressed Inventory Tests

Tests with the `Suppressed` tag are for inventory/audit data that should be returned as structured log objects without distracting operators in normal console output. When the runner processes a suppressed-tagged test, each emitted non-debug test message is marked with `Suppressed = $true` as if its message signature were present in `Get-ComputerHealth.sigs-to-suppress.txt`.

Use `Suppressed` only when every message from the test is expected inventory data rather than an actionable health problem. Operators can still see those messages unless they hide suppressed output with `-Hide S`; automation that uses `-OutputObjects` still receives the log objects.

### Policy Inventory Tests

Tests with the `Policy` tag inventory a system aspect where the initial controlled state is accepted as a baseline. For example, this can cover open ports, installed software, and enabled services after a clean server installation.

Policy Health tests have special handling:
- The first run automatically suppresses `[WARNING]` and `[NOTICE]` findings from that policy test (except if `-DontAutosetPolicy` is used)
- `[FAILURE]` findings are not auto-suppressed
- A flag is appended to `Get-ComputerHealth.sigs-to-suppress.txt` so future runs are treated normally

### Helpers

Feel free to use functions from `helpers-for-healthtests.ps1`.
