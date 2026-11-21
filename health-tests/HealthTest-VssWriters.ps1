# HostRequirement: All

function HealthTest-VssWriters{
<#
Description: Checks whether all VSS writers report stable or waiting states.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: vssadmin.exe.
#>

  try {
    # Preserve stderr as details without losing the native process exit code.
    $ErrorActionPreference = 'Continue'
    $output = & vssadmin.exe list writers 2>&1
    $status = $LASTEXITCODE
  } catch {
    Write-Warning "[WARNING] Could not start VSS writer inspection`n$($_.Exception.Message)"
    return
  }

  $raw = ($output -join "`n").Trim()
  if ($status -ne 0) {
    Write-Warning "[WARNING] VSS writer inspection failed`nExit code: $status`n$raw"
    return
  }

  $blocks = @($raw -split '\r?\n(?:[ \t]*\r?\n)+')
  if ($blocks[0] -match '^vssadmin[ \t]+\d+(?:[.,]\d+)?[ \t]+-[^\r\n]+\r?\n[^\r\n]+$') {
    $blocks = @($blocks | Select-Object -Skip 1)
  }

  # Field order, GUIDs, and the bracketed state code are independent of language.
  $guidField = '^\s*[^:]+:\s*(?<id>\{[^{}]+\})\s*$'
  $seenInstances = [System.Collections.Generic.HashSet[guid]]::new()
  $incomplete = [System.Collections.Generic.List[string]]::new()
  $hasFailedWriter = $false
  foreach ($block in $blocks) {
    $lines = @($block -split '\r?\n')
    if ($lines.Count -ne 5) {
      if ($block) { $incomplete.Add($block) }
      continue
    }

    $name = [regex]::Match($lines[0], "^\s*[^:]+:\s*'(?<name>.+)'\s*$")
    $writerId = [regex]::Match($lines[1], $guidField)
    $instanceId = [regex]::Match($lines[2], $guidField)
    $state = [regex]::Match($lines[3], '^\s*[^:]+:\s*\[(?<code>[0-9]{1,3})\](?:\s+.*)?$')
    $writerGuid = [guid]::Empty
    $instanceGuid = [guid]::Empty
    if (-not $name.Success -or
        -not [guid]::TryParse($writerId.Groups['id'].Value, [ref]$writerGuid) -or
        -not [guid]::TryParse($instanceId.Groups['id'].Value, [ref]$instanceGuid) -or
        -not $state.Success -or $lines[4] -notmatch '^\s*[^:]+:\s*\S' -or
        -not $seenInstances.Add($instanceGuid)) {
      $incomplete.Add($block)
      continue
    }

    $writer = $name.Groups['name'].Value
    $code = [int]$state.Groups['code'].Value
    # VSS_WRITER_STATE: 1 is stable, 2-5 are waiting, and 6-15 failed.
    if ($code -ge 6 -and $code -le 15) {
      Write-Warning "[FAILURE] VSS writer '$writer' failed`n$block"
      $hasFailedWriter = $true
    } elseif ($code -lt 1 -or $code -gt 5) {
      $incomplete.Add("Unknown VSS writer state $code.`n$block")
    }
  }

  if ($seenInstances.Count -eq 0 -or $incomplete.Count -gt 0) {
    $details = if ($incomplete.Count -gt 0) { $incomplete -join "`n`n" } else { 'No writer records were returned.' }
    Write-Warning "[WARNING] VSS writer inspection was incomplete`n$details"
  } elseif (-not $hasFailedWriter) {
    Write-Warning '[PASS] All VSS writers report stable or waiting states'
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-VssWriters
}
