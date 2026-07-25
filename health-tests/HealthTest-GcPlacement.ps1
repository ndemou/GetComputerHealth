# HostRequirement: DC

function HealthTest-GcPlacement{
<#
Description: Checks whether each AD site has a Global Catalog and the domain has at least one GC.
AppliesTo: DC
Scope: Forest
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: Get-ADDomainController.
#>
  [CmdletBinding()] param([switch]$AtLeastOnePerSite=$true)
  $dcs=Get-ADDomainController -Filter *
  if(-not $AtLeastOnePerSite){
    $has=@($dcs | Where-Object {$_.IsGlobalCatalog}).Count -gt 0
    if($has){ Write-Warning "[PASS] At least one Global Catalog exists in the domain" } else { Write-Warning "[FAILURE] No Global Catalog server detected in the domain" }
    return
  }
  $sites=$dcs | Group-Object Site
  $bad=@()
  foreach($s in $sites){
    if(@($s.Group | Where-Object {$_.IsGlobalCatalog}).Count -eq 0){ $bad+=$s.Name; Write-Warning "[FAILURE] No Global Catalog in site '$($s.Name)'" }
  }
  if($bad.Count -eq 0){ Write-Warning "[PASS] Each AD site has at least one Global Catalog" }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-GcPlacement
}
