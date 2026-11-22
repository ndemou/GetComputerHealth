<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:46.031Z","completions":[]} -->

GitHub source: [#124](https://github.com/ndemou/GetComputerHealth/issues/124) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/124#issuecomment-7062162232)

Confirmed: ADInboundReplicationTopology suppresses both query types and conflates read failure with zero partners/connections. Its final flag also ignores NOTICE paths, allowing an overbroad all-DC PASS.

Proposed fix:

1. Track success/empty/error independently for partner metadata and connection-object queries on each DC, using terminating errors and per-query recovery.
2. On a query error, identify the DC and failed query with useful details. Do not label the missing result as proven absence of replication.
3. Continue inspecting other DCs and retain findings from successful evidence.
4. Reserve the full cross-check PASS for complete, consistent evidence from every intended DC. A mismatch NOTICE or failed query blocks that summary.
5. Distinguish a valid single-DC domain from an expected replication topology with missing partners. This prevents tests from baking in "every domain must have another DC" as an unstated requirement.

Tests: both data sources present, genuinely absent expected replication, either query failing, both failing, mismatch NOTICE, one failed DC followed by a healthy DC, and single-DC topology.

Priority P1 for infrastructure-result accuracy; low to moderate risk with topology fixtures. Plan only. Validate unit, smoke, and integration runners under Windows PowerShell 5.1.
