# SuppressRepeats findings

Status: implemented per finding, first used for failed executions reported by `HealthTest-ScheduledTasks`.

For day-to-day behavior, see [automatic repeat suppression](../user/reporting.md#automatic-repeat-suppression). For the marker syntax and selection of suitable findings, see [findings that suppress repeats](../contributor/built-in-health-tests.md#findings-that-suppress-repeats). This document records the design decisions, state format, and implementation requirements.

## Intent

A finding that describes a specific event should be shown only when we first observe it. If later checks find exactly the same event, keep it in the full results as suppressed. After at least 45 days without observing that finding, show it again if it returns.

Measure the interval from the last health check that observed the finding, even when it was suppressed. The 45-day interval allows monthly runs of `Get-ComputerHealth` to keep suppressing the same old event. Continuous observations can keep it suppressed indefinitely; that is intentional.

## Event identity and per-finding scope

This finding identifies a particular failed execution:

```text
Scheduled task '\enLogic\Execute WindowsUpdatesHelper' terminated with LastTaskResult=0x800710E0 (Either wrong password or win32 error 'The operator or administrator has refused the request'); Last run time 2026-10-18 20:03:03.
```

The full task path, error code, and last run time distinguish the event. If the task does not run again, later checks observe the same finding. If it runs and fails again, the new last run time changes the description and its signature, so the new execution is shown unless another suppression covers it.

The existing description signature identifies the finding. The marker, details, and severity are excluded from that signature. Changes only to details do not create a new notification. A severity increase from `WARNING` to `FAILURE` also keeps the existing repeat suppression; the current severity remains in the results.

Apply the behavior to individual event findings. `HealthTest-ScheduledTasks` also reports disabled tasks, missed runs, stale tasks, and collection errors, which keep their normal behavior. The [authoring guide](../contributor/built-in-health-tests.md#findings-that-suppress-repeats) defines which findings use the marker. The test remains a single health test, and the runner owns all observation state.

## The 45-day rule

For each marked finding, the runner uses its previous observation to decide whether it is a repeat:

```text
SuppressRepeats suppression is active when:
    PreviousLastSeenUtc <= NowUtc < PreviousLastSeenUtc + 45 days
```

At exactly 45 days, repeat suppression has expired. UTC timestamps keep timezone and daylight-saving changes from changing the interval.

1. Read the previous state and calculate the repeat decision for this run.
2. Save `LastSeenUtc = NowUtc` for every observation, including findings already suppressed by configuration or repeat handling.
3. Apply the suppression precedence below when emitting the finding. Save the observation successfully before applying automatic suppression; a state failure must not hide the finding.

The repeat decision must use the previous timestamp. Calculating it from the newly saved timestamp would hide even the first observation. Saving state for later runs does not change the decision for the current run. Console output and reports use that same decision.

A run that does not observe the finding neither refreshes nor immediately deletes its entry. The [reporting guide](../user/reporting.md#automatic-repeat-suppression) gives daily, monthly, and expiry examples.

## Identity and stored state

Store state in `state\suppress_repeats.json` under the installation root on the computer being checked. Each entry is keyed by test name and finding signature. Custom scripts use their full script path instead of a built-in test name. Local storage separates computers; the key separates tests and findings.

```json
[
  {
    "TestName": "HealthTest-ScheduledTasks",
    "Hash": "1234abcd",
    "FirstSeenUtc": "2026-10-08T09:00:01Z",
    "LastSeenUtc": "2026-10-22T09:00:00Z"
  }
]
```

The example signature is illustrative. Calculate expiry as `LastSeenUtc + 45 days`; do not store a second expiry timestamp for the same fact.

`FirstSeenUtc` records the first retained observation and survives gaps of 45 days or more. If the clock moves backwards and the previous observation is in the future, treat the finding as a new observation and reset both timestamps. Other active suppressions still apply.

State survives subsequent runs and code updates. With no previous entry, the first observation is visible unless another active suppression covers it.

## Suppression precedence

Keep automatic observation state separate from `config\Get-ComputerHealth.sigs-to-suppress.txt`. SuppressRepeats does not add entries to that file or change existing suppression dates or permanence. That file contains both manual choices and policy baselines, so its source is named `Configured`.

Use the first applicable rule:

| Condition | Suppression source in the current run |
| --- | --- |
| The finding's signature has an active configured suppression | `Configured` |
| The test has the `Suppressed` tag, or logging explicitly suppresses the finding | `SuppressedTag` or `Explicit` |
| No earlier rule applies and a recent SuppressRepeats observation exists | `SuppressRepeats` |
| No suppression applies | Empty; the finding is visible |

When both configured and repeat suppression apply, report `Configured` as the source and still refresh the repeat observation. Expiry of a manual suppression therefore does not guarantee a new notification. There is no additional mandatory reminder at that point.

## Reporting contract

Preserve `SuppressRepeats`, `Suppressed`, `SuppressionSource`, `FirstSeenUtc`, and `LastSeenUtc` through collection, serialization, saved report rows, and interactive reports. This applies to local runs and remote collection through `Invoke-GetComputerHealth.ps1`. The [report-field reference](../user/reporting.md#repeat-suppression-fields) explains their meanings and source values.

Without another active suppression, the first occurrence has `SuppressRepeats = $true` and `Suppressed = $false`. Subsequent repeats remain in the full results with their current severity and details, subject to the existing display filters for suppressed findings.

Automatic repeat suppression never becomes `Postponed`. Existing postponement reminders use `SuppressedUntil` for configured suppressions. Do not overwrite that field with the calculated repeat-suppression expiry: observing an old event again is not a manual decision to postpone addressing it.

## Limits and state failures

A gap in observations does not prove that the problem was resolved. A computer that is offline, or a test that does not run, for at least 45 days can produce another notification for the same event when checks resume. This is accepted behavior.

Recording a first observation means that the finding was included normally in the results. It does not confirm that the user received or read the report.

On a state read or write failure, report an ordinary warning and leave the finding eligible for normal reporting. The warning itself does not use SuppressRepeats. Existing configured suppressions still apply, so a state error does not override the user's choices.

Updates take an exclusive lock, write a temporary file, and atomically replace the previous state. The `.lock` file remains in place so successive writers lock the same file. If the state is locked, invalid, exceeds 10 MB, or cannot be saved, do not apply repeat suppression to that observation. This can produce repeat notifications, but avoids silently losing findings.

## Verification requirements

Keep regression coverage for these behaviors:

- The first observation is visible in console output and reports even though state has been saved.
- Suppressed observations refresh the interval, including monthly observations and findings covered by configured suppression.
- A repeat before 45 days stays suppressed; a repeat at or after 45 days is visible again.
- A run without the finding does not refresh its state.
- A new last run time or error changes the finding identity; details or severity changes alone do not.
- The marker is removed before calculating the signature and displaying the description; the severity is preserved.
- Other ScheduledTasks findings, including collection failures, keep their normal behavior.
- Configured suppressions retain their dates and precedence, and the reported source matches the decision.
- Repeat suppression never becomes `Postponed`, and all metadata survives the reporting path.
- State remains independent per computer and test, persists between runs, and handles a clock moving backwards.
- Missing, invalid, locked, or unwritable state does not silently hide a new finding.

See [SuppressRepeats tests](../../tests/Unit/SuppressRepeats.Tests.ps1) and [ScheduledTasks tests](../../tests/Unit/HealthTest-ScheduledTasks.Tests.ps1).

## Related implementation

- [Health findings and noise](health-findings-and-noise.md): the preference for useful administrative findings with limited recurring noise.
- [Invoke-GetComputerHealth flow](invoke-getcomputerhealth-flow.md): collection and reporting across computers.
- [Get-ComputerHealth.ps1](../../Get-ComputerHealth.ps1): marker parsing and test execution.
- [lib-write-log-objects.ps1](../../lib-write-log-objects.ps1): signatures, source precedence, and log records.
- [lib-suppress-repeats.ps1](../../lib-suppress-repeats.ps1): observations, expiry, and state storage.
- [HealthTest-ScheduledTasks.ps1](../../health-tests/HealthTest-ScheduledTasks.ps1): selection of failed-execution findings.
- [reporting.ps1](../../reporting.ps1): report fields and postponed findings.
