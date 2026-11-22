<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:46.559Z","completions":[]} -->

GitHub source: [#132](https://github.com/ndemou/GetComputerHealth/issues/132) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/132#issuecomment-7062168167)

Partly confirmed, partly already fixed. Current main still skips every task under \Microsoft\Windows\ through legacyExclusions. The blanket Office exclusion described in the report is already gone: specific Office exceptions now check task identity, executable path, and Authenticode signer, and emit INFO with definition details. Unknown Office tasks remain reportable.

Proposed fix:

1. Remove the Windows-folder blanket exclusion. A persistent task must not disappear merely because its name starts with a Microsoft-looking path.
2. Route those persistent tasks through the existing stable-key/definition-fingerprint policy mechanism so new or changed definitions can be reviewed after a baseline exists.
3. Retain low noise through the existing baseline process and, only where needed, narrowly reviewed exceptions. A Microsoft signature alone must not become a general exception for arbitrary task definitions.
4. Preserve the current explicit Office exception behavior and intentional transient-task INFO behavior; do not reintroduce path-only Office suppression.
5. Review policy-baseline versioning before rollout. Explain whether newly included existing tasks are baselined automatically and that the first snapshot is not a security assessment; later additions/changes must remain detectable.
6. Update the existing test that expects all Windows-folder tasks to be skipped.

Tests: the UnexpectedUpdater example running as SYSTEM, changed action/principal/trigger, a known built-in task through the baseline lifecycle, an unknown Office task, valid/invalid signed exceptions, and transient tasks.

Priority P2; meaningful security-inventory value, but moderate to high rollout/noise risk. Implement after the simpler false-PASS fixes. Plan only. Validate unit and smoke plus baseline migration/inventory integration under Windows PowerShell 5.1.
