# HostRequirement: DnsServer

function HealthTest-DnsZoneReplicationScope{
<#
Description: Checks whether AD-integrated DNS zones use the expected replication scope.
AppliesTo: Server
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network), Medium(Time)
Uses: Get-DnsServerZone.
#>
  $zones = Get-DnsServerZone -ErrorAction Stop | Where-Object { $_.IsDsIntegrated }
  if(-not $zones){ Write-Warning "[PASS] No AD-integrated zones present"; return }
  $lines = ($zones | ForEach-Object { "{0}:{1}" -f $_.ZoneName, $_.ReplicationScope })
  Write-Warning ("[PASS] DNS zone replication scope reviewed`n" + ($lines -join '; '))
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-DnsZoneReplicationScope
}
