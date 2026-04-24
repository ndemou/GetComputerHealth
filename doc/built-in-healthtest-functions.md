## Built in HealthTest- functions

### Function Shape

Use this structure and PascalCase after the `HealthTest-` prefix:
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

### Required Help Block

Every built-in `HealthTest-*` function **must** include an in-function comment-based help block with standarized `field: value` lines immediately after the opening `{`.

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
