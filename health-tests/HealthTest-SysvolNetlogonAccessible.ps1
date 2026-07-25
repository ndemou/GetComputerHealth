# HostRequirement: DC

if (-not (Get-Command -Name 'Get-DomainControllers' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helper-regarding-domain-controllers.ps1')
}

function HealthTest-SysvolNetlogonAccessible{
<#
Description: Checks whether each domain controller exposes reachable SYSVOL and NETLOGON shares.
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Get-DomainControllers.
#>
    $dcs = Get-DomainControllers
    $bad = @()
    foreach($dc in $dcs){
      $ok1 = Test-Path "\\$dc\SYSVOL"
      if (!$ok1) {Write-Warning "[FAILURE] '\\$dc\SYSVOL' not reachable"}
      $ok2 = Test-Path "\\$dc\NETLOGON"
      if (!$ok2) {Write-Warning "[FAILURE] '\\$dc\NETLOGON' not reachable"}
      if(-not($ok1 -and $ok2)){ $bad += $dc.HostName }
    }
    $pass = ($bad.Count -eq 0)
    if($pass){Write-Warning "[PASS] All DCs have reachable SYSVOL & NETLOGON"}
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-SysvolNetlogonAccessible
}
