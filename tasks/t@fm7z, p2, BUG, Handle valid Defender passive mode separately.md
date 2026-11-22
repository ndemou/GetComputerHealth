<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:46.838Z","completions":[]} -->

GitHub source: [#135](https://github.com/ndemou/GetComputerHealth/issues/135) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/135#issuecomment-7062170008)

Confirmed: all feature checks assume Normal mode, so passive mode produces a cascade of failures without evaluating the active-protection arrangement. Passive mode alone also does not prove that another healthy antivirus is active. Microsoft documents different client/server requirements and behavior: [Defender compatibility](https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-antivirus-compatibility).

Proposed fix:

1. Classify Defender's reported operating mode before applying feature expectations. Keep the existing active-Defender checks for Normal mode.
2. For passive mode, report one coherent posture result and identify independently confirmed active protection where a supported read-only source exists.
3. Do not treat an installed product name, passive mode, or configuration intent alone as proof of active protection. Do not assume Windows Security Center inventory is available on every Windows Server installation.
4. Distinguish confirmed passive-plus-active protection, inability to verify protection, confirmed absence of protection, and failed status collection. Unknown status must not become PASS.
5. Retain signature checks where relevant to passive Defender/MDE operation; do not blanket-skip all Defender health checks. Document applicability per supported mode/platform.
6. Coordinate scan applicability with #85, but keep the install-date correctness fix independent of this broader product-detection work.

Tests: active healthy/broken Defender, confirmed valid passive mode, passive mode with unavailable protection evidence, confirmed no protection, other/unknown operating mode, status-query error, and passive signature freshness.

Priority P2; moderate to high risk because supported third-party evidence and client/server behavior differ. Plan only. Validate unit and smoke with mocked providers, followed by representative read-only integration under Windows PowerShell 5.1.
