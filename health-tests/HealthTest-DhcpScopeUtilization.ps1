# HostRequirement: Server

function HealthTest-DhcpScopeUtilization {
<#
Description: Checks DHCPv4 scopes for high address utilization.
AppliesTo: Server
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Tags: Essential
Uses: Get-DhcpServerv4ScopeStatistics.
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

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-DhcpScopeUtilization
}
