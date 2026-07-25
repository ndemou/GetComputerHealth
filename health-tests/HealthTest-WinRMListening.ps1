# HostRequirement: All

function HealthTest-WinRMListening{
<#
Description: Checks whether the WinRM service is running and responds to WSMan requests.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Network)
Tags: Essential
Uses: Test-WSMan.
#>
  $svc=Get-Service WinRM -ErrorAction Stop
  if($svc.Status -ne 'Running'){ Write-Warning "[FAILURE] WinRM service is not running`nStatus=$($svc.Status)"; return }
  try{ $null=Test-WSMan -ErrorAction Stop; Write-Warning "[PASS] WinRM running and responding"}
  catch{ Write-Warning "[FAILURE] WinRM not responding`n$($_.Exception.Message)" }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-WinRMListening
}
