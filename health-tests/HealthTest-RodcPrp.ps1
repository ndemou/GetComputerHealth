<#
Standalone file for HealthTest-RodcPrp.
Generated during the repo-wide health-test split.
#>
# HostRequirement: DC

function HealthTest-RodcPrp{
<#
Description: Checks whether each read-only domain controller has a Password Replication Policy configured.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: Get-ADDomainController, Get-ADObject.
#>
  $rodcs=Get-ADDomainController -Filter {IsReadOnly -eq $true}
  if(-not $rodcs){ Write-Warning "[PASS] No RODCs found (PRP not applicable)"; return }
  $bad=$false
  foreach($r in $rodcs){
    $ro=Get-ADObject $r.NTDSSettingsObjectDN -Properties msDS-RevealOnDemandGroup,msDS-NeverRevealGroup
    if(-not $ro.'msDS-RevealOnDemandGroup' -and -not $ro.'msDS-NeverRevealGroup'){ $bad=$true; Write-Warning "[FAILURE] RODC PRP not configured on $($r.HostName)" }
  }
  if(-not $bad){ Write-Warning "[PASS] PRP is configured on all RODCs" }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-RodcPrp
}
