<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:43.881Z","completions":[]} -->

GitHub source: [#87](https://github.com/ndemou/GetComputerHealth/issues/87) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/87#issuecomment-7062027079)

Partly confirmed, with a distinction in the current code. Startup-folder enumeration uses SilentlyContinue and can produce the false empty PASS described. Registry reads do not all suppress errors: the normal runner sets ErrorActionPreference=Stop, so some registry failures abort the test instead. The broader need to preserve partial results and identify failed locations is valid.

Proposed fix:

1. Wrap existence checks and reads per registry/folder location, using terminating errors. Track successful, missing, unavailable, and failed locations separately.
2. Keep discovered items from readable locations and continue after an individual failure.
3. Handle folder-path lookup failures explicitly. An actually absent Startup folder is different from an inaccessible one.
4. Emit one bounded WARNING summary for failed locations. Emit the no-items PASS only if every applicable location was inspected or confirmed absent.
5. Preserve existing startup-item fingerprints and baseline version unless their identity actually changes. Check incomplete-discovery reporting through the policy runner as well as direct invocation.

Tests: complete success, truly empty/missing locations, folder access denied, registry access denied, one successful location alongside failures, and all locations failing.

Priority P2; low to moderate regression risk, mostly around missing-location semantics and policy suppression. Plan only. Validate with unit and smoke runners under Windows PowerShell 5.1.
