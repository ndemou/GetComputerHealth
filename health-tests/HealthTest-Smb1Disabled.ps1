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

  try {
    $feature = Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -ErrorAction Stop
  } catch {
    Write-Warning "[WARNING] Could not read SMBv1 feature state`n$($_.Exception.Message)"
    return
  }

  if (-not $feature -or -not $feature.PSObject.Properties['State'] -or -not $feature.State) {
    Write-Warning "[WARNING] SMBv1 feature state is unavailable"
    return
  }

  $state = $feature.State
  if ($state -in @('Disabled', 'DisabledWithPayloadRemoved')) {
    Write-Warning "[PASS] SMBv1 is disabled"
  } elseif ($state -eq 'Enabled') {
    Write-Warning (
      "[WARNING] SMBv1 is enabled`n" +
      "State=$state.`n" +
      "Recommended configuration: Remove the Windows optional feature 'SMB1Protocol' after confirming that no " +
      'legacy client or application requires it.'
    )
  } else {
    Write-Warning "[WARNING] SMBv1 feature state is inconclusive`nState=$state."
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-Smb1Disabled
}
