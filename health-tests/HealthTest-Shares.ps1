<#
Standalone file for HealthTest-Shares.
Generated during the repo-wide health-test split.
#>
# HostRequirement: All

function HealthTest-Shares {
<#
Description: Checks SMB sharing service hygiene when no shares are present.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Tags: Essential
Uses: Get-Service, Win32_ComputerSystem, Win32_Share.
#>
  # 0(Workstation standalone),  1(Workstation domain joined), 2(Server standalone), 3(Server joined), 4(DC non-FSMO), 5(DC with FSMO role)
  $domainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole
  $isHostDC = ($domainRole -in 4,5)
  $shares = @(Get-CimInstance -ClassName Win32_Share | Select-Object Name, Path)
  $lanManServerService = Get-Service -Name "LanmanServer"

  if ($shares.Count -gt 0) {
    Write-Warning "[PASS] SMB shares exist; file and print sharing service state is expected."
    return
  }

  if ($lanManServerService.Status -eq 'Stopped') {
    Write-Warning "[PASS] Found no shares and LanmanServer service is stopped."
    return
  }

  if (-not $isHostDC -and ($lanManServerService.Status -ne 'Stopped' -or $lanManServerService.StartType -ne 'Disabled')) {
    if ($domainRole -ge 2) {
      Write-Warning "[WARNING] File and print sharing is enabled but no SMB shares were discovered.`nRun this if you want to disable it:`n   Set-Service -Name 'LanmanServer' -StartupType Disabled; Stop-Service -Name 'LanmanServer'"
    } else {
      Write-Warning "[NOTICE] File and print sharing is enabled on a workstation but no SMB shares were discovered.`nConsider disabling LanmanServer to reduce attack surface if sharing is not needed."
    }
    return
  }

  Write-Warning "[PASS] No SMB share hygiene issues found."
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-Shares
}
