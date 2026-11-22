<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:45.523Z","completions":[]} -->

GitHub source: [#118](https://github.com/ndemou/GetComputerHealth/issues/118) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/118#issuecomment-7062101842)

Confirmed: Get-DcDiagFailures returns only recognized English failure blocks. Zero recognized blocks and a complete successful run are indistinguishable, and native exit status is ignored.

Proposed fix:

1. Return inspection evidence that includes exit status, recognized started/completed test counts, incomplete blocks, and failures. Preserve the existing detailed failure information.
2. Capture each DCDIAG invocation's status and raw output. A nonzero code or process error prevents all-clear; code 0 alone does not prove every diagnostic passed.
3. Treat unrecognized/localized or truncated output as incomplete until a validated parser can account for it. Do not solve this by translating a few keywords and assuming coverage.
4. Preserve the basic-versus-comprehensive distinction and the existing lower severity for event-log diagnostics.
5. Keep this test in the state-changing folder behind the existing opt-in guard. No real DCDIAG runs belong in routine regression tests.

Tests: complete English success/failure, localized unparsed output, partial blocks, nonzero exit, missing executable, and an incomplete second/basic invocation. Preserve output-compression tests.

Priority P2 because the test is opt-in, with moderate parser/API-contract risk. The first implementation should eliminate false PASS on unknown output; full localization can follow separately.

Plan only. Validate unit and smoke runners under Windows PowerShell 5.1 without enabling state-changing tests.
