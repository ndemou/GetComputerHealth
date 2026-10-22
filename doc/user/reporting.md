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

Findings marked `SuppressRepeats` are shown on their first observation and again after at least 45 days without observing them. Repeated observations remain in the full results with `Suppressed = $true` and `SuppressionSource = 'SuppressRepeats'`. They do not enter the notable report as `Postponed`.

Saved report rows and interactive-report details preserve `SuppressRepeats`, `SuppressionSource`, `FirstSeenUtc`, and `LastSeenUtc`. `FirstSeenUtc` records the earliest observation retained for that finding; `LastSeenUtc` is refreshed on each observation. Configured suppressions take precedence, retain their existing expiry and reminders, and do not stop this observation tracking.
