<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:43.742Z","completions":[]} -->

GitHub source: [#83](https://github.com/ndemou/GetComputerHealth/issues/83) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/83#issuecomment-7062023565)

Confirmed in `HealthTest-ListInstalledPrograms.ps1`. Registry/Appx failures become verbose messages, while the caller decides "no software" solely from the number of returned entries. This loses the distinction between empty and unreadable sources.

Proposed fix:

1. Track each registry hive/view and the Appx source as successful, legitimately absent/not applicable, or failed. Keep software found before a failure.
2. Return discovery status separately from software entries. Check existing callers before changing the helper contract; do not put status objects into the software pipeline.
3. Use per-key recovery where possible and close registry handles in finally blocks. Aggregate errors by source with a bounded sample of affected keys.
4. Emit one incomplete-discovery WARNING and suppress the empty-inventory PASS if any applicable source failed. Missing optional Appx support is not proof of a broken machine.
5. Preserve software normalization, severity, and policy identities. Check how the warning behaves during policy auto-baselining; do not silently describe a failed inventory as a completed baseline.

Tests: all sources empty, populated success, missing optional source, partial failure retaining entries, and total failure. Mock registry access through the smallest practical seam and cover Appx exceptions.

Priority P2; regression risk low to moderate because the helper's return contract needs care. Plan only, no implementation or test execution. Validate with the unit and smoke runners in Windows PowerShell 5.1.
