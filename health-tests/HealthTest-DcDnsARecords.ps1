<#
Standalone file for HealthTest-DcDnsARecords.
Generated during the repo-wide health-test split.
#>
# HostRequirement: DnsServer

function HealthTest-DcDnsARecords{
<#
Description: Checks whether domain controller hostnames resolve to expected A records.
AppliesTo: Server
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Get-ADDomainController, Resolve-DnsName.
#>
  $bad=@()
  foreach($dc in (Get-ADDomainController -Filter *)){
    $hn=$dc.HostName; $ip=$dc.IPv4Address
    if(-not $hn -or -not $ip){ continue }
    $ares=(Resolve-DnsName -Name $hn -Type A -ErrorAction SilentlyContinue).IPAddress
    if(-not $ares){ $msg="$hn has no A records in DNS"; $bad+=$msg; Write-Warning "[FAILURE] $msg"; continue }
    if($ares -notcontains $ip){ $msg="$hn A record mismatch: AD IP=$ip, DNS IPs="+($ares -join ','); $bad+=$msg; Write-Warning "[FAILURE] $msg" }
  }
  if($bad.Count -eq 0){ Write-Warning "[PASS] DC DNS A records match AD IPs for all DCs" }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-DcDnsARecords
}
