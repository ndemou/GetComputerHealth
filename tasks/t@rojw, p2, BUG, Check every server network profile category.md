<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:45.825Z","completions":[]} -->

GitHub source: [#122](https://github.com/ndemou/GetComputerHealth/issues/122) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/122#issuecomment-7062161693)

Confirmed as a coverage gap in NetworkConnectionProfiles: the code only asks whether any server profile matches the expected category. One detail in the report is overstated: the current PASS says "Found interface on expected NLA category", which is literally true for a mixed set; it does not explicitly claim every profile passed. The unexpected profiles are still omitted.

Proposed fix:

1. Define relevant active profiles and any explicit special-purpose exclusions. Do not use Internet connectivity as the test for whether an interface is active.
2. Evaluate each relevant server profile against its documented expectation and identify interface index/name plus current category in findings.
3. Preserve the existing workstation applicability rule and keep Internet-connectivity findings separate.
4. Emit an all-applicable-profiles PASS only when every evaluated profile matches and discovery completed.
5. Avoid assuming every secondary domain-server network must be DomainAuthenticated. Backup, management, and isolated networks need documented exceptions; apply the baseline to the intended interfaces.

Tests: mixed DomainAuthenticated/Public profiles, all matching, inactive profile, configured special-purpose exception, standalone server, workstation, and failed discovery.

Priority P2; moderate false-positive risk until interface expectations are explicit. Plan only. Validate unit, smoke, and integration under Windows PowerShell 5.1; never restart adapters during tests.
