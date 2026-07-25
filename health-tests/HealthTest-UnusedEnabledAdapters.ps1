# HostRequirement: DC

function HealthTest-UnusedEnabledAdapters{
<#
Description: Checks for enabled network adapters that are disconnected and likely unused.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: Get-NetAdapter.
#>
  $nics=Get-NetAdapter | Where-Object {$_.AdminStatus -eq 'Up' -and $_.Status -ne 'Up'}
  foreach($n in $nics){ Write-Warning "[WARNING] Enabled network adapter is disconnected: $($n.Name) ($($n.Status))" }
  if(($nics | Measure-Object).Count -eq 0){ Write-Warning "[PASS] No enabled-but-disconnected network adapters detected" } else { Write-Warning "[FAILURE] There are enabled-but-disconnected network adapters present" }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-UnusedEnabledAdapters
}
