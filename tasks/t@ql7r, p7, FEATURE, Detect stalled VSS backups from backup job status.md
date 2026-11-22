<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:47.218Z","completions":[]} -->

GitHub source: [#141](https://github.com/ndemou/GetComputerHealth/issues/141)

**Low priority feature request.**

`HealthTest-VssWriters` takes a single `vssadmin list writers` reading. States 2–5 are normal waiting states, and a backup job can stay in progress for hours. The writer state and `No error` alone cannot tell us whether the job is making progress or has stalled. Related to #116.

When the backup product exposes reliable job status or recent history, use that evidence to report a stalled or timed-out backup. An ordinary in-progress backup should pass the writer check. Cover successful, in-progress, timed-out, and unavailable job status in verification.

Keep the check read-only and within the existing 1–3 minute health-check budget. Read status or history that is already available and return without waiting for a job to finish. Preserve the writer-state result when job status is unavailable.

[Microsoft Learn on interpreting VSS writer status](https://learn.microsoft.com/en-us/windows/win32/vss/determining-writer-status)
