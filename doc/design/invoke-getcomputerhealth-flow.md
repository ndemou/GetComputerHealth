# Invoke-GetComputerHealth execution flow

*(Interface-level guide mainly for developers)*

For the full documentation routing table, see [`README.md`](../README.md).

This document explains what happens when you run `Invoke-GetComputerHealth.ps1`.
It focuses on observable behavior, inputs, outputs, and handoffs between scripts.
It intentionally avoids low-level implementation details.

## What this script is for

`Invoke-GetComputerHealth.ps1` is the normal entry point for scheduled or fleet health monitoring.
It wraps `Get-ComputerHealth.ps1` so a run can:

- update the installed toolkit before checking health
- choose one or more target computers
- run health checks locally or through PowerShell remoting
- collect all health messages into data files
- create an interactive HTML report
- decide whether to send an email report

If you only want to run the health tests for the current machine and just inspect PS objects or console output, `Get-ComputerHealth.ps1` is enough.

## Inputs at the command line

A run is controlled by these kinds of inputs:

- **Target selection**: no target for the local computer, explicit computer names, or the special domain-server target set.
- **Message filtering**: `-Hide` controls which message levels are hidden from normal console-style output.
- **Test selection**: include only certain tests, exclude certain tests, or skip slow, policy, or non-essential tests.
- **Guarded active diagnostics**: `-IReallyWantToRunTestsThatChangeState` explicitly enables the separately stored built-in tests that can make limited, highly safe state changes.
- **Update behavior**: by default the wrapper may update the installed toolkit before running checks; `-NoUpdate` disables that for the run.
- **Remote-update behavior**: the wrapper can automatically stage a validated local update zip for targets whose version differs from the controller. `-PushUpdate` is not required for this automatic path.
- **Email behavior**: switches and configuration decide whether a report is sent.

## Configuration used during a run

At startup, the wrapper resolves the installed root folders and reads configuration files from the installation layout.
The most important configuration areas are:

- general GetComputerHealth options from `config\gch.psd1`
- email settings used by `Send-Message.ps1`
- suppression signatures from `config\Get-ComputerHealth.sigs-to-suppress.txt`
- optional custom health tests under `config\Custom-HealthTests`
- cached domain-controller IP information, when configured or previously discovered

Configuration is combined with command-line arguments. Explicit command-line switches generally control the current run, while configuration supplies defaults and environment-specific settings.

The default built-in tests avoid intentional configuration and application-data changes. This does not make the wrapper read-only: it updates toolkit files, writes report and suppression data, and maintains logs and caches. Even with `-NoUpdate`, those bookkeeping writes and ordinary diagnostic side effects remain. See the [state-changing test decision](state-changing-health-tests.md).

## High-level run sequence

A typical invocation follows this flow:

1. **Prepare runtime folders and perform light housekeeping**
   - The script makes sure expected log, data, and temp folders exist.
   - Old transcript logs, if any, are cleaned up.

2. **Read local configuration**
   - The wrapper reads available configuration files.
   - It resolves the postponed-suppression display window. Domain-controller IPs are resolved after logging starts, and email settings are read when reports are prepared.

3. **Check for an update**
   - Unless update behavior is disabled, the wrapper runs the updater before health checks.
   - If the installed script version changes, the wrapper invokes its updated file once in the same PowerShell process so the rest of the run uses the updated code.
   - After that invocation returns, the original invocation returns without performing a second health scan or sending a second report.

4. **Start run logging**
   - The wrapper starts a transcript log for the run.
   - It builds report metadata such as the toolkit version and timestamp signature.

5. **Resolve targets**
   - If no computers are supplied, the local computer is checked.
   - If explicit computers are supplied, those names are normalized into a target list.
   - If the special domain-server target set is supplied, domain servers are discovered and excluded servers are removed.

6. **Find a local update package for remotes**
   - When updates are enabled and remote targets exist, the wrapper looks for a local release zip and checks that its embedded version matches the controller's code.
   - A target already matching the controller skips its updater. A target with a different or unknown version receives the validated zip automatically when one is available.
   - If no suitable package is available, targets needing an update use the normal updater path. `-PushUpdate` adds a warning when no local zip is found; it is not required to enable the automatic copy.

7. **Run health checks for each target**
   - For the local computer, the wrapper invokes the health-check flow directly.
   - For remote computers, the wrapper opens a PowerShell remoting session and runs the same target-side flow remotely.
   - Each target may run its own update step unless disabled for that path.
   - Each target then runs `Get-ComputerHealth.ps1` with the selected filters, test selections, suppression file, custom tests folder, and other applicable options.
   - The guarded state-changing test directory is included only when the wrapper received `-IReallyWantToRunTestsThatChangeState`; that choice is preserved for local targets, remote targets, and the one-time post-update rerun.

8. **Collect health messages**
   - Target output is normalized into health message records.
   - PowerShell errors from update or health-check execution are converted into failure records so they appear in reports.
   - Suppression signatures are applied and messages near suppression expiry can be displayed as postponed.

9. **Write report artifacts**
   - All messages are saved in a compressed CLIXML archive under `data` and a latest-findings CLIXML file under `temp`.
   - When notable messages exist, an interactive HTML report containing those messages is saved under `temp`, even if email is disabled.
   - No report artifacts are generated if the collected message list is empty.

10. **Decide whether to send email**
    - Explicit email switches and configuration determine whether the report should be sent.
    - In non-interactive contexts (e.g. run from scheduled tasks), email is normally enabled by default.
    - In interactive contexts (e.g. running from the terminal), email is normally disabled by default unless explicitly requested.

11. **Send the report or finish quietly**
    - If notable messages exist and email is enabled, the wrapper sends a report email with the summary and report artifact.
    - If messages exist but none are notable, the wrapper sends an all-good message when email is enabled and configured. It does not replace the previous interactive report in this case.
    - If email is disabled, artifacts are still available on disk.

## The self-update rerun handoff

The update handoff is the easiest part of the flow to get wrong and introduce subtle bugs.
When the wrapper updates itself, the original invocation has already loaded old code. The current handoff re-reads the updated script in a new invocation within the same PowerShell process:

1. the original invocation detects that the installed version changed
2. it calls the updated `Invoke-GetComputerHealth.ps1` with the call operator
3. it marks that second invocation as the one allowed post-update rerun
4. the second invocation performs target checks and report delivery
5. the original invocation returns as soon as the second invocation completes

That one-time marker (`-AlreadyReranAfterUpdate`) is internal to `Invoke-GetComputerHealth.ps1`. It must not be forwarded to `Get-ComputerHealth.ps1`, which does not declare that parameter.

## Local target flow

For a local target, the wrapper:

1. resolves the current installation root
2. optionally updates the local target files
3. resolves the current `Get-ComputerHealth.ps1`, configuration, custom tests, and suppression file paths
4. calls `Get-ComputerHealth.ps1` with the selected run options
5. converts returned objects and errors into report records

This path does not require PowerShell remoting.

## Remote target flow

For a remote target, the wrapper:

1. creates a PowerShell remoting session to the target
2. determines the target-side installation root
3. skips updating an already matching version, or copies the updater and any validated local release zip when updates are enabled
4. runs the target-side health-check flow in the remote session
5. receives health message records back from the remote target
6. closes the remote session when finished

Remote targets need working PowerShell remoting and an installed toolkit. The wrapper creates missing target `bin` and `temp` folders, but it loads the target's logging helper before running the updater. Copying the updater alone therefore does not bootstrap an empty installation. With `-NoUpdate`, the expected health-test files must also already be present.

## Outputs from a run

A run can produce several observable outputs:

- console progress and status messages
- a transcript log under the installation log folder
- compressed all-message CLIXML archives under `data`
- `temp\last-all-findings.clixml` containing the latest full result set
- `temp\last-interactive-report.html` containing the most recent report with notable messages
- `temp\last-report.html` containing the latest email body, also saved when email is disabled
- an email summary and attachment, when email sending is enabled and warranted

The exact report content depends on message levels, suppression settings, test selection, and whether targets returned failures, warnings, notices, or only routine messages.

## How failures are surfaced

The wrapper tries to make operational failures visible in the same reporting channel as health findings.
For example:

- target-side update-script PowerShell errors become failure records
- terminating update errors become failure records for that target
- health-script PowerShell errors become failure records
- remoting or target execution problems become notable results where possible

This means a report can describe both true health findings and problems encountered while trying to run the health checks.

The controller's initial update check is an exception: non-terminating errors are written to the error stream, and a terminating failure produces a warning before target execution continues. Those early messages are not added directly to the collected report records.

## Mental model

Think of the scripts as three layers:

1. **`Invoke-GetComputerHealth.ps1`** orchestrates update, target selection, remoting, collection, artifacts, and email.
2. **`Get-ComputerHealth.ps1`** runs the actual health tests for one target context.
3. **Health-test scripts** produce individual health messages. Read-only built-ins are the default; the runner includes separately stored state-changing built-ins only with explicit opt-in. Direct execution of an individual guarded test file bypasses that runner selection.

The wrapper should own wrapper-only control flow such as self-update reruns.
The health script should only receive health-check options.
Keeping that boundary clear is important for predictable scheduled monitoring.
