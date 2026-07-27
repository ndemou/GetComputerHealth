# HostRequirement: DomainJoinedNotDC

function HealthTest-GpupdatePolicyApply {
<#
Description: Actively applies Group Policy with gpupdate and reports whether computer and user policy processing succeeds.
AppliesTo: DomainJoined
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: Test-ComputerSecureChannel, gpupdate.exe.

This state-changing test actively refreshes Group Policy. The refresh can run policy scripts, recreate Immediate Tasks, apply settings, or start configured deployments. It is loaded only when -IReallyWantToRunTestsThatChangeState is used.
#>
  [CmdletBinding()] param()

  if (!(Test-ComputerSecureChannel)) {
      Write-Warning "[WARNING] Can't connected to any Domain Controller. Can not run gpupdate.`nMake sure you are on the domain LAN or connected via VPN."
    return
  }

  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $isSystem = $false
  try {
    if ($id -and $id.User -and $id.User.Value -eq 'S-1-5-18') { $isSystem = $true }
  } catch {}

  $out  = gpupdate 2>&1
  $text = ($out | sls -notmatch '^ *$' | Out-String)

  $compOk = ($text -like "*Computer Policy update has completed successfully*")
  $userOk = ($text -like "*User Policy update has completed successfully*")

  if ($compOk -and $userOk) {
    Write-Warning "[PASS] Computer and user policy updates completed successfully (gpupdate)."; return
  }

  if ($compOk) {
    Write-Warning "[PASS] Computer policy update completed successfully (gpupdate)."
  } else {
    Write-Warning "[FAILURE] Computer policy update did not report success.`ngpupdate output:`n$text"
  }

  if (-not $userOk) {
    if ($isSystem) {
      Write-Warning "[NOTICE] User policy update did not report success (gpupdate running under SYSTEM/non-interactive).`nThis can be expected when no interactive user is logged on.`nRaw gpupdate output:`n$text"
    } else {
      Write-Warning "[FAILURE] User policy update did not report success.`nExpected success for interactive user.`nRaw gpupdate output:`n$text"
    }
  } else {
    Write-Warning "[PASS] User policy update completed successfully (gpupdate)."
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-GpupdatePolicyApply
}
