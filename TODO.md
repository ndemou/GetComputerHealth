# TODO

## More consisse messages by Invoke-GetComputerHealth.ps1

When I run Invoke-GetComputerHealth.ps1 all these messages should only appear if I use -Verbose:
```
[pass 1/2] Parameters: Reinstall=False UpdateFromZip='' Version='' ForceRefreshReleaseMetadata=False ConfigSupplied=False SelfRerunCount=0 PersistReleaseMarker=''
[pass 1/2] Latest release marker is 'ndemou/GetComputerHealth|v8.5.8|339220809'
Stored installed release marker is 'ndemou/GetComputerHealth|v8.5.8|339220809'
Latest release already downloaded and -Reinstall was not specified; skipping update download
...
Preparing notable report
```

Also: the remail report decision is extremely verbose. Look I get two lines of reporting:
```
Email report decision: Email sending disabled by default because the script is running in an interactive context.
Will not send email report. Reason: Email sending disabled by default because the script is running in an interactive context.
```
This would be enough:
```
Email sending disabled by default because the script is running in an interactive context.
```

## All HealthTest code should be under folder health-tests 

Move helpers-for-healthtests.ps1 under the `health-tests` folder.

Update CONTRIBUTING.md with this goal/philosophy and the rules above that align with it (at leaset sections Placement and Repository Layout).

## If the user wants to run a specific HealthTest function they must be able to do it after dot-sourcing *as little code as possible*

First two definitions: Let's call a function, a "specific HealthTest helper function" if it is needed only for one health test. Let's call a function, a "domain helper function" if it is needed for a class of domain specific health tests (e.g. the function that returns the description of a scheduled task which is useful for the domain of health tests that check for issues in Scheduled tasks). Let's call a function, a "generic helper function" if it is needed for a range of unrelated health tests (e.g. the Get-PropValue function that returns the property X of object Y, with a default of $null if the property doesn't exist).

Move all generic helper functions in helpers-for-healthtests.ps1 and dot-source it from each separate ps1 file that uses generic helpers.

Move each HealthTest functions and its specific HealthTest helpers and domain helpers on its own ps1 file. Exception: if a group of HealthTest functions need the same domain-specific helper(s), move all of them in one file. 

Update CONTRIBUTING.md with this goal/philosophy and the rules above that align with it (at leaset sections Placement and Repository Layout).

## HealthTest-UnexpectedListeningPorts -> HealthTest-ListListeningPorts

Follow the spirit of the change that gave us HealthTest-ListServices, ListShares, ListLocalAdmins, ListLocalAdmins a few commits ago.

Also: are there other HealthTests that fit this style (a function that emits a list of findings where some items are accepted and some are not based on policy)

## Option IpsOfAllDcs in gch.psd1
The trick with `cache.IpsOfAllDcs.clixml` is a hack. I should incorporate it into gch.psd1. An on-disk format migration can populate the new setting if the file is found, and then remove the old file.

Example `gch.psd1`:
```pwsh
@{
    AutomaticUpdates = $false
    SendReports = "Auto" # "Never", "Always", "Auto"
    ShowAsPostponedWindowDays = 15
    IpsOfAllDCs = @('10.1.2.3', '10.1.2.4')
}
```

## New gch.psd1 option 'SendReports'
```
SendReports = "Auto" # "Never", "Always", "Auto"
```
The default is "Auto", which matches the current behavior: send when running in a non-interactive session, such as from a scheduled task, and do not send when running from an interactive session, such as a terminal.

## Send-Message.ps1 should support both JSON and PSD1 configuration files
By default, prefer reading and generating the PSD1 configuration file (.\config\Send-Message.psd1).

This change should also include an On-Disk Format migration; see the relevant developer documentation. The migration must convert any existing JSON configuration (.\config\Send-Message.conf) to PSD1 (.\config\Send-Message.psd1), and then delete .\config\Send-Message.conf.

## New helper script CustomTests.ps1

`CustomTests.ps1 -New "scriptName"` should: a) create the necessary folders if needed, b) create a sample script named `scriptName.ps1`, and c) output the full path to the script. The sample code should check whether disk C: has at least 10 GB free. It must follow the documentation recommendations and include enough comments to help a first-time custom health test author modify it for their needs. It should include a link to the relevant documentation at the top.

`CustomTests.ps1 -List` should return a list of all scripts with custom health tests (file objects).

`CustomTests.ps1 -Invoke ScriptFilenName.ps1` should call `Get-ComputerHealth.ps1 -Hide "" -OnlyTheseTests ScriptFilenName.ps1` with the options needed to invoke the specific custom test.

Update our documentation with the above info.

## Avoid complex string expressions in Write-Warning

You can get an overview of suspicious Write-Warning expressions with this command:
```
(sls "write-warning" .\health-tests\*).line -replace '^.*write-warning', 'write-warning' -replace ' *} else(if)? {.*' -replace '; if [(].*' |sls 'write-warning .{76,}$' | sls '`n([" +]*)?(\$details|\$comment)(.{0,4})$' -NotMatch|%{$_.Line} | ?{$_.length -gt 100}
```

After fixing anything, check the resulting `git diff` from Codex with this ChatGPT prompt:
> Do any of the changes in this diff change what will be displayed by write-warning?

## Stop using legacy parameter set that adapts Pester 5 syntax to Pester 4 syntax

So that we don't get this warning: "You are using Legacy parameter set that adapts Pester 5 syntax to Pester 4 syntax. ..."

## New Policy test that detects Hardware (which means we can also detect changes)

## New tests for CPU, GPU, Disks temperature

Verify we don't already have any of them.

-----------------------------------------

## sigstore?

https://docs.sigstore.dev/quickstart/quickstart-cosign/

## Review our test suite for this repo

Review /doc/test-suite-guide.md and improve our test suite if needed.

## Enhance -AddWhitelisting with reason

Current interface:
```powershelll
Get-ComputerHealth.ps1 -AddWhitelisting -until 2026-06-15 -ComputerName WEB1 -sig '50636e99' -Comment "failure - TCP port 636(LDAPS) unreachable on dc02.mazars-gr.local"
```
New interface (note the change of -Comment to -Message and the extra `-Reason` which is an optional parameter)
```powershelll
Get-ComputerHealth.ps1 -AddWhitelisting -until 2026-06-15 -ComputerName WEB1 -sig '50636e99' -Message "failure - TCP port 636(LDAPS) unreachable on dc02.mazars-gr.local" -Reason "Networking team will open the traffic soon"
```

Fix the code that generates the `CommandToSuppressMsg` Excel column. Excel should contain a `-Reason "NO_REASON_ENTERED"` placeholder so that the operator can easily enter a reason.

Also describe this usage scenario in the README: The operator receives an email with notable messages, opens the Excel file, and reviews the findings. If they want to suppress a finding, they execute the contents of the `CommandToSuppressMsg` column, optionally changing `-Reason` and/or `-until`.

It would be useful to include the suppression reason in the findings that are reported to the operator and saved to disk. It would also be useful to include the `-Until` date, which is the date until which the finding is suppressed.

## Save POLICY_TEST_WAS_RUN to `.\state\policy_test_was_run.psd1` instead of `Get-ComputerHealth.sigs-to-suppress.txt`

This is an example for `.\state\policy_test_was_run.psd1`:
```powershelll
@{
    InstalledSW = @{ Ts = [datetime]'2025-11-01 12:42'; User = 'ndemou-admin' }
    UnexpectedListeningPorts = @{Ts = [datetime]'2025-11-01 12:45'; User = 'ndemou-admin' }
}
```

This change needs an On-Disk format change so we also need a migration. 

The migration will initialize `policy_test_was_run.psd1` with any  existing lines from `Get-ComputerHealth.sigs-to-suppress.txt` (the lines must not be removed). If `policy_test_was_run.psd1` already exists the migration is skiped.

For example a like like this:
```
POLICY_TEST_WAS_RUN: InstalledSW
```
Will result in this entry in `policy_test_was_run.psd1`:
```powershelll
InstalledSW = @{Ts = <current time>; User = <current user>}
```

## Save suppressed findings to `.\config\suppressed_findings.psd1` instead of `Get-ComputerHealth.sigs-to-suppress.txt`

This is an example for `.\config\suppressed_findings.psd1`:

```powershelll
@{
    'bfc162fa' = [pscustomobject]@{
        TestName    = 'UnexpectedListeningPorts'
        Description = 'Computer is listening to port 443'
        Reason      = 'business need'
        Ts          = [datetime]'2025-11-01 12:42'
        Until       = [datetime]'2026-05-06'
        User        = 'ndemou-admin'
    }

    'a7d91c03' = [pscustomobject]@{
        TestName    = 'InstalledSW'
        Description = 'Legacy software 7zip is installed'
        Reason      = 'business need'
        Ts          = [datetime]'2025-11-01 12:44'
        Until       = [datetime]'2026-06-15'
        User        = 'ndemou-admin'
    }
}
```

This change needs an On-Disk format change so we also need a migration. 

The migration will initialize `.\config\suppressed_findings.psd1` with any  existing lines from `Get-ComputerHealth.sigs-to-suppress.txt` (the lines must not be removed). If `.\config\suppressed_findings.psd1` already exists the migration is skiped.


## Lighter html code 

Interactive reports: Instead of including the findings in this fat "fieldname:value" format:
```
[
  {"Computer":"AUDIT2","Suppressed":true,"Level":"warning","EffectiveLevel":"postponed","Message":"SMB signing is not required","Comment":"...","Hash":"cdf936f1"},
  {"Computer":"AUDIT2","Suppressed":true,"Level":"warning","EffectiveLevel":"postponed","Message":"NTLM is not fully hardened ...","Comment":"...","Hash":"1b752537"}
]
```

Prefer this lighter csv-like format:
```
[
  ["AUDIT2",true,"warning","postponed","SMB signing is not required","...","cdf936f1"],
  ["AUDIT2",true,"warning","postponed","NTLM is not fully hardened ...","...","1b752537"]
]
```
So every finding is represented by a list of ordered values and all these lists are also bundled in a list (so a list of lists).

## Find redundant health tests

Do a quick first pass to group health tests into clusters that seem to check the same things.

Then check each cluster by asking: “Which tests are merely different views of the same fact?” and “Which tests detect a genuinely different failure mode?” Combine tests that are merely different views of the same fact.

### First-pass clusters and combine candidates

#### Cluster A: DNS suffix / domain identity
- `HealthTest-DnsSuffixBaseline`
- `HealthTest-DnsSuffixMatchesDomain`
- Recommendation: merge into one canonical suffix check.

#### Cluster B: Defender posture / freshness / scan recency
- `HealthTest-MalwareProtectionFeatures`
- `HealthTest-DefenderStatus`
- `HealthTest-RecentWindowsScan`
- Recommendation: merge first two as “Defender posture”; keep scan recency separate.

#### Cluster C: Scheduled task health
- `HealthTest-ScheduledTasks`
- `HealthTest-SystemScheduledTasks`
- `HealthTest-ScheduledTasksLastResult`
- Recommendation: one engine with scoped sections and dedupe by task path/name/reason.

#### Cluster D: AD replication and topology
- `HealthTest-ADInboundReplicationTopology`
- `HealthTest-ReplicationLatency`
- `HealthTest-ADReplicationHealth`
- `HealthTest-Dcdiag` (partial overlap)
- Recommendation: combine replication trio; keep `Dcdiag` as independent corroboration.

#### Cluster E: DFSR/SYSVOL
- `HealthTest-DfsReplicationState`
- `HealthTest-DfsrBacklog`
- `HealthTest-SysvolContentConsistency`
- `HealthTest-SysvolNetlogonAccessible`
- Recommendation: combine DFSR pair; keep SYSVOL downstream checks separate.

#### Cluster F: DC DNS registration / reachability
- `HealthTest-ConnectivityToDCs`
- `HealthTest-RequiredSrvRecords`
- `HealthTest-DcDnsRegistration`
- `HealthTest-DcDnsARecords`
- Recommendation: share one SRV validation helper; keep A-record and connectivity checks separate.

#### Cluster G: Network exposure surface
- `HealthTest-FirewallEnabled`
- `HealthTest-UnexpectedListeningPorts`
- `HealthTest-WinRMListening`
- `HealthTest-ShareReasonableness`
- Recommendation: do not merge; distinct failure modes, but add cross-links in output.

### Classes of reasons to combine tests

1. Same canonical fact, different collection method.
2. Same control objective, duplicated posture checks.
3. Same subsystem health split into near-identical status slices.
4. Same entity set segmented only by scope/view.
5. Shared primitive assertion embedded in multiple higher-level tests.
6. Alert-level duplication with no extra failure-mode coverage.
7. Correlated but distinct failure modes (**do not combine**; cross-link instead).

### Most likely same-fact duplicates (priority)

1. `HealthTest-DnsSuffixBaseline` + `HealthTest-DnsSuffixMatchesDomain`
2. `HealthTest-MalwareProtectionFeatures` + `HealthTest-DefenderStatus`
3. `HealthTest-DfsReplicationState` + `HealthTest-DfsrBacklog`
4. `HealthTest-ScheduledTasks` + `HealthTest-ScheduledTasksLastResult` (plus overlap with `HealthTest-SystemScheduledTasks`)
5. SRV-record portion of `HealthTest-ConnectivityToDCs` + `HealthTest-RequiredSrvRecords`


## Post-processing of long diagnostic output that may have repetitions

Look at this example output regarding a failed dcdiag:
```
  NOTICE : [3dafa4cb] 'DCDIAG /v' reports a failure in this basic test that examines the event log: DC02 failed test SystemLog
  #       Since this test fails when warnings/errors appear in the event log, false positives are likely.
  #       Run DCDIAG /v, search for 'DC02 failed test SystemLog' and examine the detailed report above it.
  #       Below are lines from that report that contain words like error/fail:
---start of diagnostic output---
Windows failed to apply the MDM Policy settings. MDM Policy settings might have its own log file. Please click on the "More information" link. Windows failed to apply the MDM Policy settings. MDM Policy settings might have its own log file. Please click on the "More information" link. Windows failed to apply the MDM Policy settings. MDM Policy settings might have its own log file. Please click on the "More information" link. Windows failed to apply the MDM Policy settings. MDM Policy settings might have its own log file. Please click on the "More information" link. Windows failed to apply the MDM Policy settings. MDM Policy settings might have its own log file. Please click on the "More information" link. Windows failed to apply the MDM Policy settings. MDM Policy settings might have its own log file. Please click on the "More information" link. Windows failed to apply the MDM Policy settings. MDM Policy settings might have its own log file. Please click on the "More information" link. Windows failed to apply the MDM Policy settings. MDM Policy settings might have its own log file. Please click on the "More information" link. Windows failed to apply the MDM Policy settings. MDM Policy settings might have its own log file. Please click on the "More information" link. Windows failed to apply the MDM Policy settings. MDM Policy settings might have its own log file. Please click on the "More information" link. Windows failed to apply the MDM Policy settings. MDM Policy settings might have its own log file. Please click on the "More information" link. Windows failed to apply the MDM Policy settings. MDM Policy settings might have its own log file. Please click on the "More information" link. An error event occurred.  EventID: 0x80000013
---end of diagnostic output---
```

Notice that the diagnostic output collected from dcdiag is a very long string of repeating sentences. We can make it much more succinct with these steps:
 - Split lines (sentences) on anything that looks like "word. ", "word.) ", or "word; ". For example: `$output -replace '(([a-z]{2,30})(;|[.][)]?)) +','$1\r\n'`
 - Keep the first 50 lines
 - Remove duplicate lines (sentences)
 - Join all lines back into one line
 - If more than 2000 characters, keep the first 1997 suffixed with "...".

For example, the diagnostic output above will become:
```
Windows failed to apply the MDM Policy settings. MDM Policy settings might have its own log file. Please click on the "More information" link. An error event occurred. EventID: 0x80000013
```

So far, I have only noticed a need for this post-processing on dcdiag output, but it is best to create a separate function for this post-processing.

## Use the new installer (~\dev\TI)


## Review the hundreds of warnings from Invoke-ScriptAnalyzer (and 3 errors)

See also : .\tests\script-analysis.ps1

## Other

  - Re-evaluate notice/warning/failure levels.

  - Implement -RemoveWhitelisting -ComputerName -Signature

  - HealthTest-EnabledScheduledTasks: I should include a hash of the action and the file(s) it runs

  - I could be monitoring the CPU and memory pressure *while* running all/most
    other tests. This has pros and cons so I can make it a separate check
    (e.g. some tests *do* stress the CPU (maybe RAM also).

  - Also measure CPU, board temperature.

  - `-AddWhitelisting` should be deleting any existing line for the signature.
    Note that even without this fix, everything works as it should
    (because the last config line wins), but it's confusing to have
    conflicting lines.

  - Use [string[]]$Arg1 everywhere for arguments that expect string arrays
    This style works like this:
         -Arg1 test,foo,bar             --> @("test","foo","bar")
         -Arg1 test -Arg1 foo -Arg1 bar --> @("test","foo","bar")
         -Arg1 @("test","foo","bar")    --> @("test","foo","bar")
         -Arg1 "test,foo,bar"           --> "test,foo,bar"
         -Arg1 "test foo bar"           --> "test foo bar"
    If I do not expect the values to contain spaces or commas, I could fix the last two cases manually.

  - `Start-HealthTestVeeamRecentBackupsExist` expects to read clear-text data from a file. Maybe use Credential Manager. Note that Credential Manager stores passwords per user, which complicates things: it may work from your account but not from SYSTEM.

## Some tests that have Scope: Domain should ideally be executed on one DC

- "HealthTest-ADReplicationDomainRepadmin"
- "HealthTest-SysvolNetlogonAccessible"
- "HealthTest-SchemaVersionConsistency"
- "HealthTest-TombstoneLifetime"
- "HealthTest-RecycleBinEnabled"

## MAYBE change any files with JSON content to `.psd1`

## Health test candidates

### detect Scheduled Tasks that are configure to run on boot and are expected be running continously but are not running at the moment.

```
function Get-InactiveStartupTask {
    <#
    .SYNOPSIS
        Gathers scheduled tasks configured to start on boot that are not running.
    .DESCRIPTION
        Queries the local system for scheduled tasks that run at system startup and are currently idle. 
        Enriches standard task definitions with runtime metadata—including timeout metrics, individual trigger 
        states, execution identities, and translated exit codes—to build a diagnostic foundation.
    .OUTPUTS
        [PSCustomObject] Containing comprehensive task configuration and last-run execution properties.
    #>
    [CmdletBinding()]
    param()

    begin {
        $StatusMap = @{
            '0'          = 'Success'
            '1'          = 'Incorrect/Unknown Function'
            '2'          = 'File Not Found'
            '10'         = 'Incorrect Environment'
            '267008'     = 'Ready to run at next scheduled time'
            '267009'     = 'Task is currently running'
            '267010'     = 'Task is disabled'
            '267011'     = 'Task has not yet run'
            '267012'     = 'No more runs scheduled'
            '267014'     = 'Task terminated by user'
            '3221225786' = 'Terminated by CTRL+C'
        }
    }

    process {
        Get-ScheduledTask | Where-Object {
            $_.State -ne 'Running' -and
            ($_.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' })
        } | Select-Object TaskPath, TaskName, 
            @{
                Name = 'StopAfterMinutes'
                Expression = {
                    $Limit = $_.Settings.ExecutionTimeLimit
                    if ([string]::IsNullOrEmpty($Limit) -or $Limit -match '^(PT0S|P0D)$') { return -1 }
                    try { return [int][System.Xml.XmlConvert]::ToTimeSpan($Limit).TotalMinutes } catch { return -1 }
                }
            },
            @{
                Name = 'TaskState'
                Expression = { $_.State }
            },
            @{
                Name = 'StartupTriggerEnabled'
                Expression = {
                    $BootTrigger = $_.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' }
                    return $BootTrigger.Enabled
                }
            },
            @{
                Name = 'RunAsIdentity'
                Expression = {
                    if ($_.Principals.UserId) { $_.Principals.UserId } else { $_.Principals.GroupId }
                }
            },
            @{
                Name = 'ActionType'
                Expression = {
                    $_.Actions.CimClass.CimClassName -replace 'MSFT_Task', '' -join ', '
                }
            },
            @{
                Name = 'LastTaskResult'
                Expression = { [int64]($_ | Get-ScheduledTaskInfo).LastTaskResult }
            },
            @{
                Name = 'LastTaskResultDescr'
                Expression = {
                    $RawCode = ($_ | Get-ScheduledTaskInfo).LastTaskResult
                    $StringCode = [string]$RawCode
                    if ($StatusMap.ContainsKey($StringCode)) { $StatusMap[$StringCode] } else { "Unknown (0x{0:X})" -f [int64]$RawCode }
                }
            }
    }
}

function Find-AbnormalStartupTask {
    <#
    .SYNOPSIS
        Analyzes output of Get-InactiveStartupTask to isolate genuine execution anomalies.
    .DESCRIPTION
        Acts as a downstream pipeline processor for Get-InactiveStartupTask. It filters out expected or 
        intentionally dormant native Windows infrastructure tasks and isolates actual deployment issues, 
        unhandled application crashes, manual operator interventions, or forced timeout kills.
    .PARAMETER Task
        An enriched task object emitted by the Get-InactiveStartupTask function. Supports pipeline input.
    .OUTPUTS
        [PSCustomObject] Representing confirmed anomalies, enriched with a dedicated 'IssueAnalysis' classification string.
    .EXAMPLE
        Get-InactiveStartupTask | Find-AbnormalStartupTask | Format-List
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        [PSCustomObject]$Task
    )

    process {
        if (-not $Task.TaskName) { return }

        if ($Task.TaskState -eq 'Disabled' -or $Task.StartupTriggerEnabled -eq $false) {
            return
        }

        if ($Task.LastTaskResult -eq 0 -or ($Task.LastTaskResult -eq 267011 -and $Task.TaskPath -like '\Microsoft\*')) {
            return
        }

        $Analysis = "Scheduled task '$($Task.TaskPath)$($Task.TaskName)' terminated abnormaly ($($Task.LastTaskResultDescr))"

        if ($Task.LastTaskResult -eq 267011) {
            $Analysis = "Non-Windows scheduled task '$($Task.TaskPath)$($Task.TaskName)' is configured to start on boot but hasn't started."
        }
        elseif ($Task.LastTaskResult -eq 267014) {
            if ($Task.StopAfterMinutes -ne -1) {
                $Analysis = "Scheduled task '$($Task.TaskPath)$($Task.TaskName)' probably exceeded its execution time limit($($Task.StopAfterMinutes) mins) and was killed by the OS."
            } else {
                $Analysis = "Scheduled task '$($Task.TaskPath)$($Task.TaskName)' was probably killed by a user or some other process."
            }
        }
        else {
            $Analysis = "Scheduled task '$($Task.TaskPath)$($Task.TaskName)' terminated with an unhandled non-zero exit code ($($Task.LastTaskResultDescr))"
        }

        [PSCustomObject]@{
            TaskPath            = $Task.TaskPath
            TaskName            = $Task.TaskName
            TaskState           = $Task.TaskState
            LastTaskResult      = $Task.LastTaskResult
            LastTaskResultDescr = $Task.LastTaskResultDescr
            StopAfterMinutes    = $Task.StopAfterMinutes
            IssueAnalysis       = $Analysis
            RunAsIdentity       = $Task.RunAsIdentity
            ActionType          = $Task.ActionType
        }
    }
}

Function HealthTest-BootSchTaskNotRunning {
<#
Reports Scheduled Tasks that run on boot and where expected to be still running but are not
#>
    $TASKS_THAT_OFTEN_FAIL = @(
        '\Microsoft\Windows\AppID\VerifiedPublisherCertStoreCheck',
        '\Microsoft\Windows\NetCfg\BindingWorkItemQueueHandler',
        '\Microsoft\Windows\PI\SecureBootEncodeUEFI',
        '\Microsoft\Windows\Setup\PITRTask'
    )
    
    Get-InactiveStartupTask | Find-AbnormalStartupTask | %{
        if (($_.TaskPath + $_.TaskName ) -in $TASKS_THAT_OFTEN_FAIL) {
            $level = "NOTICE"
        } else {
            $level = "WARNING"
        }
        Write-Warning "[$level] $($_.IssueAnalysis)"
    }
}
```

### Other
```
function HealthTest-ExploitProtectionBaseline {
<#
.SYNOPSIS
Checks Exploit Protection Baseline

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Audit / Compliance / Informational
Impact: Medium(Time)
Uses: Get-ProcessMitigation.
FalsePositives: None.

TODO: Check all protections not just the 3 below. Get-ProcessMitigation -System
TODO: What are the popular defaults?
#>
    if (-not (Get-Command Get-ProcessMitigation -ErrorAction SilentlyContinue)) { Write-Warning "[notice] Exploit Protection cmdlets unavailable"; return }
    $sys = Get-ProcessMitigation -System -ErrorAction SilentlyContinue
    if (-not $sys) { Write-Warning "[warning] Could not read system process mitigations"; return }
    $ok = $true
    if (-not $sys.Dep.Enable) { Write-Warning "[notice] Exploit Protection; DEP not enforced system-wide"; $ok = $false }
    if (-not $sys.ASLR.EnableForceRelocateImages) { Write-Warning "[notice] Exploit Protection; ASLR not enforcing force-relocate"; $ok = $false }
    if (-not $sys.SEHOP.Enable) { Write-Warning "[notice] Exploit Protection; SEHOP not enabled"; $ok = $false }
    if ($ok) { Write-Warning "[pass] Exploit Protection key mitigations enabled"; return } else { return }
}


function HealthTest-HyperVVMProperties {
<#
.SYNOPSIS
Checks Hyper VVM Properties

.DESCRIPTION
AppliesTo: HyperV
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-VM.
FalsePositives: None.
#>
    # For Hyper-V hosts put here the expected values for these VM properties
    $EXPECTED_VALUES_FOR_VM_PROPERTIES = @{
        ReplicationHealth        = 'Normal'
        Status                   = 'Operating normally'
        PrimaryOperationalStatus = 'Ok'
        Heartbeat                = 'Ok*'
        AutomaticStartAction     = 'Start*'
        AutomaticStopAction      = 'Save'
        VMIntegrationService     = 'Guest Service Interface,Heartbeat,Key-Value Pair Exchange,Shutdown,Time Synchronization,VSS'
        Generation               = '2'
        Version                  = '9.0'
    }

    $vms = Get-VM | Where-Object { $_.State -eq 'Running' }
    foreach ($vm in $vms) {
        $EXPECTED_VALUES_FOR_VM_PROPERTIES.Keys | ForEach-Object {
            $prop_name = $_
            $expected_value = $EXPECTED_VALUES_FOR_VM_PROPERTIES[$prop_name]
            # write-host "Checking if $prop_name = $expected_value"

            if ($prop_name -eq 'VMIntegrationService') {
                # for VMIntegrationService we need to canonicalize the values
                $expected_value = ($expected_value -split ',' | % { $_.Trim() } | Sort-Object -Unique)  -join ','
                $actual_value   = ($vm.VMIntegrationService.Name | Sort-Object -Unique) -join ','
            } else {
                # for all other properties we have a simple value we expect them to have
                $actual_value = $vm.$prop_name
            }
            if ($actual_value -notlike $expected_value) {
                Write-Warning "[warning] VM $($vm.Name) has $prop_name='$actual_value' instead of '$expected_value'."
            }
        }
    }
}


function HealthTest-RecentDiskErrors {
<#
.SYNOPSIS
Checks Recent Disk Errors

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: Get-WinEvent.
FalsePositives: None.
#>
    param([int]$Hours = 48)

    $pass = $true
    if ($Hours -lt 1) { $Hours = 1 }

    $start     = (Get-Date).AddHours(-$Hours)
    $providers = @('disk','ntfs','stornvme')
    $events    = @()

    foreach ($p in $providers) {
        try {
            Get-WinEvent -FilterHashtable @{
                    LogName      = 'System'
                    ProviderName = $p
                    Level        = 2     # Error
                    StartTime    = $start
            } -ErrorAction SilentlyContinue | %{
                Write-Warning "[failure] Storage($p) error in last N hours`nN=$Hours hours; Event: $($_.TimeCreated), $($_.LevelDisplayName), $($_.Message)"
                $pass = $false
            }
        } catch {
            if ($_.Exception.Message -notlike '*There is not an event provider*') {
                Write-Warning "[warning] Failed reading System log for provider '$p': $($_.Exception.Message)"
            }
        }
    }

    if ($pass) {
        Write-Warning "[pass] No disk/NTFS/storage errors in last $Hours h"
    }

}

<#
.SYNOPSIS
Detects orphaned Hyper-V files (disks, configs, state, etc.) and reports them.

.DESCRIPTION
Builds an "in-use" map from Hyper-V:
  - VM IDs via Get-VM
  - All disks attached to VMs via Get-VMHardDiskDrive
  - Walks VHDX/AVHDX parent chains via Get-VHD to include parents

Scans typical Hyper-V roots (recursively) and classifies files:
  Failures:
    - .vhdx / .avhdx not referenced by any VM chain
    - .vmcx / .vmrs / .vmgs whose GUID does not belong to any VM
    - .bin / .vsv / .svo with non-VM GUID
  Notices:
    - .rct / .mrt / .mrt.log (likely stale RCT logs if base VHDX unused)
    - .tmp, export remnants (.exp folders), replication metadata (*.hrl, *.hrx, *.xml) not referenced
    - Access denied / IO errors while scanning

Outputs Write-Failure/Write-Notice lines and returns [bool] (healthy = no failures).

.PARAMETER Roots
Folders to scan recursively. Defaults cover common Hyper-V paths on the host.

.PARAMETER ScanAllFixed
If set, also scans all fixed drives’ roots (e.g., C:\, D:\) for stray artifacts.

.EXAMPLE
HealthTest-OrphanedHyperVFiles
.EXAMPLE
HealthTest-OrphanedHyperVFiles -Roots 'D:\Hyper-V','E:\VMStore'
#>
function HealthTest-OrphanedHyperVFiles {
    [CmdletBinding()]
    param(
        [string[]]$Roots = @(
            'C:\ProgramData\Microsoft\Windows\Hyper-V',
            'C:\ProgramData\Microsoft\Windows\Hyper-V\Virtual Machines',
            'C:\Users\Public\Documents\Hyper-V',
            'C:\Hyper-V',
            'D:\Hyper-V'
        ),
        [switch]$ScanAllFixed
    )

    $hadFailure = $false
    $notices = 0

    # Helpers
    function _NormPath([string]$p){
        if ([string]::IsNullOrWhiteSpace($p)) { return $null }
        try { (Resolve-Path -LiteralPath $p -ErrorAction Stop).Path } catch { $p }
    }
    function _GuidFromName([string]$name){
        if (-not $name) { return $null }
        $m = [regex]::Match($name, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
        if ($m.Success) { return $m.Groups[1].Value.ToLowerInvariant() }
        return $null
    }

    # 1) Collect VM IDs and referenced disk paths
    $vmIds = New-Object 'System.Collections.Generic.HashSet[string]'
    $inUseDisks = New-Object 'System.Collections.Generic.HashSet[string]'
    try {
        $vms = Get-VM -ErrorAction Stop
        foreach($vm in $vms){
            if ($vm.Id) { [void]$vmIds.Add($vm.Id.Guid.ToString().ToLowerInvariant()) }
            $drives = Get-VMHardDiskDrive -VMName $vm.Name -ErrorAction SilentlyContinue
            foreach($d in $drives){
                $p = _NormPath $d.Path
                if ($p) {
                    [void]$inUseDisks.Add($p.ToLowerInvariant())
                    # Walk parent chain
                    try {
                        $cur = $p
                        while ($true) {
                            $v = Get-VHD -Path $cur -ErrorAction Stop
                            if (-not $v.ParentPath) { break }
                            $pp = _NormPath $v.ParentPath
                            if (-not $pp) { break }
                            [void]$inUseDisks.Add($pp.ToLowerInvariant())
                            $cur = $pp
                        }
                    } catch { }
                }
            }
        }
    }
    catch {
        Write-Warning ("[Failure] Failed to enumerate VMs/disks: {0}" -f $_.Exception.Message)
        return $false
    }

    # 2) Build scan roots
    $scanRoots = New-Object System.Collections.Generic.List[string]
    foreach($r in $Roots){
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        if (Test-Path -LiteralPath $r) { $scanRoots.Add((Resolve-Path -LiteralPath $r).Path) }
    }
    if ($ScanAllFixed) {
        $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -ge 0 -and $_.Root -match '^[A-Z]:\\$' }
        foreach($d in $drives){ if (-not $scanRoots.Contains($d.Root)) { $scanRoots.Add($d.Root) } }
    }
    if ($scanRoots.Count -eq 0) {
        Write-Warning "[Warning] No scan roots exist; nothing to check."
        return $true
    }

    # 3) Scan and classify
    $extFailDisk = @('.vhdx','.avhdx')
    $extCfgState = @('.vmcx','.vmrs','.vmgs','.bin','.vsv','.svo')
    $extNotice   = @('.rct','.mrt','.log','.tmp')
    $repMetaLike = @('*.hrl','*.hrx','*.xml') # replication metadata heuristics

    foreach($root in $scanRoots){
        try {
            $files = Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction Stop
        }
        catch {
            Write-Warning ("[Warning] Access denied or IO error scanning {0}: {1}" -f $root, $_.Exception.Message)
            $notices++
            continue
        }

        foreach($f in $files){
            $ext = $f.Extension.ToLowerInvariant()
            $pathL = $f.FullName.ToLowerInvariant()

            if ($extFailDisk -contains $ext) {
                if (-not $inUseDisks.Contains($pathL)) {
                    $hadFailure = $true
                    Write-Warning ("[Failure] Orphaned {0}: {1}  SizeGB={2}  Modified={3}" -f $ext.Trim('.').ToUpper(), $f.FullName, [math]::Round($f.Length/1GB,2), $f.LastWriteTime)
                }
                continue
            }

            if ($extCfgState -contains $ext) {
                $gid = _GuidFromName $f.Name
                if ($gid -and -not $vmIds.Contains($gid)) {
                    $hadFailure = $true
                    Write-Warning ("[Failure] Orphaned {0} (no matching VM ID): {1}  Modified={2}" -f $ext.Trim('.').ToUpper(), $f.FullName, $f.LastWriteTime)
                }
                continue
            }

            if ($extNotice -contains $ext) {
                # RCT/MRT: if base VHDX clearly not in use, call it out; otherwise just note
                $base = [System.IO.Path]::ChangeExtension($f.FullName, '.vhdx')
                $baseL = $base.ToLowerInvariant()
                if (Test-Path -LiteralPath $base) {
                    if (-not $inUseDisks.Contains($baseL)) {
                        Write-Warning ("[Warning] Stale {0} next to unused VHDX: {1}" -f $ext.Trim('.').ToUpper(), $f.FullName)
                    } else {
                        Write-Warning ("[Warning] RCT/MRT or temp file present: {0}" -f $f.FullName)
                    }
                } else {
                    Write-Warning ("[Warning] Unpaired {0} file: {1}" -f $ext.Trim('.').ToUpper(), $f.FullName)
                }
                $notices++
                continue
            }

            # Replication metadata heuristics (by pattern, not just extension)
            foreach($pat in $repMetaLike){
                if ([System.Management.Automation.WildcardPattern]::new($pat,'IgnoreCase').IsMatch($f.Name)) {
                    # If there is no corresponding VM folder/ID, treat as notice (not hard failure)
                    $gid = _GuidFromName $f.Name
                    if (($gid -and -not $vmIds.Contains($gid)) -or (-not $gid)) {
                        Write-Warning ("[Warning] Possible orphaned replication metadata: {0}" -f $f.FullName)
                        $notices++
                    }
                    break
                }
            }
        }
    }

    if (-not $hadFailure) {
        Write-Pass ("No orphaned disks/config/state found. Notices: {0}" -f $notices)
        return $true
    }

    return $false
}
```

## HealthTest-SysvolContentConsistency
The function HealthTest-SysvolContentConsistency calculates the size and file count of the entire `\\SYSVOL\...\Policies` tree across **all** domain controllers over the network. In a production environment with branch offices or many GPOs, this is dangerous because it can generate massive WAN traffic. Since health tests already run on every DC, we could compute hashes locally on each DC, using real hashes instead of the pseudo signatures this function computes. We could then exchange and compare those hashes. This should be very fast, even over WAN.


## Look at these Gemini suggestions

### 1. Minor Logical Errors (`Test-NetConnectionFast` & `TimeSync`)

**A. `Test-NetConnectionFast` (DNS ordering bug)**
The original code fetches all IP addresses and arbitrarily picks the first one, or filters them clumsily. If a host has IPv6 but the network does not route it, the test fails even if IPv4 works.

**The Fix: Enforce IPv4 and Registry-Based Time Checks**

```powershelll
    # Inside Test-NetConnectionFast process block:
    try {
        # Force IPv4 resolution to match your "IPv4 only is acceptable" requirement
        $ips = [System.Net.Dns]::GetHostAddresses($ComputerName) |
               Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
               Select-Object -ExpandProperty IPAddressToString -First 1

        if ($ips) { $remoteAddr = $ips }
        else {
            # Fallback if no IPv4 found
            $remoteAddr = [System.Net.Dns]::GetHostAddresses($ComputerName) | Select -First 1 -Expand IPAddressToString
        }
    } catch {}

```

**B. `HealthTest-TimeSyncPolicy` (Localization bug)**
The check `$currentTimeSource -eq 'Local CMOS Clock'` fails on non-English Windows, such as "Lokale CMOS-Uhr".

**Suggestion:** Instead of parsing the localized text output of `w32tm /query /source`, check the **Registry** configuration, which is language-neutral.

**The Fix: **

```powershelll
    # Replace the text comparison with a check on the configuration type
    $w32Param = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
    $isNt5Ds  = $w32Param.Type -eq 'NT5DS'

    # If it is configured as NT5DS, it is correct for domain members/DCs.
    # We only alert if it is explicitly using the internal clock while NOT being a PDC.
    if (-not $isNt5Ds -and $currentTimeSource -match 'CMOS|LOCL|Free-running') {
        Log-Failure "Time source is set to Local CMOS/Internal Clock"
    }

```

---

### 2: False Positives in Driver Signing

`Win32_PnPSignedDriver` and `Get-AuthenticodeSignature` are unreliable for modern drivers because they often look for an embedded signature in the `.sys` file. Many valid Microsoft, Intel, and Realtek driver binaries are unsigned because their signatures live in external `.cat` catalog files.

**Suggestion:** Use the `Get-AppLockerFileInformation` cmdlet, available on most modern Windows versions, to check signatures. It is catalog-aware and will correctly identify a file as signed even if the signature is external.

**Modified Code (`HealthTest-UnsignedDrivers`):**

```powershelll
    # Inside the loop where you have the driver path ($sysPath):

    # 1. Try standard Authenticode (fastest)
    $sig = Get-AuthenticodeSignature $sysPath
    if ($sig.Status -eq 'Valid') { continue }

    # 2. If invalid, fallback to AppLocker (slower, but catalog-aware)
    if (Get-Command Get-AppLockerFileInformation -ErrorAction SilentlyContinue) {
        try {
            $appLockerInfo = Get-AppLockerFileInformation -Path $sysPath -ErrorAction Stop
            if ($appLockerInfo.Publisher.PublisherName) {
                # If AppLocker finds a publisher, the system trusts the signature (Catalog or Embedded)
                Log-Notice "Driver validated via Catalog (AppLocker): $($d.DeviceName)"
                continue
            }
        } catch {
            # AppLocker failed to read it, likely actually unsigned or unreadable
        }
    }

    # 3. If both fail, flag it
    $bad = $true
    Log-Failure "Unsigned Driver detected: $sysPath"

```

##  Consider if the following health tests are useful (GPT inspired)
```
# Run it and in about half the servers it complained it found "no backup signals"
# .SYNOPSIS Looks for recent backup-related events and highlights failures or missing success signals.
function HealthTest-BackupSignals {
    param(
        [int]$WarnHours = 24,
        [int]$FailHours = 48
    )

    if ($WarnHours -lt 1) { $WarnHours = 1 }
    if ($FailHours -lt $WarnHours) { $FailHours = $WarnHours }

    $failCutoff  = (Get-Date).AddHours(-$FailHours)
    $warnCutoff  = (Get-Date).AddHours(-$WarnHours)

    $events = Get-WinEvent -FilterHashtable @{
            LogName   = 'Application'
            StartTime = $failCutoff
        } -ErrorAction SilentlyContinue

    $events = @($events)
    $backupEvents = @(
        $events | Where-Object {
            $_.ProviderName -match 'VSS|Microsoft\-Windows\-Backup|Windows Server Backup|MSSQLSERVER|VMMS|Veeam|Acronis|DPM'
        }
    )

    if ($backupEvents.Count -eq 0) {
        Log-Warning "No recognizable backup-related events in last $FailHours h"
        return
    }

    $fail = @($backupEvents | Where-Object { $_.LevelDisplayName -match 'Error|Critical' })
    if ($fail.Count -gt 0) {
        Log-failure "Backup-related errors present in last $FailHours h"
        return
    }

    $recentOk = @(
        $backupEvents | Where-Object {
            $_.TimeCreated -gt $warnCutoff -and $_.LevelDisplayName -match 'Information'
        }
    )

    if ($recentOk.Count -gt 0) {
        Log-pass "Backup signals present within last $WarnHours h"
        return
    }

    Log-Warning "No clear successful backup signals within last $WarnHours h (but older backup activity exists)"
}

# Verify BitLocker recovery objects for specific computer exists in AD
function Test-BitLockerRecoveryInAD($computerName){
  $cn="$($computerName)$"
  $comp=Get-ADComputer -Identity $cn -ErrorAction SilentlyContinue
  if(-not $comp){ Log-pass "Computer account not found in AD (skipping BitLocker recovery check)"; return }
  $ri=Get-ADObject -SearchBase $comp.DistinguishedName -LDAPFilter '(objectClass=msFVE-RecoveryInformation)' -SearchScope OneLevel
  if(($ri | Measure-Object).Count -gt 0){ Log-pass ("BitLocker recovery objects present for this computer ($($ri.Count))") } else { Log-failure "No BitLocker recovery objects found for this computer in AD" }
}


```

## New test: Evaluate secure communication configurations

Most of the servers will emit these failures:
    > FAILURE: [337007c8] .NET 4.x (64-bit) expected Enabled; got SchUseStrongCrypto=1; SystemDefaultTlsVersions=<missing>
    >        Applies to: Client+Server.
    >        Key: HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319.
    > FAILURE: [9045cbcf] .NET 4.x (32-bit) expected Enabled; got SchUseStrongCrypto=1; SystemDefaultTlsVersions=<missing>
    >        Applies to: Client+Server.
    >        Key: HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319.

```
<#
.SYNOPSIS
Evaluates the configured state of secure communication protocols against
target security states.

.OUTPUTS
Produces a custom object for each evaluated configuration component:
  AuditType            : The category of the evaluation.
  Computer             : The local machine name.
  Protocol_Component   : The evaluated protocol or framework.
  CurrentState         : The active operational state.
  Source               : The origin of the current state.
  RecommendedState     : The target security state.
  Note                 : Context regarding the recommendation.
  Key                  : The evaluated registry path.
  EnabledRaw           : The raw numerical enabled value.
  DisabledByDefaultRaw : The raw numerical disabled value.

.DESCRIPTION
Reads configuration data for secure communication protocols and application
framework settings. The effective state accounts for explicit values and
default behaviors tied to the operating system version. Recommendations
reflect the capability of the host operating system to support specific
protocols. Read operations encountering access issues may result in
terminating errors.

.PARAMETER IncludeDotNetCheck
When set, also evaluates .NET framework cryptography settings
#>
function Get-SchannelProtocolState {
    [CmdletBinding()]
    param(
        [ValidateSet('Server','Client')] [string]$Role = 'Server',
        [string[]]$Protocol = @('SSL 3.0','TLS 1.0','TLS 1.1','TLS 1.2','TLS 1.3'),
        [switch]$IncludeDotNetCheck = $true
    )

    $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols'

    $v = [Environment]::OSVersion.Version
    $installType = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'InstallationType' -ErrorAction SilentlyContinue).InstallationType
    $isServer = $false
    if ($installType -like '*Server*') { $isServer = $true }

    $tls13Supported = $false
    if ($isServer) {
        if ($v.Major -ge 10 -and $v.Build -ge 20348) { $tls13Supported = $true }
    } else {
        if ($v.Major -ge 10 -and $v.Build -ge 22000) { $tls13Supported = $true }
    }

    function Get-EffectiveState {
        param([string]$KeyPath, [string]$ProtocolName)

        $enabled = $null
        $disabledByDefault = $null
        $src = 'OS default'
        $state = 'Enabled'

        if (Test-Path $KeyPath) {
            try {
                $props = Get-ItemProperty -Path $KeyPath -ErrorAction Stop
                if ($null -ne $props.Enabled) { $enabled = [uint32]$props.Enabled }
                if ($null -ne $props.DisabledByDefault) { $disabledByDefault = [uint32]$props.DisabledByDefault }
            } catch {
            }
        }

        if ($null -ne $enabled) {
            if ($enabled -eq 0) { $state = 'Disabled'; $src = 'Enabled=0' }
            else { $state = 'Enabled'; $src = 'Enabled=1/FFFF' }
        }
        elseif ($null -ne $disabledByDefault) {
            if ($disabledByDefault -eq 1) { $state = 'Disabled'; $src = 'DisabledByDefault=1' }
            else { $state = 'Enabled'; $src = 'DisabledByDefault=0' }
        }
        else {
            if ($ProtocolName -in 'SSL 3.0','TLS 1.0','TLS 1.1') { $state = 'Disabled'; $src = 'OS default' }
            else { $state = 'Enabled'; $src = 'OS default' }
        }

        ,@($state, $src, $enabled, $disabledByDefault)
    }

    foreach ($proto in $Protocol) {
        $key = Join-Path (Join-Path $base $proto) $Role
        $eff = Get-EffectiveState -KeyPath $key -ProtocolName $proto
        $current = $eff[0]; $source = $eff[1]; $enabledRaw = $eff[2]; $disabledRaw = $eff[3]

        $rec = 'No requirement'
        $note = ''
        $fix = $null

        if ($proto -in 'SSL 3.0','TLS 1.0','TLS 1.1') {
            $rec = 'Disabled'
            $note = 'Disable legacy protocol.'
            $fix = @"
Set: Enabled=0 (DWORD) and DisabledByDefault=1 (DWORD)
Example:
  New-Item -Path '$key' -Force | Out-Null
  New-ItemProperty -Path '$key' -Name Enabled -PropertyType DWord -Value 0 -Force | Out-Null
  New-ItemProperty -Path '$key' -Name DisabledByDefault -PropertyType DWord -Value 1 -Force | Out-Null
"@
        }
        elseif ($proto -eq 'TLS 1.2') {
            $rec = 'Enabled'
            $note = 'Keep TLS 1.2 enabled.'
            $fix = @"
Set: Enabled=1 (DWORD) and DisabledByDefault=0 (DWORD)
Example:
  New-Item -Path '$key' -Force | Out-Null
  New-ItemProperty -Path '$key' -Name Enabled -PropertyType DWord -Value 1 -Force | Out-Null
  New-ItemProperty -Path '$key' -Name DisabledByDefault -PropertyType DWord -Value 0 -Force | Out-Null
"@
        }
        elseif ($proto -eq 'TLS 1.3') {
            if ($tls13Supported) {
                $rec = 'Enabled'
                $note = 'OS supports TLS 1.3; enable it.'
                $fix = @"
Set: Enabled=1 (DWORD) and DisabledByDefault=0 (DWORD)
Example:
  New-Item -Path '$key' -Force | Out-Null
  New-ItemProperty -Path '$key' -Name Enabled -PropertyType DWord -Value 1 -Force | Out-Null
  New-ItemProperty -Path '$key' -Name DisabledByDefault -PropertyType DWord -Value 0 -Force | Out-Null
"@
            } else {
                $rec = 'No requirement'
                $note = 'TLS 1.3 not required on this OS.'
                $fix = $null
            }
        }

        [pscustomobject]@{
            AuditType  = 'Schannel'
            AppliesTo  = $Role
            Name       = "$proto"
            Current    = $current
            Expected   = $rec
            Evidence   = "Source=$source"
            Key        = $key
            EnabledRaw = $enabledRaw
            DisabledByDefaultRaw = $disabledRaw
            Note       = $note
            Fix        = $fix
        }
    }

    if ($IncludeDotNetCheck) {
        $dotNetPaths = @(
            @{ Arch = '64-bit'; Path = 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319' },
            @{ Arch = '32-bit'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319' }
        )

        foreach ($d in $dotNetPaths) {
            $path = $d.Path
            $arch = $d.Arch

            $strongCrypto = $null
            $systemTls = $null

            if (Test-Path $path) {
                $props = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
                if ($null -ne $props.SchUseStrongCrypto) { $strongCrypto = $props.SchUseStrongCrypto }
                if ($null -ne $props.SystemDefaultTlsVersions) { $systemTls = $props.SystemDefaultTlsVersions }
            }

            $scText = '<missing>'
            $stText = '<missing>'
            if ($null -ne $strongCrypto) { $scText = [string]$strongCrypto }
            if ($null -ne $systemTls) { $stText = [string]$systemTls }

            $isCompliant = $false
            if ($strongCrypto -eq 1 -and $systemTls -eq 1) { $isCompliant = $true }

            $fix = @"
New-Item -Path '$path' -Force | Out-Null
New-ItemProperty -Path '$path' -Name SchUseStrongCrypto -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path '$path' -Name SystemDefaultTlsVersions -PropertyType DWord -Value 1 -Force | Out-Null
"@

            [pscustomobject]@{
                AuditType = '.NET'
                AppliesTo = 'Client+Server'
                Name      = ".NET 4.x ($arch)"
                Current   = if ($isCompliant) { 'Enabled' } else { 'Noncompliant' }
                Expected  = 'Enabled'
                Evidence  = "SchUseStrongCrypto=$scText; SystemDefaultTlsVersions=$stText"
                Key       = $path
                Note      = 'Both DWORD values must be 1.'
                Fix       = $fix
            }
        }
    }
}

<#
.SYNOPSIS
Evaluates secure communication configurations against target states.
#>
function HealthTest-SchannelCompliance {
    [CmdletBinding()]
    param()

    foreach ($role in @('Server','Client')) {
        $results = Get-SchannelProtocolState -Role $role -IncludeDotNetCheck:$false

        foreach ($item in $results) {
            if ($item.Expected -eq 'No requirement') { continue }

            $subject = "Schannel $($item.Name) $role"

            if ($item.Current -eq $item.Expected) {
                log-pass "$subject = $($item.Current)" -comment "Evidence: $($item.Evidence). Key: $($item.Key)."
            }
            else {
                $raw = @()
                if ($null -ne $item.EnabledRaw) { $raw += "Enabled=$($item.EnabledRaw)" }
                if ($null -ne $item.DisabledByDefaultRaw) { $raw += "DisabledByDefault=$($item.DisabledByDefaultRaw)" }
                $rawText = ''
                if ($raw.Count -gt 0) { $rawText = " Raw: " + ($raw -join ', ') + "." }

                $msg = "$subject expected $($item.Expected); got $($item.Current)"
                $c = "Evidence: $($item.Evidence).$rawText`nKey: $($item.Key).`nNote: $($item.Note)"
                if ($item.Fix) { $c = $c + "`n`nFix (example):`n$($item.Fix)" }
                log-failure $msg -comment $c
            }
        }
    }

    $dotNet = Get-SchannelProtocolState -Role 'Server' -IncludeDotNetCheck:$true | Where-Object { $_.AuditType -eq '.NET' }
    foreach ($item in $dotNet) {
        $subject = "$($item.Name)"
        if ($item.Current -eq $item.Expected) {
            log-pass "$subject = Enabled" -comment "Applies to: $($item.AppliesTo). Evidence: $($item.Evidence). Key: $($item.Key)."
        }
        else {
            $msg = "$subject expected Enabled; got $($item.Evidence)"
            $c = "Applies to: $($item.AppliesTo).`nKey: $($item.Key).`nNote: $($item.Note)`n`nFix (copy/paste):`n$($item.Fix)"
            log-failure $msg -comment $c
        }
    }
}
```



- "HealthTest-TrustsVerify"
- "HealthTest-ReplicationLatency"
- "HealthTest-UnconstrainedDelegationAccounts"
- "HealthTest-DuplicateSpn"
- "HealthTest-ServiceAccountsPwdNeverExpires"
