<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:46.295Z","completions":[]} -->

GitHub source: [#129](https://github.com/ndemou/GetComputerHealth/issues/129) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/129#issuecomment-7062165723)

Confirmed: normal no-argument invocation cannot enforce an expected-zone list and currently labels even an empty inventory PASS. There is no universal reverse-zone list that would be correct for every installation.

Proposed fix:

1. Use the shared read-only health-test-baselines.psd1 mechanism proposed in #102, resolved from CONFIG_DIR. Add a validated expected reverse-zone list instead of introducing another configuration loader.
2. Preserve explicitly supplied ExpectedReverseZones as the highest-precedence override.
3. Without a configured expectation, report INFO inventory and say the requirement was not evaluated. Malformed/unreadable configuration is WARNING, not an empty valid baseline.
4. Compare normalized DNS zone names case-insensitively, with a consistent trailing-dot rule, for both IPv4 and IPv6 reverse zones.
5. Report each configured missing zone. PASS requires successful discovery and a complete comparison; a query error must not become an empty inventory.

Tests: normal runner with configured and unconfigured baselines, explicit override, missing/present zones, case/trailing-dot variants, IPv6 reverse zones, malformed configuration, and discovery failure.

Priority P2; moderate risk due to the shared configuration dependency. Implement together with #102 and #130. Plan only. Validate unit, smoke, and installed-runtime configuration handling under Windows PowerShell 5.1.
