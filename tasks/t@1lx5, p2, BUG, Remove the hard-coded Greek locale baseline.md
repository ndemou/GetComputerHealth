<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:44.646Z","completions":[]} -->

GitHub source: [#101](https://github.com/ndemou/GetComputerHealth/issues/101) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/101#issuecomment-7062066390)

Confirmed: DefaultLocale is Essential on all hosts, but treats Greek ACP/OEMCP 1253/737 as the universal healthy baseline. This is an organization-specific compatibility requirement, not a general Windows health rule.

Proposed fix:

1. Make expected ACP/OEMCP an explicit optional baseline. Reuse the narrow data-file mechanism proposed in #102 rather than introducing another configuration source.
2. With no baseline, emit INFO describing the actual values and that compatibility was not evaluated. Do not warn merely because a host is English or uses another supported locale.
3. With a valid configured baseline, compare both values and explain the expected pair in mismatch findings.
4. Treat unreadable or malformed data/configuration as unknown. Do not silently substitute Greek defaults.
5. Remove the Essential designation from an unconfigured organization-specific check and update help/examples. Do not change the computer's locale.

Tests: Greek matching/mismatching baseline, English matching baseline, no baseline, another locale, and unreadable/malformed configuration through normal runner invocation.

Priority P2; moderate migration risk because existing deployments may intentionally depend on the Greek rule. Document the explicit baseline needed to retain that behavior. Plan only. Validate unit, smoke, and configuration/installer integration in Windows PowerShell 5.1.
