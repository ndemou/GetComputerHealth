if (-not (Get-Command -Name 'Get-ScheduledTaskFacts' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helper-regarding-scheduled-tasks.ps1')
}

if (-not (Get-Command -Name 'Format-ScheduledTaskDefinitionDetails' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helper-regarding-scheduled-tasks.ps1')
}

function HealthTest-ListScheduledTasks {
<#
Description: Lists persistent scheduled task definitions and reports short-lived one-shot tasks as informational.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Tags: Policy
Uses: Get-ScheduledTask, Get-ScheduledTaskInfo, Export-ScheduledTask.

Policy identity: stable task key plus fingerprint of normalized actions, principal, run level, logon type, triggers, hidden state, and enabled state. Last run time, next run time, missed runs, and last result are not included.
Policy baseline version: 2

Suppression: Known noisy tasks are excluded when their stable task key (normalized task path plus task name) matches a hard-coded wildcard pattern with PowerShell's case-insensitive -like operator. Suppression does not inspect task actions, publisher, signature, principal, or fingerprint.

Transient tasks: A task is treated as transient when it has exactly one enabled TimeTrigger, no repetition or calendar schedule, valid boundaries no more than five minutes apart, and a present DeleteExpiredTaskAfter setting. Recognized deletion durations from zero up to but not including one hour qualify. An unrecognized non-empty duration also qualifies but emits a separate warning. Transient tasks emit INFO with complete definition details but no definition fingerprint.
#>
  [CmdletBinding()]
  param()

  try {
    $facts = @(Get-ScheduledTaskFacts)
  } catch {
    Write-Warning "[FAILURE] Failed to collect scheduled task definitions: $($_.Exception.Message)"
    return
  }

  $suppressedStableKeyPatterns = @(
    '\OneDrive Reporting Task*'
    '\OneDrive Startup Task*'
    '\MicrosoftEdgeUpdateTaskMachineCore*'
    '\MicrosoftEdgeUpdateTaskMachineUA*'
    '\SoftLanding\*'
    '\Microsoft\Windows\*'
    '\Microsoft\Office\*'
  )

  $seen = 0
  foreach ($fact in ($facts | Sort-Object StableKey)) {
    $isSuppressed = $false
    foreach ($pattern in $suppressedStableKeyPatterns) {
      if ($fact.StableKey -like $pattern) {
        $isSuppressed = $true
        break
      }
    }

    if ($isSuppressed) {
      continue
    }

    $seen += 1
    $transientAnalysis = Get-ScheduledTaskTransientAnalysis -Fact $fact
    if ($transientAnalysis.IsTransient) {
      $details = Format-ScheduledTaskDefinitionDetails -Fact $fact -IncludeFingerprint $false
      Write-Warning "[INFO] Found transient scheduled task: $($fact.StableKey)`n$details"

      if ($transientAnalysis.HasUnrecognizedDeleteExpiredTaskAfter) {
        $unrecognizedValue = $transientAnalysis.DeleteExpiredTaskAfterText
        Write-Warning (
          "[WARNING] Transient scheduled task has an unrecognized DeleteExpiredTaskAfter value: " +
          "$($fact.StableKey)`n" +
          "DeleteExpiredTaskAfter: '$unrecognizedValue'.`n" +
          "The task otherwise matches the transient-task criteria and was treated as transient. " +
          "Confirm that this value means the task will be deleted shortly after expiration.`n" +
          $details
        )
      }

      continue
    }

    $level = 'NOTICE'
    if ($fact.IsPrivileged) { $level = 'WARNING' }

    Write-Warning "[$level] Found scheduled task: $($fact.StableKey) fingerprint=$($fact.PolicyFingerprint)`n$(Format-ScheduledTaskDefinitionDetails -Fact $fact)"
  }

  if ($seen -eq 0) {
    Write-Warning "[PASS] No reportable scheduled tasks discovered."
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-ListScheduledTasks
}

