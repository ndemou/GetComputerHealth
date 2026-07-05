<#
Standalone file for HealthTest-HotfixBaseline.
Generated during the repo-wide health-test split.
#>
# HostRequirement: All

function HealthTest-HotfixBaseline{
<#
Description: Checks whether all required hotfixes from the baseline are installed.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Tags: Essential
Uses: Get-HotFix.
#>
  [CmdletBinding()] param([string[]]$RequiredKBs)
  if(-not $RequiredKBs -or $RequiredKBs.Count -eq 0){ Write-Warning "[PASS] No hotfix baseline provided"; return }
  $have=(Get-HotFix | Select-Object -ExpandProperty HotFixID)
  $miss=@()
  foreach($kb in $RequiredKBs){
    if($have -notcontains $kb){ $miss += $kb; Write-Warning "[FAILURE] Missing required hotfix: $kb"}
  }
  if($miss.Count -eq 0){ Write-Warning "[PASS] All required hotfixes are installed"}
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-HotfixBaseline
}
