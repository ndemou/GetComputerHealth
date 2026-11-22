<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:45.180Z","completions":[]} -->

GitHub source: [#111](https://github.com/ndemou/GetComputerHealth/issues/111) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/111#issuecomment-7062097283)

Confirmed against the code and the [RODC object specification](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-adts/73d11ea7-e634-453e-944d-559654cc91c5). The operational password-replication policy belongs to the RODC computer object; the code queries NTDSSettingsObjectDN instead.

Proposed fix:

1. Use each RODC's ComputerObjectDN as the explicit Get-ADObject identity and request the two PRP attributes there.
2. Validate that the computer-object identity is present. Separate failed discovery/query from a successful query with empty policy values.
3. Catch failures per RODC, include its hostname/identity and error details, and continue other RODCs. Any incomplete query blocks the all-RODC PASS.
4. Preserve normal configured-RODC and no-RODC handling. An empty explicit policy should be reported as such; do not describe it as proof that passwords are being insecurely cached.

Tests: assert the exact computer DN passed to the query, normal allow/deny lists, empty values, missing identity, query failure, and a second RODC still inspected after failure.

Priority P1; low regression risk with a precise identity assertion. Plan only. Validate mocked AD unit tests and smoke/integration under Windows PowerShell 5.1.
