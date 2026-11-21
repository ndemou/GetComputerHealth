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
Impact: High(Time)
Tags: Policy
Uses: Get-ScheduledTask, Export-ScheduledTask, Get-AuthenticodeSignature.

Policy identity: stable task key plus fingerprint of normalized actions, principal, run level, logon type, triggers, hidden state, and enabled state. Last run time, next run time, missed runs, and last result are not included.
Policy baseline version: 2

Exceptions: Signed exceptions report INFO for a matching task key and a single executable action at the expected path with a valid Authenticode signature from the expected signer. Legacy exclusions match only the task key.

Transient tasks: A task is treated as transient when it has exactly one enabled TimeTrigger, no repetition or calendar schedule, valid boundaries no more than five minutes apart, and a present DeleteExpiredTaskAfter setting. Recognized deletion durations from zero up to but not including one hour qualify. An unrecognized non-empty duration also qualifies but emits a separate warning. Transient tasks emit INFO with complete definition details but no definition fingerprint.
#>
  [CmdletBinding()]
  param()

  # Task patterns match the full task path and name. Executable patterns are relative to Program Files.
  $signedTaskExceptions = @(
    @{
      Tasks = '\COMODO\COMODO Scan *'
      Executable = 'COMODO\COMODO Internet Security\cfpconfg.exe'
      Signer = 'COMODO Security Solutions, Inc.'
    }
    @{
      Tasks = '\OneDrive Reporting Task*'
      Executable = 'Microsoft OneDrive\OneDriveStandaloneUpdater.exe'
      Signer = 'Microsoft Corporation'
    }
    @{
      Tasks = '\OneDrive Startup Task*'
      Executable = 'Microsoft OneDrive\*\OneDriveLauncher.exe'
      Signer = 'Microsoft Corporation'
    }
    @{
      Tasks = '\MicrosoftEdgeUpdateTaskMachineCore*', '\MicrosoftEdgeUpdateTaskMachineUA*'
      Executable = 'Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe'
      Signer = 'Microsoft Corporation'
    }
    @{
      Tasks = '\Microsoft\Office\Office Actions Server', '\Microsoft\Office\Office Startup Maintenance'
      Executable = 'Microsoft Office\root\VFS\ProgramFilesCommonX*\Microsoft Shared\Office16\ActionsServer\ActionsServer.exe'
      Signer = 'Microsoft Corporation'
    }
    @{
      Tasks = '\Microsoft\Office\Office Automatic Updates 2.0', '\Microsoft\Office\Office ClickToRun Service Monitor',
        '\Microsoft\Office\Office Feature Updates C2R Client', '\Microsoft\Office\Office Feature Updates C2R Client Logon'
      Executable = 'Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe'
      Signer = 'Microsoft Corporation'
    }
    @{
      Tasks = '\Microsoft\Office\Office Feature Updates', '\Microsoft\Office\Office Feature Updates Logon'
      Executable = 'Microsoft Office\root\Office16\sdxhelper.exe'
      Signer = 'Microsoft Corporation'
    }
    @{
      Tasks = '\Microsoft\Office\Office Background Push Maintenance'
      Executable = 'Microsoft Office\root\VFS\ProgramFilesCommonX*\Microsoft Shared\Office16\opushutil.exe'
      Signer = 'Microsoft Corporation'
    }
    @{
      Tasks = '\Microsoft\Office\Office Performance Monitor'
      Executable = 'Microsoft Office\root\VFS\ProgramFilesCommonX*\Microsoft Shared\Office16\operfmon.exe'
      Signer = 'Microsoft Corporation'
    }
    @{
      Tasks = '\Microsoft\Office\Office Serviceability Manager'
      Executable = 'Common Files\Microsoft Shared\ClickToRun\officesvcmgr.exe'
      Signer = 'Microsoft Corporation'
    }
  )

  $legacyExclusions = '\SoftLanding\*', '\Microsoft\Windows\*'
  $programFilesRoots = @($env:ProgramFiles, $env:ProgramW6432, ${env:ProgramFiles(x86)})

  try {
    $facts = @(Get-ScheduledTaskFacts)
  } catch {
    Write-Warning "[FAILURE] Failed to collect scheduled task definitions: $($_.Exception.Message)"
    return
  }

  $seen = 0
  foreach ($fact in ($facts | Sort-Object StableKey)) {
    if (Test-ScheduledTaskNameMatchesAnyPattern -Name $fact.StableKey -Patterns $legacyExclusions) {
      continue
    }

    $seen += 1
    $transientAnalysis = Get-ScheduledTaskTransientAnalysis -Fact $fact
    if ($transientAnalysis.IsTransient) {
      $details = Format-ScheduledTaskDefinitionDetails -Fact $fact -IncludeFingerprint $false
      Write-Warning "[INFO] Found transient scheduled task: $($fact.StableKey)`n$details"

      if ($transientAnalysis.HasUnrecognizedDeleteExpiredTaskAfter) {
        $unrecognizedValue = $transientAnalysis.DeleteExpiredTaskAfterText
        $message = @(
          "[WARNING] Transient scheduled task has an unrecognized DeleteExpiredTaskAfter value: $($fact.StableKey)"
          "DeleteExpiredTaskAfter: '$unrecognizedValue'."
          'The task otherwise matches the transient-task criteria and was treated as transient. Confirm that this value means the task will be deleted shortly after expiration.'
          $details
        ) -join "`n"
        Write-Warning $message
      }

      continue
    }

    $signer = Get-ScheduledTaskExceptionSigner -Fact $fact -Rules $signedTaskExceptions -ProgramFilesRoots $programFilesRoots
    if ($signer) {
      $details = Format-ScheduledTaskDefinitionDetails -Fact $fact -IncludeFingerprint $false
      Write-Warning "[INFO] Found scheduled task covered by signed exception: $($fact.StableKey)`nSigner: $signer`n$details"
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

function Get-ScheduledTaskExceptionSigner {
  param($Fact, [hashtable[]]$Rules, [string[]]$ProgramFilesRoots)

  if ($Fact.Actions.Count -ne 1 -or $Fact.Actions[0].Type -ne 'ExecAction') {
    return
  }

  $exe = $Fact.Actions[0].Execute -replace '^"([^"]+)"$', '$1'
  # Office Click-to-Run tasks can use this machine installation directory in their paths.
  if ($exe -like '%CommonProgramFiles%\*') {
    $exe = [Environment]::ExpandEnvironmentVariables($exe)
  }
  if ($exe -notmatch '^[a-z]:\\[^":%]+\.exe$') {
    return
  }

  try {
    $exe = [IO.Path]::GetFullPath($exe)
    $relativeExe = $null
    foreach ($root in $ProgramFilesRoots) {
      if (-not $root) { continue }
      $prefix = $root.TrimEnd('\') + '\'
      if ($exe.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        $relativeExe = $exe.Substring($prefix.Length)
        break
      }
    }
    if (-not $relativeExe) { return }

    $expectedSigners = foreach ($rule in $Rules) {
      if ($relativeExe -like $rule.Executable -and
          (Test-ScheduledTaskNameMatchesAnyPattern -Name $Fact.StableKey -Patterns $rule.Tasks)) {
        $rule.Signer
      }
    }
    if (-not $expectedSigners) { return }

    $signature = Get-AuthenticodeSignature -LiteralPath $exe -ErrorAction Stop
    if ($signature.Status -eq 'Valid' -and $signature.SignerCertificate) {
      $signer = $signature.SignerCertificate.GetNameInfo('SimpleName', $false)
      if ($signer -in $expectedSigners) { return $signer }
    }
  } catch {
    Write-Verbose "Could not verify the scheduled task executable '$exe': $($_.Exception.Message)"
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-ListScheduledTasks
}

