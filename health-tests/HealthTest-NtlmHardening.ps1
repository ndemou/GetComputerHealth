# HostRequirement: All

if (-not (Get-Command -Name 'Test-IsDomainJoinedComputer' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helpers-for-healthtests.ps1')
}

function HealthTest-NtlmHardening {
<#
Description: Checks whether NTLM hardening registry settings meet the security baseline.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Tags: Essential
Uses: None.
#>
  $lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'

  $bag   = Get-ItemProperty -Path $lsa -ErrorAction SilentlyContinue
  $lmVal = if ($bag -and $bag.PSObject.Properties['LmCompatibilityLevel']) { $bag.PSObject.Properties['LmCompatibilityLevel'].Value } else { $null }
  $noLM  = if ($bag -and $bag.PSObject.Properties['NoLMHash'])           { $bag.PSObject.Properties['NoLMHash'].Value }           else { $null }

  $interpreted = $true
  if ($null -ne $lmVal) { $level = [int]$lmVal; $interpreted = $false } else { $level = 3 }
  $suffix  = if ($interpreted) { ' (default)' } else { '' }
  $details = "LmCompatibilityLevel=$level$suffix; NoLMHash=$noLM"
  $isDomainJoined = Test-IsDomainJoinedComputer

  if ($noLM -ne 1) {
    if ($isDomainJoined) {
      $configurationReference = (
        'Related domain policy path: Computer Configuration\Policies\Windows Settings\Security Settings\' +
        'Local Policies\Security Options\Network security: Do not store LAN Manager hash value on next password change.'
      )
    } else {
      $configurationReference = "Related registry path: '$lsa\NoLMHash'."
    }

    Write-Warning (
      "[WARNING] NTLM is not fully hardened (NoLMHash is not 1)`n" +
      "$details`n$configurationReference"
    )
  } elseif ($level -lt 5) {
    if ($isDomainJoined) {
      $configurationReference = (
        'Related domain policy path: Computer Configuration\Policies\Windows Settings\Security Settings\' +
        'Local Policies\Security Options\Network security: LAN Manager authentication level.'
      )
    } else {
      $configurationReference = "Related registry path: '$lsa\LmCompatibilityLevel'."
    }

    Write-Warning (
      "[WARNING] NTLM hardening: LAN Manager authentication level is below 5`n" +
      "$details`n$configurationReference"
    )
  } else {
    Write-Warning "[PASS] NTLM is fully hardened`n$details"
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-NtlmHardening
}
