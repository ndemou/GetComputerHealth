<#
Standalone file for HealthTest-RecycleBinEnabled.
Generated during the repo-wide health-test split.
#>
# HostRequirement: DC

function HealthTest-RecycleBinEnabled{
<#
Description: Checks whether Active Directory Recycle Bin is enabled.
AppliesTo: DC
Scope: Forest
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: Get-ADOptionalFeature.
#>
  $f=Get-ADOptionalFeature 'Recycle Bin Feature' -ErrorAction Stop
  $enabled=($f.EnabledScopes -ne $null -and $f.EnabledScopes.Count -gt 0)
  if($enabled){ Write-Warning "[PASS] AD Recycle Bin enabled" } else { Write-Warning "[NOTICE] AD Recycle Bin is not enabled -- consider enabling it." }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-RecycleBinEnabled
}
