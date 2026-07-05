<#
Standalone file for HealthTest-RunningProcesses.
Generated during the repo-wide health-test split.
#>
# HostRequirement: All

function HealthTest-RunningProcesses {
<#
Description: Emits a suppressed inventory notice for each running process.
AppliesTo: All
Scope: Computer
Category: Audit/Compliance/Informational
Impact: low
Tags: Suppressed
Uses: None.

Lists every process currently running on the computer as suppressed NOTICE
messages. These messages are intended for inventory and auditing workflows, not
for normal operator attention.
#>
  $processes = $null
  try {
    $processes = Get-Process -IncludeUserName -ErrorAction Stop
  } catch {
    Write-Verbose "Get-Process -IncludeUserName failed; falling back to plain Get-Process: $($_.Exception.Message)"
    $processes = Get-Process
  }

  $reportedPairs = @{}
  $processes | Sort-Object -Property ProcessName, Id | ForEach-Object {
    $processName = [string]$_.ProcessName
    if (-not [string]::IsNullOrWhiteSpace($processName)) {
      $userName = if ($_.PSObject.Properties['UserName']) { [string]$_.UserName } else { '' }
      if ([string]::IsNullOrWhiteSpace($userName)) {
        $userName = '<unknown>'
      }

      $pairKey = "{0}`n{1}" -f $processName, $userName
      if (-not $reportedPairs.ContainsKey($pairKey)) {
        $reportedPairs[$pairKey] = $true
        Write-Warning "[NOTICE] Process '$processName' is running as '$userName'"
      }
    }
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-RunningProcesses
}
