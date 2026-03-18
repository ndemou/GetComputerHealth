<#
OS Performance & Hardware
#>

# This function(s) will only be defined if the Computer
# is a laptop/Mobile device
if ($Global:GetComputerHealthDataQMTA.isHostMobile){

function HealthTest-IsTPMActivated {
<#
.SYNOPSIS
Checks Is TPM Activated

.DESCRIPTION
AppliesTo: Mobile
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Write-BasedOnTestResult, Get-Tpm.
FalsePositives: None.
#>
  Write-BasedOnTestResult "Is TPM Activated?" -Test (Get-Tpm).TpmActivated
}

}
