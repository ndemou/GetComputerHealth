<#
Standalone file for HealthTest-DnsScavenging.
Generated during the repo-wide health-test split.
#>
# HostRequirement: DnsServer

function HealthTest-DnsScavenging{
<#
Description: Checks whether DNS scavenging and zone aging are enabled and configured sensibly.
AppliesTo: Server
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Get-DnsServerScavenging, Get-DnsServerZone, Get-DnsServerZoneAging.
#>
  $sv = Get-DnsServerScavenging -ErrorAction Stop
  $zones = Get-DnsServerZone -ErrorAction Stop | Where-Object { $_.IsDsIntegrated -and $_.ZoneType -eq 'Primary' }
  $comment = "Severity: Medium.`nWhat it means: Server-level scavenging is off, so stale dynamic records never age out.`nRisk: Stale A/PTR clutter, service discovery problems, and opportunities for name re-use confusion. In secure-updates AD zones, outright hijack is harder, but operational pain is real."

  $flagged=$false
  if(-not $sv.ScavengingState){ $flagged=$true; Write-Warning "[WARNING] DNS server scavenging is disabled`n$comment" }

  foreach($z in $zones){
    $ai = $null; try { $ai = Get-DnsServerZoneAging -Name $z.ZoneName -ErrorAction Stop } catch {}
    if(-not ($ai -and $ai.AgingEnabled)){ 
        $flagged=$true
        $details = "zone: $($z.ZoneName) `nNote that scavenging must be enabled both at the server level and at the zone`n$comment"
        Write-Warning ("[WARNING] DNS zone aging is disabled" + "`n" + $details)
    }
  }

  if(-not $flagged){
    $on=@($zones | ForEach-Object { $_.ZoneName })
    Write-Warning ("[PASS] DNS scavenging configured on server and zones`nZones: " + ($on -join ', '))
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-DnsScavenging
}
