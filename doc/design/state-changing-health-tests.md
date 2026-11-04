# State-Changing Health Tests

## Decision

GetComputerHealth's default built-in health checks inspect the system without intentionally changing its configuration or application data. A normal health run through `Get-ComputerHealth.ps1` or `Invoke-GetComputerHealth.ps1` must not load or execute the separately classified state-changing tests unless explicitly enabled.

Read-only describes that diagnostic intent. It does not mean that running a query leaves no trace. Queries can send network requests, populate caches, generate operating-system or application logs, and cause Windows to start a service on demand. For example, WMI can start when a client connects, and `vssadmin list writers` invokes writer callbacks that SQL Server logs. See [WMI service behavior](https://learn.microsoft.com/en-us/windows/win32/wmisdk/winmgmt) and [SQL Server VSS Writer logging](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/sql-server-vss-writer-logging).

The runner also saves its own findings, suppression state, and policy baselines. The wrapper writes reports and logs and normally runs the updater. Those toolkit operations are separate from the built-in test classification; the read-only claim is not a promise of a forensic scan with no writes.

The project may still include a state-changing built-in test when all of these conditions apply:

- The operation is considered highly safe on conventional systems and dangerous only in unusual or tightly constrained environments.
- The end-to-end diagnostic value is materially better than passive inspection alone.
- The possible state changes and operational effects are clearly documented.
- The test lives under `health-tests\HealthTests-that-do-change-state`.
- During a health run through the standard entry points, the test is loaded and run only when the administrator supplies `-IReallyWantToRunTestsThatChangeState`.

The long, deliberate switch name is part of the safety design. It prevents accidental selection through the standard entry points and makes the administrator's choice visible in scripts, scheduled tasks, transcripts, and reviews. It is a runner selection guard, not an execution restriction on the individual files. Directly executing either guarded `.ps1` file runs its test without this switch; dot-sourcing it defines functions without running the test.

## Why Safe Tests Are Still Guarded

An operation can be safe and useful without being observationally read-only. Running it at a particular time can trigger work, alter diagnostic timestamps, or be inappropriate during an unusual maintenance freeze, a forensic investigation, or testing on a deliberately isolated computer. Separate storage and explicit opt-in preserve the default read-only contract without discarding valuable active diagnostics.

Conventional installations are encouraged to enable these guarded tests after reviewing their documented behavior. Leaving the switch off excludes these active operations. Administrators of forensically preserved or tightly change-controlled systems must also account for the ordinary diagnostic and toolkit effects described above.

## Current Guarded Tests

`HealthTest-GpupdatePolicyApply` actively runs `gpupdate`. Group Policy refresh is a normal Windows domain operation that occurs automatically and is expected to apply configured settings, scripts, deployments, and Immediate Tasks safely. Running it during a health check provides valuable end-to-end confirmation that the secure channel, domain-controller access, Group Policy client, and applicable policy processing work together. On conventional domain-joined systems, that verification normally outweighs the small cost of performing an additional refresh.

`HealthTest-Dcdiag` actively runs comprehensive DCDIAG diagnostics. DCDIAG is a standard domain-controller administration tool, and some of its checks can create and remove temporary diagnostic data or refresh registrations as part of verification. On conventional domain controllers, these bounded diagnostic actions are designed for routine administration and provide strong corroboration across important Active Directory services. The guarded switch allows unusual or strictly change-controlled environments to defer them.

## Consequences

- `-ListAllBuiltInTests` dot-sources definitions from both directories to read their metadata, then lists the tests without executing their health-test functions. This listing mode does not require the state-change switch.
- `-OnlyTheseTests` does not override the guard. A guarded test selected by name is unavailable unless the switch is also supplied.
- `Invoke-GetComputerHealth.ps1` forwards the choice consistently to local and remote target runs and across its post-update rerun.
- Routine automated repository tests must not run real state-changing operations. They may exercise opt-in selection with mocked operations; active validation requires an explicitly chosen test computer.
- Custom health tests remain administrator-controlled code and are outside this built-in classification.
