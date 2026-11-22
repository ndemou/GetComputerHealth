<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:46.377Z","completions":[]} -->

GitHub source: [#130](https://github.com/ndemou/GetComputerHealth/issues/130) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/130#issuecomment-7062166313)

Confirmed: with no expected roots, both checks default to true and the result claims the paths are sane without a comparison. There is also a boundary issue in the existing prefix match: an expected D:\NTDS root can accept D:\NTDS-old.

Proposed fix:

1. Read expected database/log roots through the shared baseline mechanism proposed in #102, with explicit function arguments taking precedence.
2. Treat each component independently: unconfigured database/log expectations are INFO inventory, not validated PASS. A final claim covering both requires both comparisons to have been performed successfully.
3. Normalize absolute Windows paths and compare case-insensitively at directory boundaries. Do not use wildcard prefix matching for configured literal roots.
4. Preserve per-component findings for actual mismatches. Unreadable registry values or malformed configuration are unknown/incomplete, not healthy.
5. Document what a configured root means, including drive roots, child paths, and partial configuration. Do not invent a universal required drive letter.

Tests: configured match/mismatch, no configuration, only one configured component, explicit overrides, inaccessible registry data, trailing separators, case differences, and D:\NTDS versus D:\NTDS-old.

Priority P2; moderate risk, mainly shared configuration and path semantics. Implement with #102/#129. Plan only. Validate unit, smoke, and installed-runtime configuration handling under Windows PowerShell 5.1.
