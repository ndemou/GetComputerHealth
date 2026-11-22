<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:44.732Z","completions":[]} -->

GitHub source: [#102](https://github.com/ndemou/GetComputerHealth/issues/102) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/102#issuecomment-7062067187)

Confirmed: the normal runner invokes the function without RequiredKBs, so the current built-in check returns PASS without checking a baseline. I would not hard-code a timeless universal KB list; required and superseding updates depend on OS and servicing policy.

Proposed fix:

1. Add a narrow read-only baseline data file under the existing runtime CONFIG_DIR, proposed name health-test-baselines.psd1. Use Import-PowerShellDataFile and validate supported fields; do not execute arbitrary configuration scripts or build a generic command dispatcher.
2. Share that configuration mechanism with #129 and #130, and optionally #101. Resolve it from the installation's config directory, not the process working directory.
3. Preserve explicit RequiredKBs arguments as the highest-precedence override. Normal no-argument invocation reads the configured list.
4. Unconfigured means INFO/skipped, malformed or unreadable means WARNING, and only a successful comparison can PASS. Remove the unconfigured no-op from the Essential promise.
5. Document that exact KB presence is not a complete Windows-update health check and can require baseline maintenance for superseded updates.

Tests: normal runner with and without configuration, configured missing KB, all present, explicit override, malformed file, Get-HotFix error, and installed-runtime path resolution. Ensure installation/update preserves user configuration.

Priority P2; moderate risk due to shared configuration plumbing. Plan only. Validate unit, smoke, and installer/runtime integration under Windows PowerShell 5.1.
