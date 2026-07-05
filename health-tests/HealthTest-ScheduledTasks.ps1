<#
Standalone file for HealthTest-ScheduledTasks.
#>

if (-not (Get-Command -Name 'Get-ScheduledTaskDefaultPathIgnoreRegex' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'ScheduledTaskHelpers.ps1')
}

if (-not (Get-Command -Name 'Get-ScheduledTaskDefaultNameIgnorePatterns' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'ScheduledTaskHelpers.ps1')
}

if (-not (Get-Command -Name 'Get-ScheduledTaskFacts' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'ScheduledTaskHelpers.ps1')
}

if (-not (Get-Command -Name 'Test-ScheduledTaskRequired' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'ScheduledTaskHelpers.ps1')
}

if (-not (Get-Command -Name 'Test-ScheduledTaskIgnoredForOperationalChecks' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'ScheduledTaskHelpers.ps1')
}

if (-not (Get-Command -Name 'Format-ScheduledTaskFactDetails' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'ScheduledTaskHelpers.ps1')
}

if (-not (Get-Command -Name 'Get-ScheduledTaskOperationalSeverity' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'ScheduledTaskHelpers.ps1')
}

if (-not (Get-Command -Name 'Test-ScheduledTaskLastResultReportable' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'ScheduledTaskHelpers.ps1')
}

function HealthTest-ScheduledTasks {
<#
Description: Reviews scheduled tasks for failed results, disabled required tasks, missed runs, stale runs, and unreadable metadata.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-ScheduledTask, Get-ScheduledTaskInfo, Export-ScheduledTask.
#>
  [CmdletBinding()]
  param(
    [string[]]$MustBeEnabled = @(),
    [string[]]$Ignore = $(Get-ScheduledTaskDefaultPathIgnoreRegex),
    [string[]]$IgnoreTaskName = $(Get-ScheduledTaskDefaultNameIgnorePatterns),
    [switch]$IncludeHidden,
    [switch]$IncludeBuiltIn,
    [int]$StaleDays = 30
  )

  $hadIssue = $false

  try {
    $facts = @(Get-ScheduledTaskFacts)
  } catch {
    Write-Warning "[FAILURE] Failed to collect scheduled task facts: $($_.Exception.Message)"
    return
  }

  foreach ($fact in ($facts | Sort-Object StableKey)) {
    $isRequired = Test-ScheduledTaskRequired -Fact $fact -MustBeEnabled $MustBeEnabled
    $ignored = Test-ScheduledTaskIgnoredForOperationalChecks -Fact $fact -NamePatterns $IgnoreTaskName -PathRegex $Ignore

    if ((-not $IncludeHidden) -and $fact.Hidden -and (-not $isRequired)) {
      continue
    }

    if ($fact.InfoQueryFailed) {
      $hadIssue = $true
      if ($fact.InfoErrorKind -eq 'DeletedDuringScan') {
        Write-Warning "[NOTICE] Task '$($fact.StableKey)' was deleted while scheduled task metadata was being collected."
      }
      elseif ($fact.InfoErrorKind -eq 'CorruptXml') {
        Write-Warning "[WARNING] Task XML for '$($fact.StableKey)' is corrupted.`n$(Format-ScheduledTaskFactDetails -Fact $fact)"
      }
      else {
        Write-Warning "[FAILURE] Task '$($fact.StableKey)' failed Get-ScheduledTaskInfo with $($fact.InfoErrorHexCode) ($($fact.InfoErrorMessage)).`n$(Format-ScheduledTaskFactDetails -Fact $fact)"
      }
      continue
    }

    if ($fact.XmlQueryFailed) {
      $hadIssue = $true
      $level = Get-ScheduledTaskOperationalSeverity -Fact $fact -IssueType 'CorruptXml' -Required:$isRequired
      Write-Warning "[$level] Task XML for '$($fact.StableKey)' could not be read: $($fact.XmlErrorHexCode) ($($fact.XmlErrorMessage)).`n$(Format-ScheduledTaskFactDetails -Fact $fact)"
      continue
    }

    if ($ignored -and (-not $isRequired)) {
      continue
    }

    $isThirdPartyOrRequired = ((-not $fact.IsMicrosoftBuiltIn) -or $IncludeBuiltIn -or $isRequired)

    if ((-not $fact.Enabled) -or ($fact.State -eq 'Disabled')) {
      if ($isThirdPartyOrRequired) {
        $hadIssue = $true
        $level = Get-ScheduledTaskOperationalSeverity -Fact $fact -IssueType 'Disabled' -Required:$isRequired
        if ($isRequired -and $fact.IsSystemPrincipal) {
          Write-Warning "[$level] Required SYSTEM scheduled task is disabled: $($fact.StableKey)`n$(Format-ScheduledTaskFactDetails -Fact $fact)"
        } else {
          Write-Warning "[$level] Scheduled task is disabled: $($fact.StableKey)`n$(Format-ScheduledTaskFactDetails -Fact $fact)"
        }
      }
      continue
    }

    if (($null -ne $fact.LastResultCode) -and (-not $fact.LastResultIsInformational)) {
      if (Test-ScheduledTaskLastResultReportable -Fact $fact -Required:$isRequired -IncludeBuiltIn:$IncludeBuiltIn) {
        $hadIssue = $true
        $level = Get-ScheduledTaskOperationalSeverity -Fact $fact -IssueType 'LastResult' -Required:$isRequired
        Write-Warning "[$level] Scheduled task '$($fact.StableKey)' terminated with LastTaskResult=$($fact.LastResultHex) ($($fact.LastResultDescription)).`n$(Format-ScheduledTaskFactDetails -Fact $fact)"
      }
    }

    if ($fact.NumberOfMissedRuns -gt 0 -and $isThirdPartyOrRequired) {
      $hadIssue = $true
      if ($fact.NumberOfMissedRuns -ge 5) {
        $level = Get-ScheduledTaskOperationalSeverity -Fact $fact -IssueType 'ManyMissedRuns' -Required:$isRequired
      } else {
        $level = Get-ScheduledTaskOperationalSeverity -Fact $fact -IssueType 'FewMissedRuns' -Required:$isRequired
      }
      Write-Warning "[$level] Scheduled task missed $($fact.NumberOfMissedRuns) runs: $($fact.StableKey)`n$(Format-ScheduledTaskFactDetails -Fact $fact)"
    }

    if ($StaleDays -gt 0 -and $fact.HasEnabledTrigger -and $isThirdPartyOrRequired) {
      $lastRun = $fact.LastRunTime
      $isStale = $false
      $lastRunText = 'never'
      if ($null -eq $lastRun -or $lastRun -eq [datetime]::MinValue) {
        $isStale = $true
      } else {
        $lastRunDate = [datetime]$lastRun
        $lastRunText = $lastRunDate.ToString('yyyy-MM-dd')
        if (((Get-Date) - $lastRunDate).TotalDays -gt $StaleDays) {
          $isStale = $true
        }
      }

      if ($isStale) {
        $hadIssue = $true
        $level = Get-ScheduledTaskOperationalSeverity -Fact $fact -IssueType 'Stale' -Required:$isRequired
        Write-Warning "[$level] Scheduled task appears stale: $($fact.StableKey) LastRun=$lastRunText (> $StaleDays days or never).`n$(Format-ScheduledTaskFactDetails -Fact $fact)"
      }
    }
  }

  if (-not $hadIssue) {
    Write-Warning "[PASS] Scheduled tasks healthy"
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-ScheduledTasks
}

