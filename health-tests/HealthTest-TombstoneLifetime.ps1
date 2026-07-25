# HostRequirement: DC

function HealthTest-TombstoneLifetime{
<#
Description: Checks whether the AD tombstoneLifetime meets the minimum baseline.
AppliesTo: DC
Scope: Forest
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: Get-ADRootDSE, Get-ADObject.
#>
  [CmdletBinding()] param([int]$MinDays=60)
  $ds="CN=Directory Service,CN=Windows NT,CN=Services,$((Get-ADRootDSE).ConfigurationNamingContext)"
  $tl=(Get-ADObject $ds -Properties tombstoneLifetime).tombstoneLifetime
  if(-not $tl){$tl=60}
  if($tl -ge $MinDays){ Write-Warning "[PASS] AD tombstoneLifetime is sufficient ($tl days >= $MinDays)" }
  else{ Write-Warning "[FAILURE] AD tombstoneLifetime below threshold`nCurrent=$tl; Min=$MinDays" }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-TombstoneLifetime
}
