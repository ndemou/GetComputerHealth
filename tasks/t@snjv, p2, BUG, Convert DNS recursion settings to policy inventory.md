<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:44.410Z","completions":[]} -->

GitHub source: [#98](https://github.com/ndemou/GetComputerHealth/issues/98) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/98#issuecomment-7062063574)

Confirmed: HealthTest-DnsRecursionConfig reports PASS when any of three queries returns an object, without validating the values. I do not recommend inventing one universal recursion/cache/EDNS baseline; authoritative-only and recursive DNS servers have different requirements.

Proposed fix:

1. Convert the default behavior to policy inventory, with accurate Description, Tags: Policy, identity documentation, and an initial baseline version.
2. Read each source independently with explicit error handling. Record unavailable commands/properties separately from actual settings; verify the property names returned by supported Windows Server versions instead of retaining assumptions such as EnableRecursion.
3. Emit reviewable setting findings whose first-line fingerprint includes the setting identity and normalized value. Keep volatile runtime counters out of the identity.
4. Report incomplete discovery separately and never describe it as healthy. Define and test the interaction with policy auto-baselining.
5. If a compliance baseline is later required, add it as explicit organization configuration rather than hard-coding a DNS design here.

Tests: two different recursion configurations produce different identities, unchanged values remain stable, missing properties are unknown, and one failed query does not hide readable settings.

Priority P2; moderate regression risk because this changes classification and policy behavior. Plan only. Validate metadata, policy-runner, unit, and smoke tests in Windows PowerShell 5.1.
