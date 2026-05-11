<#
Tests that are only applicable to Windows Server O.S.
#>

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

function HealthTest-DhcpScopeUtilization {
<#
Description: Checks DHCPv4 scopes for high address utilization.
AppliesTo: Server
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Tags: Essential
Uses: Get-Service, Get-Command, Get-DhcpServerv4ScopeStatistics.
#>
    $svc = Get-Service -Name 'DHCPServer' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Output "Host is not a DHCP server (DHCPServer service missing); skipping DHCP scope utilization test"
        return
    }

    if (-not (Get-Command Get-DhcpServerv4ScopeStatistics -ErrorAction SilentlyContinue)) {
        Write-Warning "[WARNING] DHCP server cmdlets not available on this DHCP server; skipping DHCP scope utilization test"; return
    }

    $stats = Get-DhcpServerv4ScopeStatistics -ErrorAction SilentlyContinue
    if (-not $stats) {
        Write-Warning "[WARNING] DHCP server role present but no DHCPv4 scopes found"; return
    }

    $over = @()
    foreach ($s in $stats) {
        if ($s.PercentageInUse -ge 90) {
            $over += $s.ScopeId
            Write-Warning "[FAILURE] DHCP scope is >=90% used: $($s.ScopeId)"
        } elseif ($s.PercentageInUse -ge 80) {
            $over += $s.ScopeId
            Write-Warning "[WARNING] DHCP scope is >=80% used: $($s.ScopeId)"
        }
    }

    if ($over.Count -gt 0) {
        Write-Warning "[PASS] DHCP scope utilization OK (<80% in use)"}

}

function HealthTest-InstalledRolesFeatures {
<#
Description: Checks for installed Windows roles or features that are outside the intended baseline.
AppliesTo: Server
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: Get-WindowsFeature.
#>
  [CmdletBinding()]
  param([string[]]$DisallowedRoles = @('Web-Server','DHCP','WDS'))

  $roles = $null
  try { $roles = Get-WindowsFeature -ErrorAction Stop | Where-Object { $_.Installed } }
  catch {
    Write-Output "Get-WindowsFeature not available on this OS; skipping role/feature check"
    return
  }

  $hit = @($roles | Where-Object { $DisallowedRoles -contains $_.Name })
  if ($hit.Count -gt 0) {
    foreach ($h in $hit) { Write-Warning "[FAILURE] Unintended role/feature installed: $($h.Name)" }
  } else {
    Write-Warning "[PASS] No unintended roles/features installed"
  }
}
