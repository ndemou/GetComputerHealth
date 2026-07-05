<#
Standalone file for HealthTest-NtdsPathsLocation.
Generated during the repo-wide health-test split.
#>
# HostRequirement: DC

function HealthTest-NtdsPathsLocation{
<#
Description: Checks whether the NTDS database and log paths are on expected volumes.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: None.
#>
  [CmdletBinding()]
  param(
    [string[]]$ExpectedDbRoots,
    [string[]]$ExpectedLogRoots
  )
  $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
  $db = (Get-ItemProperty -Path $regPath -Name 'DSA Database file' -ErrorAction Stop).'DSA Database file'
  $lg = (Get-ItemProperty -Path $regPath -Name 'Database log files path' -ErrorAction Stop).'Database log files path'

  $dbOk = if($ExpectedDbRoots -and $ExpectedDbRoots.Count){
    ($ExpectedDbRoots | Where-Object { $db -like "$($_)*" -or ([IO.Path]::GetPathRoot($db) -eq $_) }).Count -gt 0
  } else { $true }
  if(-not $dbOk){ Write-Warning "[FAILURE] NTDS database path not on an expected volume`nDB=$db; Expected roots: $($ExpectedDbRoots -join ', ')" }

  $lgOk = if($ExpectedLogRoots -and $ExpectedLogRoots.Count){
    ($ExpectedLogRoots | Where-Object { $lg -like "$($_)*" -or ([IO.Path]::GetPathRoot($lg) -eq $_) }).Count -gt 0
  } else { $true }
  if(-not $lgOk){ Write-Warning "[FAILURE] NTDS log path not on an expected volume`nLOGS=$lg; Expected roots: $($ExpectedLogRoots -join ', ')" }

  if($dbOk -and $lgOk){ Write-Warning "[PASS] NTDS database/log paths sane (DB=$db; LOGS=$lg)" }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-NtdsPathsLocation
}
