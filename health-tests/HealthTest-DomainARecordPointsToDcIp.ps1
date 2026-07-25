# HostRequirement: DomainJoined

function HealthTest-DomainARecordPointsToDcIp {
<#
Description: Checks whether the domain A record points to a DC IP.
AppliesTo: DomainJoined
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Tags: Essential
Uses: Resolve-DnsName.
#>
  $dcIps = @($Global:GchData.IpsOfAllDcs)

  $domain = (Get-CimInstance Win32_ComputerSystem).Domain
  $ares = $null
  try { $ares = Resolve-DnsName -Name $domain -Type A -ErrorAction Stop } catch {}
  if (-not $ares) {
    Write-Warning "[FAILURE] No A records found for domain DNS name.`n$domain"
    return
  }

  $aIps = @($ares | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
  $intersection = @()
  foreach ($ip in $aIps) { if ($dcIps -contains $ip) { $intersection += $ip } }

  $comment = "Domain=$domain; DC IPs=" + ($dcIps -join ', ') + "; Domain A IPs=" + ($aIps -join ', ')
  if ($intersection.Count -gt 0) {
    Write-Warning "[PASS] Domain DNS name resolves to at least one DC IP.`n$comment"
  } else {
    Write-Warning "[NOTICE] Domain DNS name does not resolve to any known DC IPv4 address.`n$comment"
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-DomainARecordPointsToDcIp
}
