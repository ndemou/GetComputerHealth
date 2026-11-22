<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:46.470Z","completions":[]} -->

GitHub source: [#131](https://github.com/ndemou/GetComputerHealth/issues/131) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/131#issuecomment-7062166875)

Confirmed: the built-in no-argument run takes the inventory branch and reports PASS regardless of disabled bindings. A successful inventory is not proof of healthy IPv6 configuration.

Proposed fix:

1. Make the normal run evaluate an explicit enabled-binding baseline on applicable adapters, with documented exceptions. Microsoft recommends keeping IPv6 enabled/bound, but adapter applicability still matters: [IPv6 configuration guidance](https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/configure-ipv6-in-windows).
2. Define which adapters are checked, including disconnected/virtual adapters and intentionally excluded interfaces, before changing the default. Avoid a blanket failure for every installed adapter.
3. Keep a deliberate inventory mode, including a compatible explicit RequireEnabled:$false call, but emit INFO and clearly say that no health baseline was evaluated.
4. Report disabled applicable bindings with adapter identity. Missing/unknown binding state or failed discovery cannot produce an all-clear result.
5. Document that this checks the binding only, not IPv6 routing or connectivity. Never enable bindings or change the computer's configuration.

Tests: normal runner defaults, enabled/disabled applicable adapters, explicit inventory mode, exclusions, disconnected adapters, empty discovery, null status, and query failure.

Priority P2; moderate risk because changing the default adds findings and requires a clear adapter policy. Plan only. Validate unit, smoke, and representative read-only integration under Windows PowerShell 5.1.
