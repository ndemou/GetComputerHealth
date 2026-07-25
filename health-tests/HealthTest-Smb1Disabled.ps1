# HostRequirement: All

function HealthTest-Smb1Disabled{
<#
Description: Checks whether SMBv1 is disabled.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-WindowsOptionalFeature.
#>
  if ($RunWithoutElevation) {
    Write-Warning "[WARNING] this test requires elevation"
    return
  }

  $f=Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -ErrorAction SilentlyContinue
  $state=$f.State
  $disabled=($state -eq 'Disabled' -or -not $f -or $state -eq 'DisabledWithPayloadRemoved')
  if($disabled){ Write-Warning "[PASS] SMBv1 is disabled"} else { Write-Warning "[WARNING] SMBv1 is enabled`nState=$state" }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-Smb1Disabled
}
