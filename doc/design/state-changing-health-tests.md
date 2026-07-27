# State-Changing Health Tests

## Decision

GetComputerHealth advertises its default built-in health checks as read-only. A normal run must not load or execute built-in tests that can change computer state.

The project may still include a state-changing built-in test when all of these conditions apply:

- The operation is considered highly safe on conventional systems and dangerous only in unusual or tightly constrained environments.
- The end-to-end diagnostic value is materially better than passive inspection alone.
- The possible state changes and operational effects are clearly documented.
- The test lives under `health-tests\HealthTests-that-do-change-state`.
- The test is loaded and run only when the administrator supplies `-IReallyWantToRunTestsThatChangeState`.

The long, deliberate switch name is part of the safety design. It prevents accidental execution and makes the administrator's choice visible in scripts, scheduled tasks, transcripts, and reviews.

## Why Safe Tests Are Still Guarded

An operation can be safe and useful without being observationally read-only. Running it at a particular time can trigger work, alter diagnostic timestamps, or be inappropriate during an unusual maintenance freeze, a forensic investigation, or testing on a deliberately isolated computer. Separate storage and explicit opt-in preserve the default read-only contract without discarding valuable active diagnostics.

Conventional installations are encouraged to enable these guarded tests after reviewing their documented behavior. Administrators who operate unusually fragile, isolated, forensically preserved, or tightly change-controlled systems can leave the switch off while retaining the complete read-only suite.

## Current Guarded Tests

`HealthTest-GpupdatePolicyApply` actively runs `gpupdate`. Group Policy refresh is a normal Windows domain operation that occurs automatically and is expected to apply configured settings, scripts, deployments, and Immediate Tasks safely. Running it during a health check provides valuable end-to-end confirmation that the secure channel, domain-controller access, Group Policy client, and applicable policy processing work together. On conventional domain-joined systems, that verification normally outweighs the small cost of performing an additional refresh.

`HealthTest-Dcdiag` actively runs comprehensive DCDIAG diagnostics. DCDIAG is a standard domain-controller administration tool, and some of its checks can create and remove temporary diagnostic data or refresh registrations as part of verification. On conventional domain controllers, these bounded diagnostic actions are designed for routine administration and provide strong corroboration across important Active Directory services. The guarded switch allows unusual or strictly change-controlled environments to defer them.

## Consequences

- `-ListAllBuiltInTests` remains exhaustive and lists both read-only and guarded tests.
- `-OnlyTheseTests` does not override the guard. A guarded test selected by name is unavailable unless the switch is also supplied.
- `Invoke-GetComputerHealth.ps1` forwards the choice consistently to local and remote target runs and across its post-update rerun.
- Routine automated repository tests never enable the switch. Active validation requires mocks or an explicitly chosen test computer.
- Custom health tests remain administrator-controlled code and are outside this built-in classification.
