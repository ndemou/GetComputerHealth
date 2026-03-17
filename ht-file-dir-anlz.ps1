<#
File & Directory Analysis
#>


function Normalize-DirectoryPath {
        param(
            [Parameter(Mandatory)]
            [string]$CandidatePath
        )

        if ($CandidatePath -match '^[a-zA-Z]:\\$') {
            return $CandidatePath
        }

        return $CandidatePath.TrimEnd('\\')
    }

function HealthTest-LargeDirectories {
<#
.SYNOPSIS
Checks Large Directories and flags unhealthy or non-baseline states by evaluating key signals from local/domain data sources and reporting pass/warn/fail outcomes.

.DESCRIPTION
Uses: None.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices.
Impact: High(Time).
#>
    $foundLargeDirectory = $false

    foreach ($dir in Find-LargeDirectory -Path 'C:\' -Threshold 10000 -SkipPaths @("C:\windows\servicing","C:\windows\WinSxS")) {
        $foundLargeDirectory = $true
        $comment = "$($dir.ItemsCount) items found"
        try {
            $profileComment = Get-DirFileProfile $dir.Path | Format-DirFileProfileNarrative -SingleLine -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($profileComment)) {
                $comment = $profileComment
            }
        }
        catch {}

        Write-Warning "[warning] $("Directory $($dir.Path) has more than 10000 child items")`n$($comment)"
    }

    if (-not $foundLargeDirectory) {
        Write-Warning "[pass] No large directories found over threshold"
    }
}


function Find-LargeDirectory {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string[]]$Path = @('C:\'),

        [Parameter(Mandatory = $false)]
        [int]$Threshold = 10000,

        [Parameter(Mandatory = $false)]
        [string[]]$SkipPaths = @()
    )
    $normalizedSkipPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($skipPath in $SkipPaths) {
        if ([string]::IsNullOrWhiteSpace($skipPath)) { continue }

        try {
            $resolvedSkipPath = Normalize-DirectoryPath -CandidatePath (Resolve-Path -LiteralPath $skipPath -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Path)
            [void]$normalizedSkipPaths.Add($resolvedSkipPath)
        }
        catch {}
    }

    function Visit-DirectoryForLargeCount {
        param (
            [Parameter(Mandatory)]
            [string]$CurrentPath
        )

        $normalizedCurrentPath = Normalize-DirectoryPath -CandidatePath $CurrentPath
        if ($normalizedSkipPaths.Contains($normalizedCurrentPath)) {
            return
        }

        try {
            $children = @(Get-ChildItem -LiteralPath $CurrentPath -ErrorAction Stop)
        }
        catch {
            return
        }

        $count = ($children | Measure-Object).Count
        if ($count -gt $Threshold) {
            [PSCustomObject]@{
                Path       = $CurrentPath
                ItemsCount = $count
            }
        }

        foreach ($childDir in $children) {
            if (-not $childDir.PSIsContainer) { continue }

            $childPath = Normalize-DirectoryPath -CandidatePath $childDir.FullName
            if ($normalizedSkipPaths.Contains($childPath)) {
                continue
            }

            Visit-DirectoryForLargeCount -CurrentPath $childDir.FullName
        }
    }

    foreach ($rootPath in $Path) {
        if ([string]::IsNullOrWhiteSpace($rootPath)) { continue }

        try {
            $resolvedRootPath = Normalize-DirectoryPath -CandidatePath (Resolve-Path -LiteralPath $rootPath -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Path)
            Write-Verbose "Scanning '$resolvedRootPath' for directories with > $Threshold items..."
            Visit-DirectoryForLargeCount -CurrentPath $resolvedRootPath
        }
        catch {}
    }
}


function Format-DirFileProfileNarrative {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
    [object[]]$Profile,

    [int]$MaxPeriods = 0,

    [switch]$SingleLine
  )

  begin { $all = New-Object System.Collections.Generic.List[object] }
  process { foreach ($p in $Profile) { [void]$all.Add($p) } }
  end {
    if ($all.Count -eq 0) { return "" }

    $oldest = ($all | Select-Object -First 1).oldest
    $newest = ($all | Select-Object -First 1).newest

    $periods = $all | Sort-Object period
    if ($MaxPeriods -gt 0 -and $periods.Count -gt $MaxPeriods) {
      $periods = $periods | Select-Object -First $MaxPeriods
    }

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add("Oldest file at $oldest. Newest at $newest.")

    foreach ($p in $periods) {
      $mb = $p.total_mb
      $cnt = $p.count
      $per = $p.period
      $exts = $p.top_exts
      if ($exts) { $parts.Add("$mb MB in $cnt files during $per ($exts).") }
      else { $parts.Add("$mb MB in $cnt files during $per.") }
    }

    if ($SingleLine) { return ($parts -join ' ') }
    ($parts -join [Environment]::NewLine)
  }
}


function Get-DirFileProfile {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Path
  )

  $files = Get-ChildItem -LiteralPath $Path -File -ErrorAction Stop
  if (-not $files) { return @() }

  $oldest = ($files | Sort-Object LastWriteTime | Select-Object -First 1).LastWriteTime
  $newest = ($files | Sort-Object LastWriteTime | Select-Object -Last 1).LastWriteTime

  $spanDays = [math]::Abs((New-TimeSpan -Start $oldest -End $newest).TotalDays)

  if ($spanDays -lt 15) { $fmt = 'yyyy-MM-dd' }
  elseif ($spanDays -lt 365) { $fmt = 'yyyy-MM' }
  else { $fmt = 'yyyy' }

  function _FormatTopExts {
    param([object[]]$GroupFiles)

    $extGroups =
      $GroupFiles |
      Group-Object { if ($_.Extension) { $_.Extension.ToLowerInvariant() } else { '(noext)' } } |
      Sort-Object Count,Name -Descending

    if (-not $extGroups -or $extGroups.Count -eq 0) { return "" }

    if ($extGroups.Count -eq 1) {
      $only = $extGroups[0].Name
      if ($only -eq '(noext)') { return "all (noext)" }
      return "all $only"
    }

    $top3 = $extGroups | Select-Object -First 3
    $s = ($top3 | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
    if ($extGroups.Count -gt 3) { $s += ", ..." }
    $s
  }

  $files |
    Group-Object { $_.LastWriteTime.ToString($fmt) } |
    ForEach-Object {
      $sum = ($_.Group | Measure-Object Length -Sum).Sum
      [pscustomobject]@{
        period   = $_.Name
        count    = $_.Count
        total_mb = [math]::Round($sum / 1MB, 2)
        top_exts = _FormatTopExts -GroupFiles $_.Group
        oldest   = $oldest
        newest   = $newest
      }
    } |
    Sort-Object Count,Name -Descending
}
