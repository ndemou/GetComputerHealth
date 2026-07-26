# HostRequirement: All

if (
  -not (Get-Command -Name 'Get-PropValue' -CommandType Function -ErrorAction SilentlyContinue) -or
  -not (Get-Command -Name 'Test-IsDomainJoinedComputer' -CommandType Function -ErrorAction SilentlyContinue)
) {
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
    if (Test-IsDomainJoinedComputer) {
      $configurationReference = (
        'Related domain policy path: Computer Configuration\Policies\Windows Settings\Security Settings\Local Policies\' +
        'Security Options\Microsoft network server: Digitally sign communications (always).'
      )
    } else {
      $configurationReference = (
        'Recommended local command: Set-SmbServerConfiguration -RequireSecuritySignature $true'
      )
    }

    Write-Warning (
      "[WARNING] SMB hardening: server signing is not required`n" +
      "RequireSecuritySignature=$($c.RequireSecuritySignature); " +
      "EnableSecuritySignature=$($c.EnableSecuritySignature).`n" +
      "Requiring SMB signing protects traffic integrity and helps prevent session tampering.`n" +
      $configurationReference
    )
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-SmbSigningRequired
}
