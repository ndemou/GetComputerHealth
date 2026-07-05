<#
Standalone file for HealthTest-PendingReboot.
Generated during the repo-wide health-test split.
#>
# HostRequirement: All

function HealthTest-PendingReboot {
<#
Description: Checks for Windows pending-reboot indicators.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Tags: Essential
Uses: None.
#>
    $pending = $false
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending = $true }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending = $true }
    $pfr = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
    if ($pfr -and $pfr.PendingFileRenameOperations) {write-debug "Found entries in HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations (if you are not sure what this means, you can safely ignore it)"}
    if ($pending) { Write-Warning "[NOTICE] Windows need a reboot to apply some changes"; return}
    Write-Warning "[PASS] No pending reboot indicators"
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-PendingReboot
}
