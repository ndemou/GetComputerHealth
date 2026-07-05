<#
Standalone file for HealthTest-PreWin2000Group.
Generated during the repo-wide health-test split.
#>
# HostRequirement: DC

function HealthTest-PreWin2000Group{
<#
Description: Checks whether the Pre-Windows 2000 Compatible Access group has unexpected members.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: Get-ADGroup, Get-ADGroupMember.
#>
  $g=Get-ADGroup -Identity 'Pre-Windows 2000 Compatible Access'
  $m=Get-ADGroupMember $g -Recursive -ErrorAction SilentlyContinue
  foreach($u in $m){ Write-Warning "[FAILURE] 'Pre-Windows 2000 Compatible Access' contains member: $($u.SamAccountName)" }
  if(($m | Measure-Object).Count -eq 0){ Write-Warning "[PASS] 'Pre-Windows 2000 Compatible Access' group has no members" }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-PreWin2000Group
}
