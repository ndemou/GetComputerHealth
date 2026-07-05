<#
Standalone file for HealthTest-KrbtgtAge.
Generated during the repo-wide health-test split.
#>
# HostRequirement: DC

function HealthTest-KrbtgtAge{
<#
Description: Checks whether the KRBTGT password has been rotated within the allowed age threshold.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-ADUser.
#>
  [CmdletBinding()] param([int]$MaxDays=720)
  $u=Get-ADUser krbtgt -Properties pwdLastSet
  $ageDays=[int]((Get-Date) - [DateTime]::FromFileTime($u.pwdLastSet)).TotalDays
  if($ageDays -le $MaxDays){
    Write-Warning "[PASS] krbtgt password age acceptable ($ageDays days <= $MaxDays)"
  } else {
    Write-Warning "[FAILURE] krbtgt password age exceeds threshold ($MaxDays)`nThe KRBTGT account key hasn't been rotated for $ageDays days. Windows keeps the previous KRBTGT key to validate existing TGTs; never rotating extends the attack window. Risk: if an attacker ever accessed the KRBTGT key, they can mint TGTs and persist. Rotating twice (with replication time in between) is the standard mitigation."
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-KrbtgtAge
}
