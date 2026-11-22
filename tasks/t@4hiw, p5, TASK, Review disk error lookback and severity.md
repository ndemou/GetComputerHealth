<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:37:08.763Z","completions":[]} -->

`HealthTest-SeriousRecentEventLogs` already checks recent System log errors from `disk`, `Ntfs`, and `stornvme`. Decide whether disk errors need the proposed 48-hour lookback or `FAILURE` severity. The existing test uses a 24-hour default and `WARNING` for these findings.
