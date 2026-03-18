<#
Tests that are only applicable to Windows Server O.S.
#>

# Functions in this file are only going to be defined if
# this computer runs Windows Server O.S.
if ((Get-CimInstance Win32_ComputerSystem).DomainRole  -in 3,4,5) {

function HealthTest-DhcpInAd{
<#
.SYNOPSIS
Checks Dhcp In Ad

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-WindowsFeature, Get-DhcpServerInDC.
FalsePositives: None.
#>
  $dhcp=Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
  if(-not $dhcp -or -not $dhcp.Installed){ Write-Warning "[pass] DHCP role not installed on this server"; return }
  $auth=Get-DhcpServerInDC -ErrorAction SilentlyContinue
  $fqdn=[System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName
  $isAuth=($auth | Where-Object { $_.DnsName -ieq $fqdn })
  if($isAuth){ Write-Warning "[pass] DHCP server is authorized in AD ($fqdn)" } else { Write-Warning "[failure] DHCP server is NOT authorized in AD ($fqdn)" }
}

function HealthTest-DhcpScopeUtilization {
<#
.SYNOPSIS
Checks Dhcp Scope Utilization

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-DhcpServerv4ScopeStatistics.
FalsePositives: None.
#>
    $svc = Get-Service -Name 'DHCPServer' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Output "Host is not a DHCP server (DHCPServer service missing); skipping DHCP scope utilization test"
        return
    }

    if (-not (Get-Command Get-DhcpServerv4ScopeStatistics -ErrorAction SilentlyContinue)) {
        Write-Warning "[warning] DHCP server cmdlets not available on this DHCP server; skipping DHCP scope utilization test"; return
    }

    $stats = Get-DhcpServerv4ScopeStatistics -ErrorAction SilentlyContinue
    if (-not $stats) {
        Write-Warning "[warning] DHCP server role present but no DHCPv4 scopes found"; return
    }

    $over = @()
    foreach ($s in $stats) {
        if ($s.PercentageInUse -ge 90) {
            $over += $s.ScopeId
            Write-Warning "[failure] DHCP scope is >=90% used: $($s.ScopeId)"
        } elseif ($s.PercentageInUse -ge 80) {
            $over += $s.ScopeId
            Write-Warning "[warning] DHCP scope is >=80% used: $($s.ScopeId)"
        }
    }

    if ($over.Count -gt 0) {
        Write-Warning "[pass] DHCP scope utilization OK (<80% in use)"}

}

function HealthTest-InstalledRolesFeatures {
<#
.SYNOPSIS
Checks Installed Roles Features

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Audit / Compliance / Informational
Impact: Medium(Time)
Uses: Get-WindowsFeature.
FalsePositives: None.
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
    foreach ($h in $hit) { Write-Warning "[failure] Unintended role/feature installed: $($h.Name)" }
  } else {
    Write-Warning "[pass] No unintended roles/features installed"
  }
}

} # is this computer running Windows Server