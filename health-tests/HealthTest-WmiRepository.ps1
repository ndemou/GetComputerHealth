# HostRequirement: All

function HealthTest-WmiRepository{
<#
Description: Checks whether the WMI repository is consistent.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Tags: Essential
Uses: winmgmt.exe.
#>
  try {
    # Windows PowerShell turns redirected native stderr into error records.
    $ErrorActionPreference = 'Continue'
    $output = & winmgmt.exe /verifyrepository 2>&1
    $status = $LASTEXITCODE
  } catch {
    Write-Warning "[WARNING] Could not start WMI repository verification`n$($_.Exception.Message)"
    return
  }

  if ($status -eq 0) {
    Write-Warning '[PASS] WMI repository consistent'
    return
  }

  $details = "Exit code: $status`n$($output -join "`n")"
  # Some versions collapse both corruption and access errors to exit code 1.
  # Only ERROR_INTERNAL_DB_CORRUPTION and its HRESULT form identify corruption by status.
  if ($status -in @(1358, 0x8007054E)) {
    Write-Warning "[FAILURE] WMI repository inconsistent`n$details"
  } else {
    Write-Warning "[WARNING] WMI repository verification failed`n$details"
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-WmiRepository
}
