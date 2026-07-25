# HostRequirement: DC

function HealthTest-DfsrBacklog {
<#
Description: Checks DFS Replication backlog and warns when queued updates are high.
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-DfsrBacklog, Get-DfsrConnection.
#>
    param([string]$RGName='Domain System Volume')
    if (-not(Get-Service DFSR -ErrorAction SilentlyContinue)) {
        Write-Output "No DFSR service; skipping HealthTest-DfsrBacklog."
        return
    }
    if (-not (Get-Command Get-DfsrBacklog -ErrorAction SilentlyContinue)) {
        Write-Warning "[WARNING] DFSR cmdlets not available. Can't start the DFSR backlog healthcheck." `
            -comment 'I suggest you install RSAT-DFS-Mgmt-Con:`n        Install-WindowsFeature RSAT-DFS-Mgmt-Con'
        return
    }
    $conn = Get-DfsrConnection -GroupName $RGName -ErrorAction SilentlyContinue
    if (-not $conn) { Write-Warning "[info] No DFS-R connections found for '$RGName'"; return }
    $over = @()
    foreach ($c in $conn) {
      $b = Get-DfsrBacklog -GroupName $RGName -SourceComputerName $c.SourceComputerName -DestinationComputerName $c.DestinationComputerName -ErrorAction SilentlyContinue
      if ($b -and $b.Count -gt 1000) { $over += "$($c.SourceComputerName)->$($c.DestinationComputerName): $($b.Count)" }
    }
    if ($over.Count -gt 0) { Write-Warning "[WARNING] DFS-R backlog high`n$($over -join ' | ')"; return }
    Write-Warning "[PASS] DFS-R backlog OK"; return
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-DfsrBacklog
}
