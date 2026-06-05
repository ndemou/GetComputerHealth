# Invoke-GetComputerHealth execution flow

*(Interface-level guide for operators and developers)*

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

If you only want to run the health tests for the current machine and inspect objects or console output directly, `Get-ComputerHealth.ps1` is the lower-level script.
If you want scheduled monitoring, remote targets, report files, and email behavior, use `Invoke-GetComputerHealth.ps1`.

## Inputs at the command line

A run is controlled by these kinds of inputs:

- **Target selection**: no target for the local computer, explicit computer names, or the special domain-server target set.
- **Message filtering**: `-Hide` controls which message levels are hidden from normal console-style output.
- **Test selection**: include only certain tests, exclude certain tests, or skip slow, policy, or non-essential tests.
- **Update behavior**: by default the wrapper may update the installed toolkit before running checks; `-NoUpdate` disables that for the run.
- **Remote-update behavior**: optional push-update settings can stage an update zip for remote targets.
- **Email behavior**: switches and configuration decide whether a report is sent.
- **Pass-through arguments**: extra arguments can be forwarded to `Get-ComputerHealth.ps1` for supported lower-level options.

## Configuration used during a run

At startup, the wrapper resolves the installed root folders and reads configuration files from the installation layout.
The most important configuration areas are:

- general GetComputerHealth options from `config\gch.psd1`
- email settings used by `Send-Message.ps1`
- suppression signatures from `config\Get-ComputerHealth.sigs-to-suppress.txt`
- optional custom health tests under `config\Custom-HealthTests`
- cached domain-controller IP information, when configured or previously discovered

Configuration is combined with command-line arguments. Explicit command-line switches generally control the current run, while configuration supplies defaults and environment-specific settings.

## High-level run sequence

A typical invocation follows this flow:

1. **Prepare runtime folders**
   - The script makes sure expected log, data, and temp folders exist.
   - Old transcript logs may be cleaned up.

2. **Read local configuration**
   - The wrapper reads available configuration files.
   - It resolves settings such as postponed-suppression display windows, email behavior, and domain-controller IPs.

3. **Check for an update**
   - Unless update behavior is disabled, the wrapper runs the updater before health checks.
   - If the installed script version changes, the wrapper starts itself again once so the rest of the run uses the updated code.
   - After starting the updated copy, the original pre-update process exits instead of continuing. This prevents duplicate reports from one scheduled task run.

4. **Start run logging**
   - The wrapper starts a transcript log for the run.
   - It builds report metadata such as the toolkit version and timestamp signature.

5. **Resolve targets**
   - If no computers are supplied, the local computer is checked.
   - If explicit computers are supplied, those names are normalized into a target list.
   - If the special domain-server target set is supplied, domain servers are discovered and excluded servers are removed.

6. **Optionally prepare a local update package for remotes**
   - When push-update behavior is requested, the wrapper finds the newest local release zip it can use for target machines.
   - If no suitable package is available, the run continues with normal update behavior.

7. **Run health checks for each target**
   - For the local computer, the wrapper invokes the health-check flow directly.
   - For remote computers, the wrapper opens a PowerShell remoting session and runs the same target-side flow remotely.
   - Each target may run its own update step unless disabled for that path.
   - Each target then runs `Get-ComputerHealth.ps1` with the selected filters, test selections, suppression file, custom tests folder, and other applicable options.

8. **Collect health messages**
   - Target output is normalized into health message records.
   - PowerShell errors from update or health-check execution are converted into failure records so they appear in reports.
   - Suppression signatures are applied and messages near suppression expiry can be displayed as postponed.

9. **Write report artifacts**
   - All collected messages are saved as data.
   - Notable messages are saved separately.
   - An interactive HTML report is generated when there is report data to show.

10. **Decide whether to send email**
    - Explicit email switches and configuration determine whether the report should be sent.
    - In non-interactive scheduled contexts, email is normally enabled by default.
    - In interactive contexts, email is normally disabled by default unless explicitly requested.

11. **Send the report or finish quietly**
    - If notable messages exist and email is enabled, the wrapper sends a report email with the summary and report artifact.
    - If no notable messages exist, the wrapper may send an all-good message depending on configuration.
    - If email is disabled, artifacts are still available on disk.

## The self-update rerun handoff

The update handoff is the easiest part of the flow to misunderstand.
When the wrapper updates itself, continuing in the original process is unsafe because that process has already loaded and evaluated old code.
The intended behavior is:

1. the original invocation detects that the installed version changed
2. it launches a second invocation of `Invoke-GetComputerHealth.ps1`
3. it marks that second invocation as the one allowed post-update rerun
4. it exits immediately
5. the second invocation performs target checks and report delivery

That one-time marker is internal to `Invoke-GetComputerHealth.ps1`.
It is not a `Get-ComputerHealth.ps1` option and must not be forwarded to the child health script.
If that internal marker reaches the child script, PowerShell can bind it in surprising ways and produce misleading parameter errors.
For that reason, the wrapper guards the boundary before invoking `Get-ComputerHealth.ps1` and fails loudly if an internal wrapper-only argument is about to cross it.

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
3. optionally stages update material when push-update mode is requested
4. runs the target-side health-check flow in the remote session
5. receives health message records back from the remote target
6. closes the remote session when finished

Remote targets therefore need working PowerShell remoting and access to the expected GetComputerHealth installation layout on the target.

## Outputs from a run

A run can produce several observable outputs:

- console progress and status messages
- a transcript log under the installation log folder
- all-message data files under the data folder
- notable-message data files under the data folder
- an interactive HTML report under the data folder
- an email summary and attachment, when email sending is enabled and warranted

The exact report content depends on message levels, suppression settings, test selection, and whether targets returned failures, warnings, notices, or only routine messages.

## How failures are surfaced

The wrapper tries to make operational failures visible in the same reporting channel as health findings.
For example:

- update-script PowerShell errors become failure records
- terminating update errors become failure records for that target
- health-script PowerShell errors become failure records
- remoting or target execution problems become notable results where possible

This means a report can describe both true health findings and problems encountered while trying to run the health checks.

## Mental model

Think of the scripts as three layers:

1. **`Invoke-GetComputerHealth.ps1`** orchestrates update, target selection, remoting, collection, artifacts, and email.
2. **`Get-ComputerHealth.ps1`** runs the actual health tests for one target context.
3. **Health-test scripts** produce individual health messages.

The wrapper should own wrapper-only control flow such as self-update reruns.
The health script should only receive health-check options.
Keeping that boundary clear is important for predictable scheduled monitoring.
