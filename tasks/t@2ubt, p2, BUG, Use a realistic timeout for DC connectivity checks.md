<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:44.258Z","completions":[]} -->

GitHub source: [#94](https://github.com/ndemou/GetComputerHealth/issues/94) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/94#issuecomment-7062061955)
Related TAT task: [t@2od1 Fix dual-stack TCP connection checks and endpoint reporting](./t%402od1%2C%20p5%2C%20BUG%2C%20Fix%20dual-stack%20TCP%20connection%20checks%20and%20endpoint%20reporting.md)

Confirmed in Test-NetConnectionFast: $TIMEOUT_MS is fixed at 100 and controls the TCP connect wait. This can reject ordinary WAN/VPN latency.

Proposed fix:

1. Add a validated TimeoutMs parameter with a proposed default of 2000 ms, and pass it through from HealthTest-ConnectivityToDCs.
2. Keep the current TCP success rule: the wait completes and EndConnect succeeds. A completed refused connection is not success.
3. Dispose the async wait handle and TCP client on success, refusal, timeout, and exception.
4. Document that this bounds the TCP wait, not all DNS resolution or optional ping work. Retain the existing result object and port list. Consider total duration across all DCs before increasing the default further.

Tests: mocked completion at 140 ms succeeds with the default, completion after the configured limit fails, immediate refusal fails, caller overrides are honored, and handles are released. Avoid tests that sleep or depend on Internet timing.

Priority P2; low code risk, with increased duration on unreachable hosts as the main tradeoff. Plan only. Validate unit, smoke, and integration runners under Windows PowerShell 5.1.
