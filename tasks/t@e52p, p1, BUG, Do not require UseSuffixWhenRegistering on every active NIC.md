<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:46.753Z","completions":[]} -->

GitHub source: [#134](https://github.com/ndemou/GetComputerHealth/issues/134) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/134#issuecomment-7062169517)

Confirmed in the per-interface decision: UseSuffixWhenRegistering is required unconditionally. That flag controls additional registration using the connection-specific suffix; its false value is not evidence that primary-suffix registration failed. See [Set-DnsClient parameter semantics](https://learn.microsoft.com/en-us/powershell/module/dnsclient/set-dnsclient).

Proposed fix:

1. Remove the unconditional requirement for UseSuffixWhenRegistering. Evaluate RegisterThisConnectionsAddress for interfaces where registration is actually expected.
2. With an empty suffix, or a suffix equal to the primary DNS suffix, do not fail solely because the extra-registration flag is false.
3. Require that flag only for an explicitly required connection-specific registration. Reuse the narrow baseline configuration proposed in #102 if per-interface expectations are needed; keep custom suffix allowances consistent with the separate suffix-validation branch.
4. Document adapter exclusions and how active interfaces are identified. Verify the existing InterfaceOperationalStatus filter against actual Get-DnsClient records; if necessary, join adapter status by InterfaceIndex instead of silently selecting nothing.
5. Missing settings or failed discovery mean incomplete coverage. Replace the current advice to enable both flags everywhere. Leave unrelated primary-suffix/devolution policy changes out of this fix.

Tests: the reported empty-suffix example, domain-matching suffix, optional/required custom suffix registration, disabled primary registration on an applicable interface, exclusions, absent status properties, and failed discovery.

Priority P1; low to moderate risk if the false-failure fix stays narrow and additional configurable policy is introduced separately. Plan only. Validate unit and smoke, then read-only integration on a domain member under Windows PowerShell 5.1.
