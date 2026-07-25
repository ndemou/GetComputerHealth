# HostRequirement: All

function HealthTest-DefenderStatus {
<#
Description: Checks Microsoft Defender protection posture and signature freshness.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Tags: Essential
Uses: Get-MpComputerStatus.

Checks the Microsoft Defender malware protection subsystem. It collects
Get-MpComputerStatus state, verifies that the anti-malware service and main
protection layers are enabled, and compares antivirus and antispyware signature
ages with warning and failure thresholds. Scan recency is checked separately by
HealthTest-RecentWindowsScan.
#>
    param([int]$WarnSigAgeDays=2,[int]$FailSigAgeDays=7)

    try {
      $s = Get-MpComputerStatus -ErrorAction Stop
    } catch {
      Write-Warning "[FAILURE] Microsoft Defender status could not be queried`n$($_.Exception.Message)"
      return
    }

    $featureChecks = @(
      @{ Name = 'DefenderSignaturesOutOfDate'; Expected = $false; Current = $s.DefenderSignaturesOutOfDate; Fix = "You may run`n  Update-MpSignature`n  to update." },
      @{ Name = 'AMServiceEnabled'; Expected = $true; Current = $s.AMServiceEnabled; Fix = '' },
      @{ Name = 'AMRunningMode'; Expected = 'Normal'; Current = $s.AMRunningMode; Fix = '' },
      @{ Name = 'RealTimeProtectionEnabled'; Expected = $true; Current = $s.RealTimeProtectionEnabled; Fix = '' },
      @{ Name = 'OnAccessProtectionEnabled'; Expected = $true; Current = $s.OnAccessProtectionEnabled; Fix = '' },
      @{ Name = 'NISEnabled'; Expected = $true; Current = $s.NISEnabled; Fix = '' },
      @{ Name = 'IoavProtectionEnabled'; Expected = $true; Current = $s.IoavProtectionEnabled; Fix = '' },
      @{ Name = 'BehaviorMonitorEnabled'; Expected = $true; Current = $s.BehaviorMonitorEnabled; Fix = '' },
      @{ Name = 'AntivirusEnabled'; Expected = $true; Current = $s.AntivirusEnabled; Fix = '' },
      @{ Name = 'AntispywareEnabled'; Expected = $true; Current = $s.AntispywareEnabled; Fix = '' }
    )

    $featureProblems = @()
    foreach ($check in $featureChecks) {
      if ($check.Current -ne $check.Expected) {
        $featureProblems += $check
      }
    }

    if ($featureProblems.Count -gt 0) {
      foreach ($check in $featureProblems) {
        $comment = "Current=$($check.Current); Expected=$($check.Expected)"
        if (-not [string]::IsNullOrWhiteSpace($check.Fix)) {
          $comment = "$comment`n$($check.Fix)"
        }
        Write-Warning "[FAILURE] Microsoft Defender posture check failed: $($check.Name)`n$comment"
      }
    } else {
      Write-Warning "[PASS] Microsoft Defender protection features are enabled and running normally."
    }

    $antivirusAge = if ($null -ne $s.AntivirusSignatureAge) { [int]$s.AntivirusSignatureAge } else { $null }
    $antispywareAge = if ($null -ne $s.AntispywareSignatureAge) { [int]$s.AntispywareSignatureAge } else { $null }
    $maxSignatureAge = $null
    foreach ($age in @($antivirusAge, $antispywareAge)) {
      if ($null -eq $age) { continue }
      if ($null -eq $maxSignatureAge -or $age -gt $maxSignatureAge) { $maxSignatureAge = $age }
    }

    if ($null -eq $maxSignatureAge) {
      Write-Warning "[WARNING] Defender signature ages could not be determined`nAV=$antivirusAge; AS=$antispywareAge; Version=$($s.AntivirusSignatureVersion)"
      return
    }

    if ($maxSignatureAge -ge $FailSigAgeDays) {
      Write-Warning "[FAILURE] Defender signatures are too old`nAV=$($s.AntivirusSignatureAge)d, AS=$($s.AntispywareSignatureAge)d, Version=$($s.AntivirusSignatureVersion)"
      return
    }

    if ($maxSignatureAge -ge $WarnSigAgeDays) {
      Write-Warning "[WARNING] Defender signatures are rather old`nAV=$($s.AntivirusSignatureAge)d, AS=$($s.AntispywareSignatureAge)d, Version=$($s.AntivirusSignatureVersion)"
      return
    }

    Write-Warning "[PASS] Defender signatures fresh (AV=$($s.AntivirusSignatureVersion))"
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-DefenderStatus
}
