<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:45.626Z","completions":[]} -->

GitHub source: [#119](https://github.com/ndemou/GetComputerHealth/issues/119) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/119#issuecomment-7062102485)

Confirmed: GpupdatePolicyApply searches English success sentences and never checks native exit status. A successful localized refresh can be labeled failed.

Proposed fix:

1. Capture command-start outcome, exit status, and raw output immediately.
2. Prefer one reliable overall result rather than guessing separate computer/user results from translated prose. If per-target results are required, run explicitly scoped targets and validate each result.
3. Define completion and timeout behavior before treating exit 0 as completed policy application. The [gpupdate wait option](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/gpupdate) can let the caller continue before processing finishes; a timeout/in-progress result must not become PASS.
4. Under SYSTEM, check computer policy and describe user-policy applicability accurately. An unavailable interactive user is not proof of a user-policy failure.
5. Keep the existing secure-channel prerequisite and state-changing opt-in guard. Do not add forced refresh, reboot, or logoff options.

Tests: English/localized completion, nonzero exit, process-start failure, incomplete/timeout outcome, SYSTEM, interactive user, and failed secure-channel check. Mock every gpupdate invocation.

Priority P2; moderate risk because completion semantics and execution context matter. Plan only. Validate unit and smoke runners under Windows PowerShell 5.1 without enabling real state-changing tests.
