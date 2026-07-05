<#
Standalone file for HealthTest-ListRolesFeatures.
Generated during the repo-wide health-test split.
#>
# HostRequirement: Server

function HealthTest-ListRolesFeatures {
<#
Description: Lists installed Windows roles and features.
AppliesTo: Server
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Tags: Policy
Uses: Get-WindowsFeature.

Policy identity: Windows feature name. Display name, install date, and current runtime state are not included.
Policy baseline version: 1
#>
  [CmdletBinding()]
  $roles = $null
  try { $roles = Get-WindowsFeature -ErrorAction Stop | Where-Object { $_.Installed } }
  catch {
    Write-Output "Get-WindowsFeature not available on this OS; skipping role/feature check"
    return
  }

  if (@($roles).Count -gt 0) {
    foreach ($role in $roles) { Write-Warning "[WARNING] Installed role/feature: $($role.Name)" }
  } else {
    Write-Warning "[PASS] No installed roles/features found"
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-ListRolesFeatures
}
