# HostRequirement: DC

function HealthTest-DfsNamespaceEnumerate{
<#
Description: Checks whether DFS namespace roots and folders can be enumerated successfully.
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: Get-DfsnRoot, Get-DfsnFolder.
#>
  $roots=Get-DfsnRoot -ErrorAction SilentlyContinue
  if(-not $roots){ Write-Warning "[PASS] No DFS Namespace roots found (nothing to check)"; return }
  $count=0
  foreach($r in $roots){ $count += (Get-DfsnFolder -Path $r.Path -ErrorAction SilentlyContinue | Measure-Object).Count }
  Write-Warning "[PASS] DFSN roots/folders enumerate: Roots=$($roots.Count); Folders=$count"
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-DfsNamespaceEnumerate
}
