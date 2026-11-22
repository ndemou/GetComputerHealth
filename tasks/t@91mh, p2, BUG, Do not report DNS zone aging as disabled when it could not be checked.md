<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:43.964Z","completions":[]} -->

GitHub source: [#89](https://github.com/ndemou/GetComputerHealth/issues/89) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/89#issuecomment-7062029688)

Confirmed in `HealthTest-DnsScavenging.ps1`. A failed zone-aging query leaves $ai null, then enters the same branch as an explicit AgingEnabled=false result.

Proposed fix:

1. Handle each zone query in its own try/catch. On failure, emit a WARNING that aging could not be inspected, including zone identity and error details; mark the overall inspection incomplete and continue.
2. Distinguish a valid boolean false, true, and missing/unusable result. Only false should produce the disabled-setting finding.
3. Reserve the overall PASS for successful server/zone inspection with all applicable checks satisfied.
4. Keep the current zone selection and scavenging policy. This fix corrects evidence classification; it does not enable scavenging or redefine its suitability.

Tests: enabled, explicitly disabled, query error, empty/missing AgingEnabled, and a failed zone followed by a disabled zone. Assert an error never says that aging is disabled and never permits the overall PASS.

Priority P2; low regression risk. Plan only. Validate using mocked DNS cmdlets with the unit and smoke runners under Windows PowerShell 5.1.
