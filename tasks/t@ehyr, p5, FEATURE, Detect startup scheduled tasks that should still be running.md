<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:37:08.515Z","completions":[]} -->

Detect Scheduled Tasks that are configure to run on boot and are expected be running continously but are not running at the moment.
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
