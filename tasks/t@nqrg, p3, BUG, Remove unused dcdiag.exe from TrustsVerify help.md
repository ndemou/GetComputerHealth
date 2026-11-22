<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:44.108Z","completions":[]} -->

GitHub source: [#91](https://github.com/ndemou/GetComputerHealth/issues/91) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/91#issuecomment-7062031631)

Confirmed as a documentation bug in `HealthTest-TrustsVerify.ps1`. The function invokes Get-ADTrust and netdom.exe; it never invokes dcdiag.exe.

Proposed fix: change the Uses line to list only netdom.exe and Get-ADTrust. Preserve all trust queries, commands, and findings.

Validation: run the existing help-block/unit suite and check the Uses list against the function. No new behavioral test is needed for this text-only correction.

Priority P3; very low regression risk. Bundle with #90 and #92. Plan only, no implementation or test execution.
