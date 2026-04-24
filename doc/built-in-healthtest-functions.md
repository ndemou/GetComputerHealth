## Built in HealthTest- functions

### Behavior Rules

- Keep side effects at zero.
  Functions **must never** change machine state, only inspect and report.
- Report using the expected `Write-Warning` pattern (see [`how-to-add-custom-tests.md`](how-to-add-custom-tests.md)).
- Be explicit about scope and prerequisites.
  If a test only applies to DCs, domain-joined machines, laptops, and so on, use the special fields in the top-level help block. If they don't cover your situation, short-circuit early.
- Catch exceptions only when you can recover or downgrade cleanly.
  Otherwise do nothing; the framework will gracefully handle and report.

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

The function **must** include the top level help block immediately after the opening `{` and it must have standardized `field: value` lines.

The `Field: Value` lines follow this exact order (note that some are optional):
   1. `Description:` What kind of issues it detects or what findings it uncovers (160 chars max).
   2. `AppliesTo:`. Options are `All`, `VM`, `Mobile`, `DomainJoined`, `Server`, `Workstation`, `DC`, `PDC`
   3. `Scope:`. Options are `Computer`, `Domain`, `Forest`
   4. `Category:` primary plus optional secondary category. Options are: `Availability/Server Down Signals`,`Security & Stability Risks`,`Configuration Hygiene & Best Practices`,`Audit/Compliance/Informational`
   5. `Impact:` either "low" if there's low impact on all dimensions, or one or more "<level>(<dimension>)" pairs where <lever> is either "Medium" or "High" and  dimension is one of "CPU","Disk","Network","RAM","Time"
   6. `Tags:` optional comma-separated values. Supported values: `Essential`, `Policy`.
   7. `Uses:` optional, up to three essential external cmdlets or executables if any.
   8. `FalsePositives:` optional short note only if False Positives are to be expected

### About the Tags field

Use it to tag health tests. Examples:
- `Tags: Essential`
- `Tags: Essential, Policy`

Supported tags:
- `Essential`: indicates an essential test
- `Policy`: indicates a policy inventory test (see below)

### Slow tests

If your test needs more than 3secs to complete, indicate it in the Impact field (`Impact: ... High(Time)`). 
`-SkipSlowTests` uses that marker.

### Policy Inventory Tests

Tests with the `Policy` tag are those that inventory a system aspect where the initial controlled state is accepted as a baseline. For example the Open ports, installed software and enabled services after a clean installation of a server.

Policy Health tests have special handling:
- The first run automatically suppresses `[WARNING]` and `[NOTICE]` findings from that policy test (except if `-DontAutosetPolicy` is used)
- `[FAILURE]` findings are not auto-suppressed
- A flag is appended to `Get-ComputerHealth.sigs-to-suppress.txt` so future runs are treated normally

