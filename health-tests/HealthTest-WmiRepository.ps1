# HostRequirement: All

function HealthTest-WmiRepository{
<#
Description: Checks whether the WMI repository is consistent.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Tags: Essential
Uses: winmgmt.exe.
#>
  $out=& winmgmt /verifyrepository 2>&1
  $ok=($out -match 'consistent')
  if($ok){ Write-Warning "[PASS] WMI repository consistent"} else { Write-Warning ("[FAILURE] WMI repository inconsistent`n" + ($out -join ' ')) }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-WmiRepository
}
