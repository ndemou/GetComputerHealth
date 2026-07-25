# HostRequirement: DC

function HealthTest-ADReplicationHealth {
<#
Description: Uses repadmin and local RSAT cross-checks to detect AD replication failures and stale replication latency.
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: repadmin.exe, Get-ADReplicationPartnerMetadata.
#>
  [CmdletBinding()]
  param(
    [TimeSpan]$WarnLargestDelta = ([TimeSpan]::FromHours(1)),
    [TimeSpan]$FailLargestDelta = ([TimeSpan]::FromHours(4))
  )

  $domainRole = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).DomainRole
  $isHostDC = ($domainRole -in 4,5)
  if (-not $isHostDC) { return }

  function Convert-RepadminDeltaToTimeSpan {
    param([string]$Text)

    if (-not $Text) { return $null }
    $t = $Text.Trim()

    $m = [regex]::Match($t, '^(?:(?<d>\d+)d:)?(?:(?<h>\d+)h:)?(?<m>\d+)m:(?<s>\d+)s$')
    if ($m.Success) {
      $days    = if ($m.Groups['d'].Success) { [int]$m.Groups['d'].Value } else { 0 }
      $hours   = if ($m.Groups['h'].Success) { [int]$m.Groups['h'].Value } else { 0 }
      $minutes = [int]$m.Groups['m'].Value
      $seconds = [int]$m.Groups['s'].Value
      return (New-TimeSpan -Days $days -Hours $hours -Minutes $minutes -Seconds $seconds)
    }

    $m = [regex]::Match($t, '^(?<s>\d+)s$')
    if ($m.Success) {
      return (New-TimeSpan -Seconds ([int]$m.Groups['s'].Value))
    }

    return $null
  }

  function Get-MaxTimeSpan {
    param([System.Collections.IEnumerable]$Values)

    $max = $null
    foreach ($v in $Values) {
      if ($null -eq $v) { continue }
      if ($null -eq $max -or $v -gt $max) { $max = $v }
    }
    $max
  }

  function Invoke-LocalRsatCrossCheck {
    param([string]$LocalHostName)

    $result = [ordered]@{
      Executed      = $false
      Passed        = $false
      FailedCount   = 0
      FailureText   = $null
      SummaryText   = $null
    }

    if (-not $LocalHostName) { return [pscustomobject]$result }

    $result.Executed = $true

    try {
      $md = Get-ADReplicationPartnerMetadata -Target $LocalHostName -ErrorAction Stop
    } catch {
      $result.FailedCount = 1
      $result.FailureText = "[WARNING] Local RSAT replication cross-check could not query partner metadata for $LocalHostName.`n$($_.Exception.Message)"
      return [pscustomobject]$result
    }

    if (-not $md) {
      $result.FailedCount = 1
      $result.FailureText = "[WARNING] Local RSAT replication cross-check returned no partner metadata for $LocalHostName."
      return [pscustomobject]$result
    }

    $bad = @($md | Where-Object { $_.LastReplicationResult -ne 0 })
    if ($bad.Count -gt 0) {
      $details = $bad | ForEach-Object {
        "$($_.Partner) rc=$($_.LastReplicationResult) lastSuccess=$($_.LastReplicationSuccess)"
      }
      $result.FailedCount = $bad.Count
      $result.FailureText = "[FAILURE] Local RSAT replication cross-check found partner errors for $LocalHostName.`n$($details -join ' | ')"
      return [pscustomobject]$result
    }

    $result.Passed = $true
    $result.SummaryText = "[PASS] Local RSAT replication cross-check found no partner errors for $LocalHostName."
    return [pscustomobject]$result
  }

  $localDc = $null
  $localHostName = $env:COMPUTERNAME
  try {
    $localDc = Get-ADDomainController -Identity $env:COMPUTERNAME -ErrorAction Stop
    if ($localDc -and $localDc.HostName) { $localHostName = $localDc.HostName }
  } catch {
  }

  $repadminCmd = Get-Command repadmin.exe -ErrorAction SilentlyContinue
  $repadmin = if ($repadminCmd -and $repadminCmd.Source) { $repadminCmd.Source } else { "$env:windir\system32\repadmin.exe" }

  $repadminAvailable = (Test-Path -LiteralPath $repadmin)
  $rsatCheck = Invoke-LocalRsatCrossCheck -LocalHostName $localHostName

  if (-not $repadminAvailable) {
    Write-Warning "[WARNING] repadmin.exe not found.`nDomain-wide AD replication checks were skipped; using local RSAT replication cross-check only."

    if ($rsatCheck.Executed) {
      if ($rsatCheck.FailedCount -gt 0) {
        Write-Warning $rsatCheck.FailureText
      } elseif ($rsatCheck.Passed) {
        Write-Warning $rsatCheck.SummaryText
      }
    } else {
      Write-Warning "[FAILURE] Neither repadmin.exe nor local RSAT replication cross-check data were available."
    }

    return
  }

  try {
    $sumOut = (& $repadmin /replsummary 2>&1 | Out-String)
  } catch {
    Write-Warning "[FAILURE] repadmin /replsummary could not be executed.`n$($_.Exception.Message)"

    if ($rsatCheck.Executed) {
      if ($rsatCheck.FailedCount -gt 0) {
        Write-Warning $rsatCheck.FailureText
      } elseif ($rsatCheck.Passed) {
        Write-Warning $rsatCheck.SummaryText
      }
    }

    return
  }

  if (-not $sumOut) {
    Write-Warning "[FAILURE] repadmin /replsummary returned no output."
  } else {
    $rows = @()
    foreach ($ln in ($sumOut -split '\r?\n')) {
      if ($ln -match '^\s*(?<DSA>\S+)\s+(?<Delta>(?:\d+d:)?(?:\d+h:)?\d+m:\d+s|\d+s)\s+(?<Fails>\d+)\s*/\s*(?<Total>\d+)\s+(?<Pct>\d+)\b') {
        $rows += [pscustomobject]@{
          DSA       = $Matches.DSA
          DeltaText = $Matches.Delta
          Delta     = Convert-RepadminDeltaToTimeSpan $Matches.Delta
          Fails     = [int]$Matches.Fails
          Total     = [int]$Matches.Total
          Percent   = [int]$Matches.Pct
        }
      }
    }

    if ($rows.Count -eq 0) {
      Write-Warning "[FAILURE] repadmin /replsummary output could not be parsed.`nRun repadmin /replsummary manually and inspect the output."
    } else {
      $badFails = @($rows | Where-Object { $_.Fails -gt 0 })
      foreach ($b in $badFails) {
        Write-Warning (
          "[FAILURE] Replication failures reported for DSA $($b.DSA)" +
          "`nFails: $($b.Fails) / $($b.Total)" +
          "`nLargest delta: $($b.DeltaText)" +
          "`nError percentage: $($b.Percent)%"
        )
      }
      $badDeltaFail = @($rows | Where-Object { $null -ne $_.Delta -and $_.Delta -ge $FailLargestDelta })
      foreach ($b in $badDeltaFail) {
        Write-Warning (
          "[FAILURE] Replication largest delta too high for DSA $($b.DSA)" +
          "`nLargest delta: $($b.DeltaText)" +
          "`nFail threshold: $($FailLargestDelta.ToString())" +
          "`nFails: $($b.Fails) / $($b.Total)"
        )
      }
      $badDeltaWarn = @(
        $rows |
        Where-Object {
          $null -ne $_.Delta -and
          $_.Delta -ge $WarnLargestDelta -and
          $_.Delta -lt $FailLargestDelta
        }
      )
      foreach ($b in $badDeltaWarn) {
        Write-Warning (
          "[WARNING] Replication largest delta elevated for DSA $($b.DSA)" +
          "`nLargest delta: $($b.DeltaText)" +
          "`nWarning threshold: $($WarnLargestDelta.ToString())" +
          "`nFail threshold: $($FailLargestDelta.ToString())" +
          "`nFails: $($b.Fails) / $($b.Total)"
        )
      }

      if ($badFails.Count -eq 0 -and $badDeltaFail.Count -eq 0) {
        $maxDelta = Get-MaxTimeSpan ($rows | Select-Object -ExpandProperty Delta)
        $maxDeltaText = if ($null -ne $maxDelta) { $maxDelta.ToString() } else { 'unknown' }
        Write-Warning "[PASS] repadmin /replsummary found no replication failures.`nLargest parsed delta: $maxDeltaText"
      }
    }
  }

  try {
    $showOut = (& $repadmin /showrepl * 2>&1 | Out-String)
  } catch {
    Write-Warning "[FAILURE] repadmin /showrepl * could not be executed.`n$($_.Exception.Message)"

    if ($rsatCheck.Executed) {
      if ($rsatCheck.FailedCount -gt 0) {
        Write-Warning $rsatCheck.FailureText
      } elseif ($rsatCheck.Passed) {
        Write-Warning $rsatCheck.SummaryText
      }
    }

    return
  }

  if (-not $showOut) {
    Write-Warning "[FAILURE] repadmin /showrepl * returned no output."
  } else {
    $lines = @($showOut -split '\r?\n')
    $currentDc = $null
    $currentNc = $null
    $currentVia = $null
    $attempts = @()

    foreach ($ln in $lines) {
      if ($ln -match '^Repadmin:\s+running command /showrepl against full DC\s+(?<dc>\S+)') {
        $currentDc = $Matches.dc
        $currentNc = $null
        $currentVia = $null
        continue
      }

      if ($ln -match '^\s*([A-Z]{2}=|CN=).+$') {
        $currentNc = $ln.Trim()
        $currentVia = $null
        continue
      }

      if ($ln -match '^\s+(?<partner>\S+)\s+via\s+(?<transport>\S+)\s*$') {
        $currentVia = $ln.Trim()
        continue
      }

      if ($ln -match 'Last attempt @') {
        $attempts += [pscustomobject]@{
          DC          = $currentDc
          NamingCtx   = $currentNc
          Neighbor    = $currentVia
          AttemptLine = $ln.Trim()
          Successful  = ($ln -match 'was successful\.$')
        }
      }
    }

    if ($attempts.Count -eq 0) {
      Write-Warning "[WARNING] repadmin /showrepl * produced no last-attempt lines.`nRun repadmin /showrepl * manually and inspect the output."
    } else {
      $notOk = @($attempts | Where-Object { -not $_.Successful })
      foreach ($a in $notOk) {
        Write-Warning (
          "[FAILURE] Replication last attempt was unsuccessful" +
          "`nDC: $($a.DC)" +
          "`nNaming context: $($a.NamingCtx)" +
          "`nNeighbor: $($a.Neighbor)" +
          "`n$($a.AttemptLine)"
        )
      }

      if ($notOk.Count -eq 0) {
        $dcCount = (@($attempts | Select-Object -ExpandProperty DC -Unique) | Measure-Object).Count
        Write-Warning (
          "[PASS] repadmin /showrepl * found all last attempts successful" +
          "`nChecked $($attempts.Count) inbound neighbor attempt line(s)" +
          "`nAcross $dcCount DC(s)"
        )
      }
    }
  }

  if ($rsatCheck.Executed) {
    if ($rsatCheck.FailedCount -gt 0) {
      Write-Warning $rsatCheck.FailureText
    } elseif ($rsatCheck.Passed) {
      Write-Warning $rsatCheck.SummaryText
    }
  }

}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-ADReplicationHealth
}
