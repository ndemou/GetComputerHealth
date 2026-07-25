# HostRequirement: All

function HealthTest-DnsClientService{
<#
Description: Checks whether the DNS Client service is running.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: High(Network)
Tags: Essential
Uses: None.
#>
  $s=Get-Service Dnscache -ErrorAction Stop
  if($s.Status -eq 'Running'){ Write-Warning "[PASS] DNS Client service running" } else { Write-Warning "[FAILURE] DNS Client service is not running`nStatus=$($s.Status)" }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-DnsClientService
}
