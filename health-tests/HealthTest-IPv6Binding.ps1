<#
Standalone file for HealthTest-IPv6Binding.
Generated during the repo-wide health-test split.
#>
# HostRequirement: All

function HealthTest-IPv6Binding{
<#
Description: Checks whether IPv6 is bound on network adapters as expected.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Tags: Essential
Uses: Get-NetAdapterBinding.
#>
  [CmdletBinding()] param([switch]$RequireEnabled)

  $rows = Get-NetAdapterBinding -ComponentID ms_tcpip6 | Select-Object Name,Enabled
  if(-not $rows){ Write-Warning "[FAILURE] No adapters returned for IPv6 binding (ms_tcpip6)"; return }
  $bad=$false
  if($RequireEnabled){
    foreach($r in $rows){
      if(-not $r.Enabled){ $bad=$true; Write-Warning "[FAILURE] IPv6 disabled on adapter`n$($r.Name)" }
    }
    if(-not $bad){ Write-Warning "[PASS] IPv6 enabled on all adapters" }
  } else {
    Write-Warning ("[PASS] IPv6 binding state reported`n" + (($rows | ForEach-Object { "$($_.Name)=$($_.Enabled)" }) -join '; '))
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-IPv6Binding
}
