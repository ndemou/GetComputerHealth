function Update-RepeatSuppressionState {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$TestName,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{8}$')][string]$Hash,
    [datetimeoffset]$NowUtc = [datetimeoffset]::UtcNow
  )

  $NowUtc = $NowUtc.ToUniversalTime()
  $Path = [IO.Path]::GetFullPath($Path)
  $directory = [IO.Path]::GetDirectoryName($Path)
  [void][IO.Directory]::CreateDirectory($directory)
  $lock = $null
  $temporaryPath = $null
  try {
    # Keep the lock file in place so concurrent writers always lock the same file.
    $lock = [IO.File]::Open("$Path.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $entries = @{}
    if (Test-Path -LiteralPath $Path -ErrorAction Stop) {
      if ((Get-Item -LiteralPath $Path -ErrorAction Stop).Length -gt 10MB) {
        throw 'SuppressRepeats state exceeds 10 MB.'
      }
      $text = [IO.File]::ReadAllText($Path)
      if (-not $text.TrimStart().StartsWith('[')) {
        throw 'SuppressRepeats state must contain a JSON array.'
      }
      $rows = ConvertFrom-Json -InputObject $text -ErrorAction Stop
      foreach ($row in $rows) {
        if ($null -eq $row -or [string]::IsNullOrWhiteSpace($row.TestName) -or
            $row.Hash -notmatch '^[0-9a-fA-F]{8}$' -or -not $row.FirstSeenUtc -or -not $row.LastSeenUtc) {
          throw 'Invalid SuppressRepeats state entry.'
        }
        $firstSeen = [datetimeoffset]::Parse($row.FirstSeenUtc, [Globalization.CultureInfo]::InvariantCulture)
        $lastSeen = [datetimeoffset]::Parse($row.LastSeenUtc, [Globalization.CultureInfo]::InvariantCulture)
        if ($firstSeen -gt $lastSeen) { throw 'FirstSeenUtc is later than LastSeenUtc.' }
        $key = "$($row.TestName)|$($row.Hash)"
        if ($entries.ContainsKey($key)) { throw 'Duplicate SuppressRepeats state entry.' }
        $entries[$key] = $row
      }
    }

    $key = "$TestName|$Hash"
    $previous = $entries[$key]
    $isRepeat = $false
    $firstSeenText = $NowUtc.UtcDateTime.ToString('o')
    if ($null -ne $previous) {
      $previousLastSeen = [datetimeoffset]::Parse($previous.LastSeenUtc, [Globalization.CultureInfo]::InvariantCulture)
      # A clock moving backwards must not hide a finding based on a future observation.
      if ($previousLastSeen -le $NowUtc) {
        $isRepeat = $NowUtc -lt $previousLastSeen.AddDays(45)
        $firstSeenText = [string]$previous.FirstSeenUtc
      }
    }
    $entries[$key] = [pscustomobject]@{
      TestName = $TestName
      Hash = $Hash.ToLowerInvariant()
      FirstSeenUtc = $firstSeenText
      LastSeenUtc = $NowUtc.UtcDateTime.ToString('o')
    }

    $rows = @($entries.Values | Sort-Object TestName, Hash)
    $json = ConvertTo-Json -InputObject $rows -Depth 3
    $encoding = New-Object System.Text.UTF8Encoding($false)
    if ($encoding.GetByteCount($json) -gt 10MB) { throw 'SuppressRepeats state exceeds 10 MB.' }
    $temporaryPath = Join-Path $directory ([IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($temporaryPath, $json, $encoding)
    if ([IO.File]::Exists($Path)) {
      [IO.File]::Replace($temporaryPath, $Path, [NullString]::Value)
    }
    else {
      [IO.File]::Move($temporaryPath, $Path)
    }

    # Return a decision only after the new observation has been saved successfully.
    [pscustomobject]@{
      Suppressed = $isRepeat
      FirstSeenUtc = $firstSeenText
      LastSeenUtc = $entries[$key].LastSeenUtc
    }
  }
  finally {
    if ($null -ne $lock) { $lock.Dispose() }
    if ($temporaryPath -and [IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
  }
}
