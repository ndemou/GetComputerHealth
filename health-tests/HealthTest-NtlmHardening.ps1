# HostRequirement: All

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

  if ($noLM -ne 1) {
    Write-Warning "[WARNING] NTLM is not fully hardened (NoLMHash is not 1)`n$details"
  } elseif ($level -lt 5) {
    Write-Warning "[WARNING] NTLM is not fully hardened (LmCompatibilityLevel<5)`n$details"
  } else {
    Write-Warning "[PASS] NTLM is fully hardened`n$details"
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-NtlmHardening
}
