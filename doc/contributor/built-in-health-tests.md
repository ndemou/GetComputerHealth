# Built-in HealthTest Functions

*(Information for developers only)*

For the full documentation routing table, see [`README.md`](../README.md).

## Behavior Rules

- Keep ordinary built-in tests read-only.
  Functions directly under `health-tests` **must never** change machine state; they only inspect and report.
- Follow the [state-changing health-test design decision](../design/state-changing-health-tests.md).
  An approved test that makes limited state changes must be highly safe for conventional systems, live under `health-tests\HealthTests-that-do-change-state`, describe the active behavior clearly, and remain guarded by `-IReallyWantToRunTestsThatChangeState`.
- Follow the [health findings and noise design decision](../design/health-findings-and-noise.md).
  This is an administrative health tool rather than a threat-detection product; prefer actionable, low-noise findings when broader detection would create recurring false positives.
- Report using the expected `Write-Warning` pattern:
  ```
  Write-Warning "[LEVEL] Description of the issue"
  Write-Warning ("[LEVEL] Description of the issue" + "`n" + $details)
  ```
  Where `LEVEL` is one of `PASS`, `INFO`, `NOTICE`, `WARNING`, or `FAILURE`. See [`user/custom-tests.md`](../user/custom-tests.md) for more information.
- Be explicit about scope and prerequisites.
  If a test only applies to DCs, domain-joined machines, laptops, and so on, use the special fields in the top-level help block. If they don't cover your situation, short-circuit early.
- Catch exceptions only when you can recover or downgrade cleanly. Otherwise, do nothing because the framework that invokes the functions catches exceptions, reports them, and aborts the rest of the HealthTest code. A typical example is iterating over a list and testing each item, where you do not want an exception for one item to skip all the others.

## Function Shape

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

Place ordinary functions directly under `health-tests`. Use `health-tests\HealthTests-that-do-change-state` only for explicitly approved tests whose diagnostic value justifies limited, highly safe state changes. Their `Description:` and detailed help must say what operation changes state.

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

  If `Tags:` includes `Policy`, the detailed part of the help block must also include `Policy identity:` and `Policy baseline version: N`. See below.

  Use `Uses:` to list the main non-built-in commands or helper functions the HealthTest depends on, for example:

  - module cmdlets such as `Get-ADUser`, `Get-DnsServerZone`, `Get-WindowsFeature`
  - external executables such as `dcdiag.exe`, `repadmin.exe`, `w32tm.exe`, `certutil.exe`
  - repo helper functions such as `Get-ServiceVendors`, `Test-NetConnectionFast`, `Get-InstalledSW`
  - helper functions defined elsewhere in the same file or repo, as long as they are not defined inside the `HealthTest-*` function body itself

  Do not list:

  - built-in PowerShell language constructs or common built-in cmdlets
  - helper functions defined inside the `HealthTest-*` function itself
  - vague prose descriptions instead of concrete command/function names

## About the Tags field

Use it to tag health tests. Examples:
- `Tags: Essential`
- `Tags: Essential, Policy`

Supported tags:
- `Essential`: indicates an essential test
- `Policy`: indicates a policy inventory test (see below)
- `Suppressed`: indicates an inventory/audit test whose emitted non-debug messages should be treated as suppressed by default (see below)

## Slow tests

If your test needs more than 3 seconds to complete, indicate that in the Impact field (`Impact: ... High(Time)`).
`-SkipSlowTests` uses that marker.

## Suppressed Inventory Tests

Tests with the `Suppressed` tag are for inventory/audit data that should be returned as structured log objects without distracting operators in normal console output. When the runner processes a suppressed-tagged test, each emitted non-debug test message is marked with `Suppressed = $true` as if its message signature were present in `Get-ComputerHealth.sigs-to-suppress.txt`.

Use `Suppressed` only when every message from the test is expected inventory data rather than an actionable health problem. Operators can still see those messages unless they hide suppressed output with `-Hide S`; automation that uses `-OutputObjects` still receives the log objects.

Suppressed Inventory Tests can be extremely useful for "Required findings".

## Findings that must only be reported once

Some findings describe an event at a specific point in time (e.g. the failed execution of a Scheduled Task). In such cases it's very convenient for the first observation to be reported but all later observations of the *same* event to be silent. In practice if there's a gap of at 45 days without any observation and then the finding reappears it will be reported again.

To enable this behavior for a finding, add `[SuppressRepeats]` immediately after its severity prefix, as shown below.

```powershell
Write-Warning "[FAILURE][SuppressRepeats] Event $eventName occured at $($timestamp).`n$details"
```

It is supported for `NOTICE`, `WARNING`, and `FAILURE`. Put everything that distinguishes the specific event in the first-line description (e.g. its timestamp). The runner handles everything else.

### Implementation details for `SuppressRepeats`

The runner sets `SuppressRepeats = $true` and removes the marker before displaying the description or calculating its signature. Adding the marker therefore preserves existing finding signatures. Severity is also preserved, but is not part of the signature: changing only details or severity does not create a new notification. See [automatic repeat suppression](../user/reporting.md#automatic-repeat-suppression), and the [SuppressRepeats design](../design/first-seen-findings.md) for details.

For example, `HealthTest-ScheduledTasks` uses this behavior for a failed execution at a specific last run time. A new failed execution will have a different last run time and will be reported as a new finding. 

The following assumes no other active suppression covers the finding:

| Observation | Result |
| --- | --- |
| First observation | Shown normally; the observation is saved. |
| The same event every day for months | Shown only the first time; each observation refreshes the interval. |
| The same event every month | Remains suppressed while every gap is shorter than 45 days. |
| Return 44 days after the last observation | Suppressed; the observation is refreshed. |
| Return exactly 45 days or more after the last observation | Shown again; a new interval starts. |
| A run does not find the event | Its observation is not refreshed. |

A continuously observed event can stay suppressed indefinitely. Changes only to details or severity, including an increase from `WARNING` to `FAILURE`, do not create a new notification. Repeats remain in the full results with their current severity and details, and the existing filters control whether suppressed findings are displayed.

An offline computer or a skipped test can also create a 45-day gap. Seeing the finding again after that gap does not prove that the underlying problem was resolved and then returned. Recording an observation also does not confirm that someone read the report.

### Manual suppressions and Postponed

Configured suppressions, including manual choices and policy baselines, take precedence. SuppressRepeats keeps observing the finding but does not modify `config\Get-ComputerHealth.sigs-to-suppress.txt`, its expiry dates, or permanent entries.

This means that **expiry of a manual suppression does not guarantee a new notification**. A continuously observed finding can still be covered by repeat suppression.

Automatic repeats never become `Postponed`. That report level belongs to configured suppressions approaching their expiry within `ShowAsPostponedWindowDays`. Repeat suppression does not populate or replace `SuppressedUntil` with its own calculated expiry. Configured suppressions retain their existing postponement reminders.

### Repeat suppression fields

Saved report rows retain these properties. Interactive-report details show the repeat-handling source and observation timestamps when available.

| Property | Meaning |
| --- | --- |
| `SuppressRepeats` | The finding opts into repeat handling, including on its first visible occurrence. |
| `Suppressed` | The finding is suppressed in this run by any applicable mechanism. |
| `SuppressionSource` | `Configured`, `SuppressedTag`, `Explicit`, or `SuppressRepeats`; empty when no suppression applies. `Configured` covers manual suppressions and policy baselines. |
| `FirstSeenUtc` | The earliest retained observation, preserved even across a gap of 45 days or more. |
| `LastSeenUtc` | The time of the current observation, refreshed even for suppressed findings. |
| `SuppressedUntil` | The existing configured suppression expiry, when available; never the calculated SuppressRepeats expiry. |

### State and troubleshooting

Each checked computer stores observations in `state\suppress_repeats.json` under its installation root. State persists across runs and code updates. With no previous entry, the next observation is treated as new, subject to other active suppressions. If the clock moves backwards and makes the previous observation appear to be in the future, that observation history is restarted.

If state cannot be read or saved, the runner emits a warning and does not apply repeat suppression to that finding. Configured suppressions still apply. Repeated notifications alongside a state warning therefore indicate a problem with observation tracking; inspect the warning's details for the cause.

See the [SuppressRepeats design](../design/first-seen-findings.md) for state format, precedence, locking, and failure handling. To mark findings in built-in or custom tests, see the [authoring guide](../contributor/built-in-health-tests.md#findings-that-suppress-repeats). Persistent repeat handling requires `Get-ComputerHealth.ps1` or `Invoke-GetComputerHealth.ps1`; directly executing a health-test file only prints its warnings.

## Policy Inventory Tests

Tests with the `Policy` tag inventory a system aspect where the initial controlled state is accepted as a baseline. For example, this can cover open ports, installed software, and enabled services after a clean server installation.

Policy Health tests have special handling:
- The first run automatically suppresses `[WARNING]` and `[NOTICE]` findings from that policy test (except if `-DontAutosetPolicy` is used)
- `[FAILURE]` findings are not auto-suppressed
- A flag is appended to `Get-ComputerHealth.sigs-to-suppress.txt` so future runs are treated normally
- The auto-baseline flag includes the test's `Policy baseline version`

The detailed part of the help block of a Policy health test must also include:
  - `Policy identity:` explaining what stable object identity or fingerprint appears in the first finding line.
  - `Policy baseline version: N` where `N` is a non-negative integer. Use `1` for new built-in policy tests.

Policy tests work best when each emitted finding has a stable, intentional identity. The identity is whatever must appear in the first warning line so the generic message-signature and `Policy` suppression machinery can distinguish a known finding from a new one.

Do not overbuild this. Use the simplest identity that matches the review need:

- If the object identity is enough, put that identity in the first line prefixed with "Found ". Examples: local administrator account, installed role name, share name plus path, or installed software name. 
- If the same object can change in security- or operations-relevant ways while keeping the same object name, add a compact definition fingerprint. The fingerprint should include fields whose change should force human review.
- Keep volatile runtime status out of policy identity. Last run time, next run time, current state, process ID, missed run count, last result, queue depth, and similar facts usually belong in health findings or comments, not in a policy ID.

Every built-in policy test must document its identity and baseline version in the help block:

```powershell
Tags: Policy
Uses: Get-Something.

Policy identity: normalized object name plus review-worthy definition fingerprint.
Policy baseline version: 1
```

Increase `Policy baseline version` when a code change results in a change of the first warning line, and as a result requires a re-run of auto-baselining. Typical reasons include changing the policy identity, adding important fields to a fingerprint, removing fields that made the old fingerprint misleading, or splitting/merging policy findings. 

Only split a topic into separate policy and hygiene tests when both questions matter:

- A policy listing answers: "What definitions exist, and are these definitions expected here?"
- A hygiene test answers: "Is the current state/result of those definitions healthy?"

Some topics need only one side. Installed software is usually just a policy listing. A DNS client service check may be only hygiene. Services and scheduled tasks naturally have both a definition/inventory side and a runtime health side.

Use a shared normalized fact collector only when it pays for itself: when enumeration is expensive, interpretation is complicated, or multiple tests would otherwise duplicate fragile logic. A simple policy test that reads one object type once does not need a separate collector.

Scheduled tasks are the full version of this pattern:

- `HealthTest-ListScheduledTasks` is a `Policy` test that emits one finding per task definition.
- The stable object key is task path plus task name.
- The policy fingerprint includes review-worthy definition fields: actions, triggers, run account, run level, logon type, hidden state, and enabled state.
- Runtime fields such as last run time, missed runs, and last result are deliberately excluded from that fingerprint.
- `HealthTest-ScheduledTasks` is the separate hygiene test that reports disabled required tasks, failed last results, missed runs, stale runs, and unreadable task metadata.

This lets the generic `Policy` handling baseline known scheduled-task definitions on first run. Later, a new task or a changed definition emits a new message signature without requiring a separate state file, while current operational failures remain visible through the hygiene test.

## Helpers

Feel free to use functions from `health-tests\helpers-for-healthtests.ps1`.
