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

  try {
    $bag = Get-ItemProperty -Path $lsa -ErrorAction Stop
    if ($null -eq $bag) { throw 'The registry query returned no settings.' }
  } catch {
    Write-Warning "[WARNING] Could not read NTLM hardening registry settings`nRegistry path: '$lsa'.`nError: $($_.Exception.Message)"
    return
  }

  $lmVal = if ($bag.PSObject.Properties['LmCompatibilityLevel']) { $bag.PSObject.Properties['LmCompatibilityLevel'].Value } else { $null }
  $noLMProperty = $bag.PSObject.Properties['NoLMHash']
  $noLM = if ($noLMProperty) { $noLMProperty.Value } else { $null }

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

    $finding = '[WARNING] NTLM is not fully hardened (NoLMHash is not 1)'
    # Starting with Windows Vista, the default prevents storing new LM hashes.
    if ($null -eq $noLMProperty -and [Environment]::OSVersion.Version.Major -ge 6) {
      $finding = '[NOTICE] NTLM hardening: NoLMHash is not explicitly configured'
      $details += "`nWindows defaults to not storing LM hashes on the next password change."
    }
    Write-Warning "$finding`n$details`n$configurationReference"
  } elseif ($level -lt 5) {
    if ($isDomainJoined) {
      $configurationReference = (
        'Related domain policy path: Computer Configuration\Policies\Windows Settings\Security Settings\' +
        'Local Policies\Security Options\Network security: LAN Manager authentication level.'
      )
    } else {
      $configurationReference = "Related registry path: '$lsa\LmCompatibilityLevel'."
    }

    Write-Warning "[NOTICE] NTLM hardening: LAN Manager authentication level is below 5`n$details`n$configurationReference"
  } else {
    Write-Warning "[PASS] NTLM is fully hardened`n$details"
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-NtlmHardening
}
