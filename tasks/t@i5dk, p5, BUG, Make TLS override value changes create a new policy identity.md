<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:45.934Z","completions":[]} -->

GitHub source: [#123](https://github.com/ndemou/GetComputerHealth/issues/123) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/123#issuecomment-7061940201)
Related TAT task: [t@cuhb Check .NET Framework TLS defaults](./t%40cuhb%2C%20p5%2C%20FEATURE%2C%20Check%20.NET%20Framework%20TLS%20defaults.md)

Confirmed by static review of `HealthTest-ListTlsRegistryOverrides.ps1`, `Convert-TextToLogRecord`, and `Log-Msg`. The first line contains only path/name; the value and registry type become comments and are excluded from the signature. A policy inventory can therefore keep suppressing a changed TLS configuration.

The stable-title behavior is explicitly documented and tested, but it conflicts with detecting configuration changes in a policy test. This is not a request to classify every override as insecure.

Proposed fix:

1. Append a compact fingerprint of registry kind and full, normalized value to the finding's first line. Keep path/name readable and retain explanatory details.
2. Use deterministic, type-aware serialization before hashing. Keep array order, item boundaries, null versus empty, and all bytes significant. Normalize only formatting known to be irrelevant for the particular setting. Do not lowercase arbitrary values, sort cipher priorities, or hash the truncated display text.
3. Reuse the existing SHA-256 short-hash helper where suitable. Keep the serialization specific to this test and leave the shared logging/signature algorithm unchanged.
4. Update the help text and replace the existing test that requires path/name-only identity. Increase this test's policy baseline version from 1 to 2.
5. Explicitly test and document the baseline transition. A version bump causes the runner to auto-baseline the current configuration once by default; it does not force review of that first snapshot. `-DontAutosetPolicy` is available when that snapshot needs manual review. Subsequent value/type changes must become unsuppressed without another baseline reset.

Test unchanged values, a value change, a type change, harmless formatting for supported list settings, meaningful order changes, array-boundary differences, and changes beyond the display truncation limit. Include a runner-level test that baselines one value, changes it, and checks the actual suppression result.

Regression risk is moderate because finding identities change intentionally. This remains worthwhile because otherwise security-relevant changes can be invisible. Keep the migration limited to this one policy test.

Plan only. No code changed or tests run. Validate with the unit and smoke runners under Windows PowerShell 5.1.
