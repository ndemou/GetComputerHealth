<#
Scheduled Task Master Cluster
#>

function HealthTest-ScheduledTasks {
    $task_name_paterns_to_ignore = @(
      'OneDrive Per-Machine Standalone Update Task*',
      'OneDrive Reporting Task*',
      'OneDrive Standalone Update*',
      'Office Feature Updates*',
      'Firefox Background Update*',
      'Firefox Default Browser Agent*',
      'Office Actions Server*',
      'Clipboard User Service*',
      "Optimize Start Menu Cache Files-*",
      "User_Feed_Synchronization-*"
    )
    $OK_TASK_RESULTS = @(0,267009,267010,267011,267012,267013,267014)

    $problem_found = $false
    $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | ?{$_.TaskPath -notlike "\Microsoft\Windows\*"}

    foreach ($t in $tasks) {
        $skip = $false
        foreach ($p in $task_name_paterns_to_ignore) {
          if ($t.TaskName -like $p) { $skip = $true; break }
        }
        if ($skip) { continue }

        $i = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue
        if ($i -and ($i.LastTaskResult -notin $OK_TASK_RESULTS -or $i.NumberOfMissedRuns -gt 0)) {
            $problem_found = $true
            $details=(Get-ScheduledTaskDeepInfo -TaskName $t.TaskName -TaskPath $t.TaskPath |
              Select-Object state,actions,Description,RunAcntUserId,RunLogonType,LastRunTime,NextRunTime | %{
                $_.PSObject.Properties |
                  Where-Object { $_.Value -ne $null -and "$($_.Value)" -ne '' } |
                    ForEach-Object {
                      if ($_.Name -eq 'actions') {
                        $acts = @($_.Value)
                        foreach($a in $acts){
                          if($null -eq $a){ continue }
                          if($a.PSObject.Properties.Name -contains 'Execute'){
                            "Command: $($a.Execute) $($a.Arguments)"
                          } else {
                            $t = $a.GetType().FullName
                            "Action: $t"
                          }
                        }
                      } else {
                        "{0}: {1}" -f $_.Name, $_.Value
                      }
                    }
              } | out-string)
            if ($i.LastTaskResult -notin $OK_TASK_RESULTS) {
                $meaning = Convert-TaskResultCode $i.LastTaskResult
                Write-Warning "[warning] Scheduled Task with failures: '$($t.TaskPath)$($t.TaskName)'; Last exit code: $($i.LastTaskResult) ($meaning)`nDetails about this task:`r`n$details"
            }
            if ($i.NumberOfMissedRuns -gt 0) {
                if ($i.NumberOfMissedRuns -lt 5){
                    if ($t.TaskName -like '*update*' `
                        -or $t.TaskName -like '*Maintenance*' `
                        -or $t.TaskName -in @('Office Serviceability Manager','Resolut Refresh') `
                    ) {
                        Write-Warning "[info] Scheduled Task with just a few missed runs(<5): '$($t.TaskPath)$($t.TaskName)'`n$($i.NumberOfMissedRuns) runs where missed. Details about this task: $details"
                    } else {
                        Write-Warning "[notice] Scheduled Task with just a few missed runs(<5): '$($t.TaskPath)$($t.TaskName)'`n$($i.NumberOfMissedRuns) runs where missed. Details about this task: $details"
                    }
                } else {
                    Write-Warning "[warning] Scheduled Task with missed runs: '$($t.TaskPath)$($t.TaskName)'`n$($i.NumberOfMissedRuns) runs where missed. Details about this task: $details"
                }
            }
        }
    }
    if ($problem_found) { return }

    Write-Warning "[pass] Scheduled tasks healthy (non-Microsoft)"
}

function HealthTest-SystemScheduledTasks{
  [CmdletBinding()] param(
    [string[]]$MustBeEnabled = @(),  # exact paths or regex
    [string[]]$Ignore = @(
      '^\\Microsoft\\Windows\\(AppxDeploymentClient|Bluetooth|Clip|PushToInstall|SharedPC)\\',
      '^\\Microsoft\\Windows\\(InstallService|WaaSMedic|UpdateOrchestrator)\\',
      '^\\Microsoft\\Windows\\(PLA\\Server Manager Performance Monitor|File Classification Infrastructure\\Property Definition Sync)$',
      '^\\Microsoft\\Windows\\\.NET Framework\\\.NET Framework NGEN v4\.0\.30319.*$',
      '^\\Microsoft\\Windows\\Server Initial Configuration Task$'
    ),
    [switch]$IncludeHidden,
    [switch]$IncludeBuiltIn,   # include Microsoft-authored tasks in checks
    [int]$StaleDays = 30,
    [switch]$WarnOnNonZeroLastResult
  )

  $hadIssue = $false
  $isSystem       = { param($t) $t.Principal.UserId -match '^(NT AUTHORITY\\)?SYSTEM$' }
  $isMicrosoft    = { param($t) ($t.Author -match 'Microsoft') -or ($t.TaskPath -like '\Microsoft\*') }
  $shouldIgnore   = { param($path) foreach($rx in $Ignore){ if($path -match $rx){ return } } return }
  $isRequired     = { param($path) foreach($rx in $MustBeEnabled){ if($path -match $rx){ return } } return }

  $tasks = Get-ScheduledTask | Where-Object { & $isSystem $_ }
  if(-not $IncludeHidden){ $tasks = $tasks | Where-Object { -not $_.Settings.Hidden } }
  if(-not $IncludeBuiltIn){ $tasks = $tasks | Where-Object { -not (& $isMicrosoft $_) } }

  foreach($t in $tasks){
    # Keep the leading "\" so paths look like \Microsoft\Windows\...
    $path = "$($t.TaskPath.TrimEnd('\'))\$($t.TaskName)"
    if(& $shouldIgnore $path){ continue }

    $info = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath
    $enabled = [bool]$t.Settings.Enabled
    $state = $t.State
    $hasEnabledTrigger = ($t.Triggers | Where-Object { $_.Enabled }) -ne $null
    $lastRun = $info.LastRunTime
    if (-not $lastRun) {$lastRun = [datetime]::new(1900, 1, 1)}
    $lastRes = ('0x{0:X8}' -f ([uint32]$info.LastTaskResult))

    # 1) Disabled tasks
    if(-not $enabled -or $state -eq 'Disabled'){
      $hadIssue = $true
      if(& $isRequired $path){ Write-Warning "[failure] Required SYSTEM task is disabled: $path" }
      else { Write-Warning "[warning] SYSTEM task is disabled: $path" }
      continue
    }

    # 2) Stale runs (only if triggers exist)
    if($hasEnabledTrigger -and $StaleDays -gt 0){
      if(($lastRun -eq [datetime]::MinValue) -or ((Get-Date) - $lastRun).TotalDays -gt $StaleDays){
        $hadIssue = $true
        Write-Warning "[warning] SYSTEM task appears stale: $path ; LastRun=$lastRun (> $StaleDays days or never)"
      }
    }

    # 3) Non-zero last result (optional)
    if($WarnOnNonZeroLastResult -and $info.LastTaskResult -ne 0){
      $hadIssue = $true
      if(& $isRequired $path){ Write-Warning "[failure] Required SYSTEM task has non-zero LastTaskResult: $path ; Code=$lastRes" }
      else { Write-Warning "[warning] SYSTEM task has non-zero LastTaskResult: $path ; Code=$lastRes" }
    }
  }

  if(-not $hadIssue){ Write-Warning "[pass] All relevant SYSTEM scheduled tasks are enabled and healthy" }
}


function Convert-ISODuration{
  param([string]$Iso)
  if(-not $Iso){return $null}
  $m=[regex]::Match($Iso,'^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$')
  if(-not $m.Success){return $Iso}
  $parts=@()
  if($m.Groups[1].Value){$n=[int]$m.Groups[1].Value;$parts+=("$n day"+($(if($n-ne 1){'s'}else{''})))}
  if($m.Groups[2].Value){$n=[int]$m.Groups[2].Value;$parts+=("$n hour"+($(if($n-ne 1){'s'}else{''})))}
  if($m.Groups[3].Value){$n=[int]$m.Groups[3].Value;$parts+=("$n minute"+($(if($n-ne 1){'s'}else{''})))}
  if($m.Groups[4].Value){$n=[int]$m.Groups[4].Value;$parts+=("$n second"+($(if($n-ne 1){'s'}else{''})))}
  if($parts.Count -eq 0){return $Iso}
  $parts -join ' '
}


function Convert-TaskResultCode{
  param([int64]$Code)
  $hex = ('0x{0:X8}' -f $Code)
  switch($Code){
    0{"Success (0)"}
    2147750687{"Operator/admin refused ($hex)"}
    2147942402{"File not found ($hex)"}
    2147942403{"Path not found ($hex)"}
    2147942405{"Access denied ($hex)"}
    2147954402{"Service not started ($hex)"}
    267008{"Ready ($hex)"}
    267009{"Running ($hex)"}
    267010{"Disabled ($hex)"}
    267011{"Not yet run ($hex)"}
    267012{"No more runs ($hex)"}
    267013{"Terminated ($hex)"}
    267014{"No active triggers ($hex)"}
    2147946720{"Either wrong password or win32 error 0x800710E0('The operator or administrator has refused the request')"}
    default{
          $win32 = if ($Code -band 0x80070000) { $Code -band 0xFFFF } else { $Code }
          try {
            $win32msg = (New-Object ComponentModel.Win32Exception ([int]$win32)).Message
          } catch {
            $win32msg = ""
          }
          if ($win32msg) {"Possible win32 error $hex('$win32msg')"} else {"Non standard code hex=$hex"}
    }
  }
}


function Get-ScheduledTaskDeepInfo{
  [CmdletBinding()]param(
    [Parameter(Mandatory=$true)][string]$TaskName,
    [string]$TaskPath
  )

  function _TaskDesc($n,$p){
    try{([xml](Export-ScheduledTask -TaskName $n -TaskPath $p -ErrorAction Stop)).Task.RegistrationInfo.Description}
    catch{$null}
  }
  function _TrigType($tr){
    if($tr.PSObject.Properties.Match('TriggerType').Count -and $tr.TriggerType){return $tr.TriggerType}
    if($tr.PSObject.Properties.Match('CimClass').Count -and $tr.CimClass){return ($tr.CimClass.CimClassName -replace '^MSFT_Task','')}
    ($tr.PSObject.TypeNames|Select-Object -First 1)
  }

  $tasks = if($TaskPath){
    Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
  }else{
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -eq $TaskName }
  }
  if(-not $tasks){ throw "Task '$TaskName' not found." }

  $out=@()
  foreach($t in $tasks){
    $info=Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue
    $full="$($t.TaskPath)$($t.TaskName)"
    $desc=_TaskDesc $t.TaskName $t.TaskPath

    $acts=@()
    foreach($a in $t.Actions){
      $acts+=[pscustomobject]@{
        Type=$a.ActionType
        Execute=$a.Execute
        Arguments=$a.Arguments
        WorkingDirectory=$a.WorkingDirectory
      }
    }

    $trigs=@()
    foreach($tr in $t.Triggers){
      $rep=$null
      if($tr.PSObject.Properties.Match('Repetition').Count -and $tr.Repetition){
        $rep=[pscustomobject]@{
          Interval=$tr.Repetition.Interval
          Duration=$tr.Repetition.Duration
          StopAtDurationEnd=$tr.Repetition.StopAtDurationEnd
        }
      }
      $sumParts=@()
      if($rep -and $rep.Interval){$sumParts+="Every $(Convert-ISODuration $rep.Interval)"}
      if($tr.StartBoundary){$sumParts+="from $([datetime]$tr.StartBoundary)"}
      if($tr.EndBoundary){$sumParts+="until $([datetime]$tr.EndBoundary)"}
      if($tr.Enabled -ne $null){$sumParts+="enabled: $($tr.Enabled)"}

      $trigs+=[pscustomobject]@{
        Type=_TrigType $tr
        Start=$tr.StartBoundary
        End=$tr.EndBoundary
        Enabled=$tr.Enabled
        Every = $( if($rep -and $rep.Interval){ Convert-ISODuration $rep.Interval } else { $null } )
        Duration = $( if($rep -and $rep.Duration){ Convert-ISODuration $rep.Duration } else { $null } )
        StopAtDurationEnd = $( if($rep){ $rep.StopAtDurationEnd } else { $null } )
        RandomDelay = $( Convert-ISODuration $tr.RandomDelay )
        ExecutionTimeLimit = $( Convert-ISODuration $tr.ExecutionTimeLimit )
        DaysOfWeek=$tr.DaysOfWeek
        DaysOfMonth=$tr.DaysOfMonth
        MonthsOfYear=$tr.MonthsOfYear
        Summary=($sumParts -join ' ')
      }
    }

    [pscustomobject]@{
      PathPlusName=$full
      State=$t.State
      Enabled=($t.State -ne 'Disabled')
      Actions=$acts
      LastTaskResult="$($info.LastTaskResult); $(Convert-TaskResultCode $info.LastTaskResult)"
      Description=$desc
      Author=$t.Author
      RunAcntUserId="$($t.Principal.UserId) $($t.Principal.DisplayName)"
      RunLevel=$t.Principal.RunLevel
      RunLogonType=$t.Principal.LogonType
      LastRunTime=$info.LastRunTime
      NextRunTime=$info.NextRunTime
      NumberOfMissedRuns=$info.NumberOfMissedRuns
      Triggers=$trigs
      Settings=[pscustomobject]@{
        AllowDemandStart=$t.Settings.AllowDemandStart
        StartWhenAvailable=$t.Settings.StartWhenAvailable
        MultipleInstances=$t.Settings.MultipleInstances
        WakeToRun=$t.Settings.WakeToRun
        DisallowStartIfOnBatteries=$t.Settings.DisallowStartIfOnBatteries
        StopIfGoingOnBatteries=$t.Settings.StopIfGoingOnBatteries
        ExecutionTimeLimit=$( Convert-ISODuration $t.Settings.ExecutionTimeLimit )
        Priority=$t.Settings.Priority
      }
    }
  }
}

function HealthTest-ScheduledTasksLastResult {
  $mapHresult = @{
    0x40010004=@{d='Process terminated externally'}
    0x80070001=@{d='Incorrect function'}
    0x80070002=@{d='File or path not found'}
    0x80070003=@{d='Path not found'}
    0x80070005=@{d='Access denied'}
    0x8007000A=@{d='Invalid environment'}
    0x8007000B=@{d='Bad EXE format / arch mismatch'}
    0x80070070=@{d='Disk full'}
    0x8007052E=@{d='Logon failure (bad username/password)'}
    0x80070533=@{d='Account disabled'}
    0x800705B4=@{d='Operation timed out'}
    0x800706BA=@{d='RPC server unavailable'}
    0x80040121=@{d='Storage access denied'}
    0x80040154=@{d='COM class not registered'}
    0x800401F5=@{d='COM application not found'}
    0x8004130F=@{d='Task engine execution error/timeout'}
    0x80004005=@{d='Unspecified failure'}
    0x80090020=@{d='Cryptographic/DPAPI failure'}
    0xC000006D=@{d='Logon failure'}
    0xC000006A=@{d='Wrong password'}
    0xC0000064=@{d='Unknown user'}
    0xC0000072=@{d='Account disabled'}
    0xC0000234=@{d='Account locked out'}
  }
  $mapWin32Bare = @{
    1056=@{d='Service already running'}
    1326=@{d='Logon failure (bad username/password)'}
    1331=@{d='Account disabled'}
    1909=@{d='Account locked out'}
  }

  function Normalize-Code($v){
    if($null -eq $v){return $null}
    $s="$v".Trim()
    if($s -eq '' -or $s -eq 'N/A'){return $null}
    if($s -match '(?i)^0x([0-9a-f]{1,8})$'){return [int64]([uint32]::Parse($matches[1],[System.Globalization.NumberStyles]::HexNumber))}
    if($s -match '^-?\d+$'){return [int64]$s}
    $null
  }
  function To-UInt32($code){
    try{
      $i64=[int64]$code
      $u64=[uint64]($i64 -band 0xFFFFFFFFFFFFFFFF)
      [uint32]($u64 -band 0x00000000FFFFFFFF)
    }catch{$null}
  }
  function Get-Severity($u32,$isBare){
    if($isBare){return 'Error'}
    if($null -eq $u32){return 'Error'}
    $sev=($u32 -band 0xC0000000)
    if($sev -eq 0x80000000){'Error'}
    elseif($sev -eq 0x40000000){'Warning'}
    elseif($u32 -eq 0){'Success'}
    else{'Success'}
  }

  # Suppress purely informational "Last Result" values entirely
  $benign = [uint32[]](0x00000000,0x10000000,0x40010004) # S_OK, success-severity flag, DBG_TERMINATE_PROCESS
  function Is-Informational($u32,$sev){
    if($null -eq $u32){return $false}
    if($benign -contains $u32){return $true}
    if($sev -eq 'Success'){return $true}
    if($u32 -ge 0x00041300 -and $u32 -le 0x000413FF){return $true} # SCHED_S_* family
    $false
  }

  function Get-RowValue{ param($row,[string[]]$names)
    foreach($n in $names){
      if($row.PSObject.Properties.Name -contains $n){
        $v=$row.$n; if($v){return "$v"}
      }
    }
    $null
  }

  $want = [ordered]@{
    'Task Name'         = @('TaskName','Task Name')
    'Run As User'       = @('Run As User','RunAsUser')
    'Last Run Time'     = @('Last Run Time','LastRunTime')
    'Next Run Time'     = @('Next Run Time','NextRunTime')
    'Status'            = @('Status')
    'Schedule Type'     = @('Schedule Type','ScheduleType')
    'Triggers'          = @('Schedule','Triggers')
    'Task To Run'       = @('Task To Run','TaskToRun','Actions')
    'Start In'          = @('Start In','StartIn')
    'Logon Mode'        = @('Logon Mode','LogonMode')
    'Author'            = @('Author')
    'Last Result (raw)' = @('Last Result','LastResult')
  }

  $passed = $true
  # These conditions:
  #     $_.'Last Result' -notmatch 'Last Result' -and $_.HostName -eq $env:COMPUTERNAME
  # filter-out plenty of invalid lines that schtasks generates
  $tasks = schtasks /query /fo csv /v | ConvertFrom-Csv | Where-Object {
    $_.'Last Result' -ne 0 -and `
    $_.'Last Result' -notmatch 'Last Result' -and $_.HostName -eq $env:COMPUTERNAME
  }

  foreach($t in $tasks){
    $dec = Normalize-Code $t.'Last Result'
    if($null -eq $dec){ continue }
    $u32 = To-UInt32 $dec
    if($null -eq $u32){ continue }

    $isBare = $mapWin32Bare.ContainsKey($u32)
    $sev = Get-Severity $u32 $isBare
    if(Is-Informational $u32 $sev){ continue } # suppress informational results

    $info = if($isBare){ $mapWin32Bare[$u32] } else { $mapHresult[$u32] }
    $desc = if($info){ $info.d } else { 'Unknown failure' }
    $hex  = ('0x{0:X8}' -f $u32)
    $msg  = "Scheduled Task '$($t.TaskName)' terminated with Last Result=$hex('$desc')"

    $lines=@()
    foreach($k in $want.Keys){
      $val = Get-RowValue -row $t -names $want[$k]
      if($val){ $lines += ('{0}: {1}' -f $k,$val) }
    }
    $details = ($lines -join "`r`n")

    if($sev -eq 'Error'){ Write-Warning "[failure] $($msg)`n$($details)"; $passed = $false }
    elseif($sev -eq 'Warning'){ Write-Warning "[warning] $($msg)"; $passed = $false }
  }

  if ($passed) {
      Write-Warning "[pass] HealthTest-ScheduledTasksLastResult found no problem"
  }
}
