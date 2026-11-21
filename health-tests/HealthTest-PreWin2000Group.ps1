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
  $groupName = 'Pre-Windows 2000 Compatible Access'
  $operation = 'Get-ADGroup'
  try {
    $group = Get-ADGroup -Identity $groupName -ErrorAction Stop
    if (-not $group) { throw 'The group lookup returned no group.' }

    $operation = 'Get-ADGroupMember -Recursive'
    $members = @(Get-ADGroupMember -Identity $group -Recursive -ErrorAction Stop)
  } catch {
    Write-Warning "[WARNING] Could not check '$groupName' membership`n$($operation): $($_.Exception.Message)"
    return
  }

  foreach ($member in $members) {
    Write-Warning "[FAILURE] '$groupName' contains member: $($member.SamAccountName)"
  }
  if ($members.Count -eq 0) {
    Write-Warning "[PASS] '$groupName' group has no members"
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-PreWin2000Group
}
