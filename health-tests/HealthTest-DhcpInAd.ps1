<#
Standalone file for HealthTest-DhcpInAd.
Generated during the repo-wide health-test split.
#>
# HostRequirement: Server

function HealthTest-DhcpInAd{
<#
Description: Checks whether a local DHCP server is authorized in Active Directory.
AppliesTo: Server
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: low
Tags: Essential
Uses: Get-WindowsFeature, Get-DhcpServerInDC.
#>
  $dhcp=Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
  if(-not $dhcp -or -not $dhcp.Installed){ Write-Warning "[PASS] DHCP role not installed on this server"; return }
  $auth=Get-DhcpServerInDC -ErrorAction SilentlyContinue
  $fqdn=[System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName
  $isAuth=($auth | Where-Object { $_.DnsName -ieq $fqdn })
  if($isAuth){ Write-Warning "[PASS] DHCP server is authorized in AD ($fqdn)" } else { Write-Warning "[FAILURE] DHCP server is NOT authorized in AD ($fqdn)" }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-DhcpInAd
}
