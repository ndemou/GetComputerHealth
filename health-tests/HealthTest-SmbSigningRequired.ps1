# HostRequirement: All

if (-not (Get-Command -Name 'Get-PropValue' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helpers-for-healthtests.ps1')
}

function HealthTest-SmbSigningRequired{
<#
Description: Checks whether the SMB server requires signing when the server service is running.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Tags: Essential
Uses: Get-SmbServerConfiguration.
#>
  if ((Get-PropValue -obj (Get-Service -Name LanmanServer) -name Status) -ne 'running') {
      Write-Warning "[PASS] Skipping HealthTest-SmbSigningRequired; LanmanServer service not running."
      return
  }

  $c=Get-SmbServerConfiguration
  if($c.RequireSecuritySignature){
    Write-Warning "[PASS] SMB signing required on the server"
  } else {
    Write-Warning "[WARNING] SMB signing is not required`nRequireSecuritySignature=$($c.RequireSecuritySignature); EnableSecuritySignature=$($c.EnableSecuritySignature)"
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-SmbSigningRequired
}
