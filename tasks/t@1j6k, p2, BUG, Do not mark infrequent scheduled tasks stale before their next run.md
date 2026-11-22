<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:44.991Z","completions":[]} -->

GitHub source: [#108](https://github.com/ndemou/GetComputerHealth/issues/108) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/108#issuecomment-7062096078)

Partly fixed already. Current main exempts a Ready task that has never run, has no missed runs, and has one enabled non-repeating TimeTrigger with a future StartBoundary. Existing tests cover that exemption. The report remains valid for monthly/annual schedules: the general stale branch still compares only LastRunTime with StaleDays.

Proposed fix:

1. Preserve the existing future-first-run exemption and its tests.
2. Base staleness on an expected execution that is actually overdue, using enabled triggers, start/end boundaries, last execution, and missed-run evidence.
3. Do not simply exempt every task with NextRunTime in the future: an overdue daily task usually also has a future next occurrence.
4. Isolate schedule evaluation in one testable helper. Use a validated read-only Task Scheduler schedule query where possible rather than building a complete calendar engine. Unsupported/ambiguous triggers should produce explicit uncertainty, not an invented missed deadline.
5. Keep failed-result, disabled-required-task, and missed-run findings independent from this change. Account for multiple triggers, repetition, disabled triggers, time zones, and DST.

Tests: daily overdue, healthy monthly/annual, future first run, multiple triggers, DST boundary, expired one-shot task, and uncertain schedule. Freeze the clock in tests.

Priority P2; moderate to high regression risk. Plan only. Validate existing scheduled-task tests plus unit, smoke, and integration under Windows PowerShell 5.1.
