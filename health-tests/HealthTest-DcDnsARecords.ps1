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
  $bad=$false
  foreach($dc in (Get-ADDomainController -Filter *)){
    $hn=$dc.HostName; $ip=$dc.IPv4Address
    if(-not $hn -or -not $ip){ continue }
    $ares=(Resolve-DnsName -Name $hn -Type A -ErrorAction SilentlyContinue).IPAddress
    if(-not $ares){
      $bad = $true
      Write-Warning "[FAILURE] $hn has no A records in DNS"
      continue
    }
    if($ares -notcontains $ip){
      $bad = $true
      $dnsIps = ($ares | Sort-Object) -join ','
      Write-Warning "[FAILURE] $hn A record mismatch: AD IP=$ip, DNS IPs=$dnsIps"
    }
  }
  if(-not $bad){ Write-Warning "[PASS] DC DNS A records match AD IPs for all DCs" }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-DcDnsARecords
}
