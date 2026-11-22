<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:46.209Z","completions":[]} -->

GitHub source: [#126](https://github.com/ndemou/GetComputerHealth/issues/126) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/126#issuecomment-7062164329)

Confirmed in the current source: the filter recognizes only English output, treats every remaining line as FAILURE, and never checks the native exit code. That can reject a successful localized run and does not reliably establish success either.

Proposed fix:

1. Capture complete DFSDIAG output and the process exit code immediately, before filtering or formatting.
2. A failed start or nonzero exit must prevent PASS. Keep the original output available for diagnosis.
3. Replace the broad English whitelist with result handling whose success contract is verified. Do not assume exit code zero alone proves every diagnostic passed unless that behavior is documented and validated.
4. Until a reliable success signal is available for a particular output format, report WARNING/incomplete with the raw evidence. Unfamiliar translated output is not proof of a DFS failure.
5. Keep any parser small and explicit about supported results; avoid a growing list of translated English phrases.

Tests: known successful English output, localized output, unknown/truncated/empty output, diagnostic failure, nonzero exit, and process-start failure. Mock the native command; no live domain diagnostic is needed for unit coverage.

Priority P2; moderate risk because the native diagnostic's success contract must be established. Plan only. Validate unit and smoke under Windows PowerShell 5.1, then controlled integration against supported Windows languages.
