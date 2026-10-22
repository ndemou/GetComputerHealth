# Reporting

`reporting.ps1` exposes `Invoke-GetComputerHealthReporting` as the callable reporting entry point. (Reminder: `Get-ComputerHealth.ps1` runs tests; `Invoke-GetComputerHealth.ps1` orchestrates machines and collection (it calls `Get-ComputerHealth.ps1`); reporting.ps1 turns the collected results into saved artifacts, HTML reports, and optional email.)

For interactive developer use:

```powershell
$repoRoot = 'C:\it\GetComputerHealth\bin'
. (Join-Path $repoRoot 'reporting.ps1')

$latestReport = Get-ChildItem -LiteralPath (Join-Path (Split-Path -Parent $repoRoot) 'temp') -Filter 'last-all-findings.clixml' |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

$all_messages = @()
if ($latestReport) {
  $all_messages = @(Import-Clixml -LiteralPath $latestReport.FullName)
}

Invoke-GetComputerHealthReporting -Messages $all_messages
```

Notes:

- `-Messages` is required, but it can be an empty array. The function then returns without creating report output.
- `-Timestamp` is optional. If omitted, reporting uses the current time formatted as `yyyy-MM-dd_HH.mm`.
- `-Targets` is optional. If omitted, reporting derives unique target names from each message's `Computer` property.
- `-NoSendReport` and `-SendReport` keep the same interactive vs non-interactive defaults as `Invoke-GetComputerHealth.ps1`.

## Automatic repeat suppression

Some findings describe a specific event that later checks may keep observing. `SuppressRepeats` shows the first observation normally and suppresses repeats until there has been a gap of at least 45 days. Each observation refreshes the interval, even when the finding is already suppressed. The interval starts at the health check's observation time, not the event's timestamp.

For example, `HealthTest-ScheduledTasks` uses this behavior for failed executions with a known last run time. If the task does not run again, the same failure is reported once. A new failed execution has a different last run time and is reported as a new finding. Failed executions with an unknown last run time, disabled tasks, missed runs, stale tasks, and collection errors keep their normal reporting behavior.

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
