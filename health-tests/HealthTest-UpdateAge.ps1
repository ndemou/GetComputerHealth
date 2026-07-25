# HostRequirement: All

function HealthTest-UpdateAge {
<#
Description: Checks how long it has been since the latest installed Windows update.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Tags: Essential
Uses: Get-HotFix.
#>
    param([int]$WarnDays=30,[int]$FailDays=45)
    $lastUpdateDate = $null

    try {
      $batchSize = 100
      $start = 0
      $maxScanEntries = 10000
      $scanned = 0
      $session = New-Object -ComObject Microsoft.Update.Session
      $searcher = $session.CreateUpdateSearcher()

      while ($scanned -lt $maxScanEntries -and -not $lastUpdateDate) {
        $remaining = $maxScanEntries - $scanned
        $take = if ($remaining -lt $batchSize) { $remaining } else { $batchSize }
        $batch = $searcher.QueryHistory($start, $take)
        if (-not $batch -or $batch.Count -eq 0) { break }

        $scanned += $batch.Count
        $start += $batch.Count

        foreach ($entry in $batch) {
          if ($entry.Operation -eq 1 -and $entry.ResultCode -in 2,3) {
            $lastUpdateDate = $entry.Date
            break
          }
        }

        if ($batch.Count -lt $take) { break }
      }
    } catch { }

    if (-not $lastUpdateDate) {
      $reg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Install' -ErrorAction SilentlyContinue
      if ($reg -and $reg.LastSuccessTime) { $lastUpdateDate = [datetime]::Parse($reg.LastSuccessTime) }
    }

    if (-not $lastUpdateDate) {
      $hf = Get-HotFix -ErrorAction SilentlyContinue | ?{$_.InstalledOn} | Sort-Object InstalledOn -Descending | Select-Object -First 1
      if ($hf -and $hf.InstalledOn) { $lastUpdateDate = $hf.InstalledOn }
    }
    if (-not $lastUpdateDate) { Write-Warning "[WARNING] Could not determine last successful Windows Update installation (normal only for a fresh windows installation)"; return}
    $lastUpdateDateText = ([datetime]$lastUpdateDate).ToString('yyyy-MM-dd')
    $age = (Get-Date) - $lastUpdateDate
    if ($age.Days -ge $FailDays) { Write-Warning "[FAILURE] Too many days since the last successful Windows Update installation`n$($age.Days)d ago ($lastUpdateDateText)"; return }
    if ($age.Days -ge $WarnDays) { Write-Warning "[WARNING] Several days since the last successful Windows Update installation`n$($age.Days)d ago ($lastUpdateDateText)"; return }
    Write-Warning "[PASS] We have a recent successful installation of a Windows Update ($($age.Days)d ago at $lastUpdateDateText)"
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-UpdateAge
}
