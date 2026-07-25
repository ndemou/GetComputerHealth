# HostRequirement: All

function HealthTest-TimeSyncAccuracy {
<#
Description: Checks whether the local clock appears reasonably synchronized.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: w32tm.exe.
#>
  param(
    [int]$WarnOffsetSeconds=15,
    [int]$FailOffsetSeconds=30,
    [string]$RefTimeServer='time.windows.com',
    [switch]$AlwaysUseRef
  )

  $source = ''
  try {
    $srcOut = (w32tm /query /source 2>&1) -join "`n"
    if ($LASTEXITCODE -eq 0) {
      $source = ($srcOut -split "`r?`n")[0].Trim()
    }
  } catch {}

  $target = $RefTimeServer
  if (-not $AlwaysUseRef -and $source) {
    $src1 = ($source -split ',',2)[0].Trim()
    $isNonHost = $src1 -match '(?i)(free[-\s]?running|local\s+(cmos|rtc)|vm\s+ic|hyper[-\s]?v|unsynchronized|no\s+source|local\s+clock)'
    $looksIPv4 = $src1 -match '^(?:\d{1,3}\.){3}\d{1,3}$'
    $looksName = $src1 -match '^[A-Za-z0-9][A-Za-z0-9\-\.]*[A-Za-z0-9]$'
    $looksIPv6 = $src1 -match '^[\[\]0-9A-Fa-f:]+$'
    if (($looksIPv4 -or $looksName -or $looksIPv6) -and -not $isNonHost) { $target = $src1 }
  }

  $sc = (w32tm /stripchart /computer:$target /dataonly /samples:2 2>&1) -join "`n"
  $exit = $LASTEXITCODE
  if ($exit -ne 0) {
    $hex = '0x{0:X}' -f ($exit -band 0xFFFFFFFF)
    if ($target -ne $RefTimeServer) {
        Write-Warning "[NOTICE] Failed to test time sync via $target, retrying with $RefTimeServer`nStripchart to $target failed with error $hex"
        # retry
        $sc = (w32tm /stripchart /computer:$RefTimeServer /dataonly /samples:2 2>&1) -join "`n"
        $exit = $LASTEXITCODE
        if ($exit -ne 0) {
          $hex = '0x{0:X}' -f ($exit -band 0xFFFFFFFF)
          Write-Warning "[WARNING] Failed to test time sync either via $target or via $RefTimeServer`nStripchart to $RefTimeServer failed with error $hex"
          return
        }
        $target = $RefTimeServer
    } else {
        Write-Warning "[WARNING] Failed to test time sync`nStripchart to $target failed with error $hex"
        return
    }
  }

  $m = [regex]::Match($sc,'([-+]?\d+(?:[.,]\d+)?)s')
  if (-not $m.Success) {
    Write-Warning "[WARNING] Failed to test time sync`nCould not parse offset from stripchart to $target"
    return
  }

  $valStr = $m.Groups[1].Value.Replace(',', '.')
  $offsetSec = [double]::Parse($valStr, [System.Globalization.CultureInfo]::InvariantCulture)
  $abs = [math]::Abs($offsetSec)
  $ok = $true

  if ($abs -ge $FailOffsetSeconds) {
    $details = "$offsetSec s exceeds $FailOffsetSeconds s (2-samples)"
    Write-Warning ("[FAILURE] Time offset too high" + "`n" + $details)
    $ok = $false
  } elseif ($abs -ge $WarnOffsetSeconds) {
    $details = "$offsetSec s exceeds $WarnOffsetSeconds s (2-samples)"
    Write-Warning ("[WARNING] Time offset rather high" + "`n" + $details)
    $ok = $false
  }

  if ($ok) {
    Write-Warning ("[PASS] Time OK (1-sample); source: {0}; target: {1}; offset: {2} s" -f $source,$target,$offsetSec)
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-TimeSyncAccuracy
}
