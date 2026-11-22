<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:45.720Z","completions":[]} -->

GitHub source: [#120](https://github.com/ndemou/GetComputerHealth/issues/120) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/120#issuecomment-7062160373)
Related TAT task: [t@hew1 Detect the local hardware clock on non-English Windows](./t%40hew1%2C%20p5%2C%20BUG%2C%20Detect%20the%20local%20hardware%20clock%20on%20non-English%20Windows.md)

Confirmed: Is-DCSource accepts any hostname ending in the AD domain. It can also accept an unrelated FQDN by matching only its short-name prefix. Neither proves that the source is a discovered DC.

Proposed fix:

1. Remove the domain-suffix fallback. Normalize case and trailing dots, then match discovered FQDNs exactly.
2. Accept a discovered short name only when the reported source itself is unqualified. Do not turn dc01.other-domain.example into a match for dc01.
3. Return discovery status separately from the discovered name set. A failed/empty discovery produces an unverified-source result, not a confident non-DC diagnosis or PASS.
4. Keep clearly established configuration findings independent. Do not let unknown DC discovery suppress a proven wrong time-service mode.
5. Preserve PDC/member/standalone distinctions. Validate legitimate parent-domain time sources where applicable rather than assuming the current domain's SRV list is the entire allowed hierarchy.

Tests: actual DC FQDN, short name, trailing dot, same-domain member server, same short prefix in another domain, failed discovery, and relevant PDC/member cases.

Priority P2; moderate regression risk because incomplete discovery and legitimate AD hierarchy choices need care. Plan only. Validate unit, smoke, and integration runners in Windows PowerShell 5.1 without changing time-service configuration.
