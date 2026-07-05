<#
Standalone file for HealthTest-AdminSDHolderCoverage.
Generated during the repo-wide health-test split.
#>
# HostRequirement: DC

function HealthTest-AdminSDHolderCoverage{
<#
Description: Reports whether AdminSDHolder protection is currently applied to any users.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-ADUser.
#>
  $prot=Get-ADUser -LDAPFilter '(adminCount=1)' -Properties MemberOf | Select-Object -ExpandProperty SamAccountName
  if($prot){ Write-Warning "[PASS] AdminSDHolder applied; protected users: $($prot -join ", ")" } else { Write-Warning "[PASS] No users currently protected by AdminSDHolder" }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-AdminSDHolderCoverage
}
