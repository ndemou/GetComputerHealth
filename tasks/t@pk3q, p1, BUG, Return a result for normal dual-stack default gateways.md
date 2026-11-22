<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:45.261Z","completions":[]} -->

GitHub source: [#113](https://github.com/ndemou/GetComputerHealth/issues/113) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/113#issuecomment-7062097879)

Confirmed: the default path combines IPv4 and IPv6 gateways, while the workstation helper inspects IPv4 only. A normal dual-stack workstation can emit nothing; a dual-stack server can get a false multiple-gateway failure. AllowOnePerFamily already exists but is not the default and still uses the IPv4-only helper.

Proposed fix:

1. Make at-most-one default gateway per address family the normal evaluation.
2. When a family has multiple routes, pass that family explicitly to the metric-check helper and inspect its matching default prefix and interface metrics.
3. Return a clear result for IPv4-only, IPv6-only, and dual-stack cases. If routes disappear during inspection or a query fails, report the incomplete check instead of silently returning.
4. Distinguish routes by interface plus next hop; IPv6 link-local gateway text alone is not a globally unique identity.
5. Preserve the existing policy for genuinely multiple same-family server routes in this fix, documenting the default-behavior change and any explicit legacy override.

Tests: one route in either family, one in each, multiple IPv4 routes, multiple IPv6 routes, equal/unequal metrics, failed reads, and disappearing routes. Cover workstation and server paths.

Priority P1; moderate risk because route selection and the default change affect many hosts. Plan only. Validate unit, smoke, and integration under Windows PowerShell 5.1.
