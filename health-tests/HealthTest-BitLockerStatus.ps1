<#
Standalone file for HealthTest-BitLockerStatus.
Generated during the repo-wide health-test split.
#>
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

    $pass = $true

    $vols = Get-BitLockerVolume -ErrorAction SilentlyContinue
    if (-not $vols) {
        Write-Warning "[WARNING] No BitLocker-capable volumes found"}
    $vols | Where-Object { $_.ProtectionStatus -ne 'On' } | %{
        Write-Warning "[WARNING] Volume not protected by BitLocker: $($_.MountPoint)"
        $pass = $false
    }
    if ($pass) {
        Write-Warning "[PASS] BitLocker protection is ON for all detected volumes"}
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-BitLockerStatus
}
