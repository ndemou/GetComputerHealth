# HostRequirement: All

if (-not (Get-Command -Name 'Test-IsVirtualMachine' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helpers-for-healthtests.ps1')
}


function HealthTest-BitLockerStatus {
<#
Description: Checks whether detected volumes are protected by BitLocker.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Tags: Essential
Uses: Get-BitLockerVolume.
#>
    if (Test-IsVirtualMachine) {
        Write-Warning "[info] Computer is a VM; skipping HealthTest-BitLockerStatus"
        return
    }
    if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        Write-Warning "[WARNING] BitLocker PowerShell cmdlets not available; skipping BitLocker status check"
        return
    }

    try {
        $vols = Get-BitLockerVolume -ErrorAction Stop
    } catch {
        Write-Warning "[WARNING] Could not read BitLocker status`n$($_.Exception.Message)"
        return
    }
    if (-not $vols) {
        Write-Warning "[WARNING] No BitLocker-capable volumes found"
        return
    }

    $unprotectedVolumes = @($vols | Where-Object { $_.ProtectionStatus -ne 'On' })
    foreach ($volume in $unprotectedVolumes) {
        Write-Warning "[WARNING] Volume not protected by BitLocker: $($volume.MountPoint)"
    }
    if ($unprotectedVolumes.Count -eq 0) {
        Write-Warning "[PASS] BitLocker protection is ON for all detected volumes"
    }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-BitLockerStatus
}
