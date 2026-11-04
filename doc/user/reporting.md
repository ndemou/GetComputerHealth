# Reporting

`reporting.ps1` exposes `Invoke-GetComputerHealthReporting` as the callable reporting
entry point. `Get-ComputerHealth.ps1` runs tests; `Invoke-GetComputerHealth.ps1`
orchestrates machines and collects their findings. Reporting turns those findings
into saved files, HTML reports, and optional email. It does not rerun health tests.

For interactive developer use:

```powershell
$binDir = 'C:\IT\Get-ComputerHealth\bin'
. (Join-Path $binDir 'reporting.ps1')

$latestReportPath = Join-Path (Split-Path -Parent $binDir) 'temp\last-all-findings.clixml'

$all_messages = @()
if (Test-Path -LiteralPath $latestReportPath -PathType Leaf) {
  $all_messages = @(Import-Clixml -LiteralPath $latestReportPath)
}

Invoke-GetComputerHealthReporting -Messages $all_messages -NoSendReport
```

Notes:

- `-Messages` is required, but it can be an empty array. The function then returns without creating report output.
- `-Timestamp` is optional. If omitted, reporting uses the current time formatted as `yyyy-MM-dd_HH.mm`.
- `-Targets` is optional. If omitted, reporting derives unique target names from each message's `Computer` property.
- `-NoSendReport` disables email. `-SendReport` enables it; if both are supplied,
  `-NoSendReport` wins. Without either switch, email is enabled only when the
  process has session ID 0 or `[Environment]::UserInteractive` is false. A remote
  PowerShell session can meet that condition even while someone is typing commands.
- Email requires `config\Send-Message.conf`, or `config\Send-Message.psd1` if the
  `.conf` file is absent, relative to the installation root.

## Automatic repeat suppression

Findings marked `SuppressRepeats` report an event once, then suppress later
observations of that same event while retaining it in the full results. Daily
or monthly observations refresh its last-seen timestamp and keep it suppressed.
After at least 45 days without an observation, the next occurrence is reported
again. An active configured suppression still takes precedence. Automatic
repeat suppression does not turn a finding into a `postponed` reminder.

The runner makes this decision before reporting. Rebuilding a report from saved
CLIXML preserves the recorded decision and does not refresh observation state.
See the [design and expiry rules](../design/first-seen-findings.md) for details.

## Repeat suppression fields

Saved report rows preserve these fields:

| Field | Meaning |
| --- | --- |
| `SuppressRepeats` | The finding requests automatic repeat handling |
| `Suppressed` | The finding is suppressed on this run, whether by repeat handling or configured suppression |
| `SuppressionSource` | `Configured` for stored or run-specific signatures, `SuppressedTag` or `Explicit` for other explicit suppression, `SuppressRepeats` for automatic repeats, or empty when none applies |
| `FirstSeenUtc` | First retained observation; preserved across gaps of 45 days or more |
| `LastSeenUtc` | Most recent observation of this finding |

Timestamps are saved as UTC strings. Ordinary findings without repeat handling
have no repeat-observation timestamps. A first observation can have
`SuppressRepeats = $true` while `Suppressed = $false`.

## Saved files

Reporting resolves `config`, `temp`, and `data` relative to the parent of its own
script directory. The example uses the installed `bin` layout; dot-sourcing a
repository checkout instead writes beside that checkout. The `temp` directory
must already exist when exporting a nonempty result set.

| File under the installation root | Contents |
|---|---|
| `temp\last-all-findings.clixml` | All normalized findings from the latest nonempty reporting call, including suppressed findings |
| `data\all-messages-<timestamp>.clixml.zip` | Archived CLIXML findings for that call |
| `temp\last-report.html` | The email HTML body, including the all-clear body when nothing is notable |
| `temp\last-interactive-report.html` | Interactive report of notable findings, updated only when notable findings exist |

Notable findings normally include unsuppressed failures, warnings, and notices.
Findings marked `postponed` are also included. The email body contains the notable
findings and attaches the interactive report. When no findings are notable, email
contains the all-clear body without that attachment. An older interactive report
can therefore remain on disk after a later all-clear run.

The temporary timestamped CLIXML is removed after compression. Reusing a timestamp
replaces that archive, so pass a distinct `-Timestamp` if you need to retain
multiple reporting calls made in the same minute.

