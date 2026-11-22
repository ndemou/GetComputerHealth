<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:44.178Z","completions":[]} -->

GitHub source: [#92](https://github.com/ndemou/GetComputerHealth/issues/92) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/92#issuecomment-7062033377)

Confirmed as a documentation mismatch. The contributor guide omits DEBUG, while Log-Msg accepts debug and DcDnsRegistration emits it. Debug visibility is controlled by the existing Hide setting.

Proposed fix:

1. Add DEBUG to the supported level list and explain that it is for diagnostic detail normally hidden from routine reports.
2. Check the linked custom-test guide and any validation lists for agreement with the six levels accepted by Log-Msg.
3. Preserve the distinction between valid DEBUG output and a useful health result. A test should not substitute debug-only output for the PASS/problem finding it owes the caller.
4. Leave logging behavior and default visibility unchanged.

Validation: review documentation links and existing level-parser tests. Add a parser case only if DEBUG acceptance is currently untested; avoid a test that merely checks one documentation sentence.

Priority P3; very low regression risk. Bundle with #90 and #91. Plan only, no code changed or tests run.
