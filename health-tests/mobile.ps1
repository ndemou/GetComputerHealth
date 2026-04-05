<#
Only for laptop/Mobile device
#>

function HealthTest-IsTPMActivated {
<#
.SYNOPSIS
Checks Is TPM Activated.

.DESCRIPTION
AppliesTo: Mobile
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-Tpm.
#>
  if ($RunWithoutElevation) {
    Write-Warning "[WARNING] this test requires elevation"
    return
  }

  Write-BasedOnTestResult "Is TPM Activated?" -Test (Get-Tpm).TpmActivated
}
