<#
Standalone file for HealthTest-DnsForwarders.
Generated during the repo-wide health-test split.
#>
# HostRequirement: DnsServer

function HealthTest-DnsForwarders{
<#
Description: Checks whether DNS forwarders are configured, private, and reachable.
AppliesTo: Server
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Network)
Uses: Get-DnsServerForwarder, Test-Connection.
#>
  function Test-IsPrivateDnsForwarderIp([string]$IpAddress) {
    if ($IpAddress -like '10.*') { return $true }
    if ($IpAddress -like '192.168.*') { return $true }
    if ($IpAddress -like '172.1[6-9].*') { return $true }
    if ($IpAddress -like '172.2[0-9].*') { return $true }
    if ($IpAddress -like '172.3[0-1].*') { return $true }
    return $false
  }

  $f=Get-DnsServerForwarder -ErrorAction Stop
  if(-not $f -or -not $f.IPAddress){ Write-Warning "[PASS] No DNS forwarders configured"; return }

  $ips = @()
  foreach ($ip in @($f.IPAddress)) {
    if ($null -ne $ip) {
      $ips += $ip.ToString()
    }
  }

  $bad=$false
  $hasPublicForwarder = $false
  foreach($ip in $ips){
    if(($ip -eq '127.0.0.1') -or ($ip -eq '::1')){ $bad=$true; Write-Warning "[FAILURE] Loopback address is configured as a DNS forwarder`n$ip"; continue }
    if (-not (Test-IsPrivateDnsForwarderIp -IpAddress $ip)) {
      $hasPublicForwarder = $true
    }
    $ok=(Test-Connection -ComputerName $ip -Count 1 -Quiet)
    if(-not $ok){ $bad=$true; Write-Warning "[FAILURE] DNS forwarder not reachable`n$ip" }
  }

  if ($hasPublicForwarder) {
    Write-Warning "[NOTICE] DNS forwarders include public/non-private addresses`nForwarders: $($ips -join ', ')`nThese DNS servers can inspect and log queried domains. For extra privacy, consider root hints or documented internal resolvers."
  } else {
    Write-Warning "[PASS] All DNS forwarders are private/internal: $($ips -join ', ')"
  }

  if(-not $bad){ Write-Warning ("[PASS] DNS forwarders are reachable`nForwarders: " + ($ips -join ', ')) }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-DnsForwarders
}
