# HostRequirement: DnsServer

function HealthTest-DnsZoneTransfers{
<#
Description: Checks whether DNS zone transfers are disabled or restricted as expected.
AppliesTo: Server
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Network)
Uses: Get-DnsServerZone.
#>
  $zones=Get-DnsServerZone | Where-Object { -not $_.IsAutoCreated }
  $bad=$false
  foreach($z in $zones){
    if($z.SecureSecondaries -eq 'Any'){ $bad=$true; Write-Warning "[FAILURE] DNS zone transfer open to Any: $($z.ZoneName)" }
  }
  if(-not $bad){ Write-Warning "[PASS] DNS zone transfers are restricted (not 'Any')" }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-DnsZoneTransfers
}
