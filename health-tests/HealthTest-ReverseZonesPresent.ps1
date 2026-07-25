# HostRequirement: DnsServer

function HealthTest-ReverseZonesPresent{
<#
Description: Checks whether required reverse lookup zones exist.
AppliesTo: Server
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: Get-DnsServerZone.
#>
  [CmdletBinding()] param([string[]]$ExpectedReverseZones)
  $zones=Get-DnsServerZone | Where-Object {$_.IsReverseLookupZone} | Select-Object -ExpandProperty ZoneName
  if(-not $ExpectedReverseZones){ Write-Warning ("[PASS] Reverse zones present: " + (($zones -join ', ') -replace '^$','<none>')); return }
  $missing=@()
  foreach($z in $ExpectedReverseZones){
    if($zones -notcontains $z){ $missing+=$z; Write-Warning "[FAILURE] Reverse zone missing: $z" }
  }
  if($missing.Count -eq 0){ Write-Warning "[PASS] All expected reverse zones are present" }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-ReverseZonesPresent
}
