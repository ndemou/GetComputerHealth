<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:37:07.030Z","completions":[]} -->

Some tests that have Scope: Domain should ideally be executed on one DC only or on one server only.

Here are some tests that can be run from any domain controller and need only run once:

- `HealthTest-ADReplicationHealth` (check whether its local RSAT fallback still needs per-DC execution)
- "HealthTest-SysvolNetlogonAccessible"
- "HealthTest-SchemaVersionConsistency"
- "HealthTest-TombstoneLifetime"
- "HealthTest-RecycleBinEnabled"

Use the built-in `HostRequirement` metadata to pick eligible hosts. Respect Domain and Forest scopes when deciding where a test should run once.

I also need a way to tell if a `RUN_ONCE` test was executed on one server. Examples: Maybe `Invoke-GetComputerHealth.ps1` detects it from the output. Maybe the computer that executes it places a flag in NETLOGON\GCH\temp. In this case an identifier for each run (e.g. the timestamp when the tests started) must be passed to all targets so that it can be included in the flag.

Custom AD and network health tests should also use this functionality. Run AD tests from a DC and network tests from hosts with access to the network segment being checked. Custom tests can have tags to allow or exclude specific hosts. The online HTTPS certificate check is one use case ([#137](https://github.com/ndemou/GetComputerHealth/issues/137)).
