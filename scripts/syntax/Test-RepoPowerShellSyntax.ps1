<#
.SYNOPSIS
Parses all repository PowerShell files and reports any syntax errors clearly.

.DESCRIPTION
Uses `System.Management.Automation.Language.Parser::ParseFile()` on every `.ps1`
file in the repository except generated content under `.git` and `temp`.

The script keeps a cache of each checked file's last-write timestamp and parse
result under `temp\syntax-cache\ps1-parse-cache.json` so later runs only parse
files that changed since the last successful check.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepoRoot {
  $root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
  return $root.ProviderPath
}

function Get-RelativeRepoPath {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$Path
  )

  $repoUri = [System.Uri]((Resolve-Path -LiteralPath $RepoRoot).ProviderPath.TrimEnd('\') + '\')
  $pathUri = [System.Uri]((Resolve-Path -LiteralPath $Path).ProviderPath)
  $relativeUri = $repoUri.MakeRelativeUri($pathUri)
  return [System.Uri]::UnescapeDataString($relativeUri.ToString()).Replace('/', '\')
}

function Get-CachePath {
  param([Parameter(Mandatory)][string]$RepoRoot)
  return (Join-Path $RepoRoot 'temp\syntax-cache\ps1-parse-cache.json')
}

function Read-ParseCache {
  param([Parameter(Mandatory)][string]$CachePath)

  if (-not (Test-Path -LiteralPath $CachePath -PathType Leaf)) {
    return @{}
  }

  $raw = Get-Content -LiteralPath $CachePath -Raw -ErrorAction Stop
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return @{}
  }

  $data = $raw | ConvertFrom-Json
  $map = @{}

  if ($data.Files) {
    foreach ($item in $data.Files) {
      $map[[string]$item.Path] = [ordered]@{
        Path = [string]$item.Path
        LastWriteTimeUtc = [string]$item.LastWriteTimeUtc
        Passed = [bool]$item.Passed
        Errors = @($item.Errors)
      }
    }
  }

  return $map
}

function Convert-ToUtcTimestampString {
  param([Parameter(Mandatory)]$Value)

  if ($null -eq $Value) {
    return $null
  }

  if ($Value -is [datetime]) {
    return $Value.ToUniversalTime().ToString('o')
  }

  return ([datetime]$Value).ToUniversalTime().ToString('o')
}

function Write-ParseCache {
  param(
    [Parameter(Mandatory)][string]$CachePath,
    [Parameter(Mandatory)][hashtable]$Cache
  )

  $parent = Split-Path -Parent $CachePath
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }

  $payload = [ordered]@{
    UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
    Files = @(
      $Cache.Values |
        Sort-Object Path |
        ForEach-Object {
          [ordered]@{
            Path = $_.Path
            LastWriteTimeUtc = $_.LastWriteTimeUtc
            Passed = $_.Passed
            Errors = @($_.Errors)
          }
        }
    )
  }

  $json = $payload | ConvertTo-Json -Depth 10
  [System.IO.File]::WriteAllText($CachePath, $json, [System.Text.UTF8Encoding]::new($false))
}

function Get-RepoPowerShellFiles {
  param([Parameter(Mandatory)][string]$RepoRoot)

  $excludedRoots = @(
    (Join-Path $RepoRoot '.git'),
    (Join-Path $RepoRoot 'temp')
  )

  return @(
    Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Filter '*.ps1' |
      Where-Object {
        $fullName = $_.FullName
        foreach ($excluded in $excludedRoots) {
          if ($fullName.StartsWith($excluded + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
          }
        }
        return $true
      } |
      Sort-Object FullName
  )
}

function Format-ParseErrors {
  param($ParseErrors)

  return @(
    $ParseErrors | ForEach-Object {
      $line = $_.Extent.StartLineNumber
      $column = $_.Extent.StartColumnNumber
      $message = $_.Message.Trim()
      if ($column -gt 0) {
        "Line ${line}, Column ${column}: $message"
      }
      else {
        "Line ${line}: $message"
      }
    }
  )
}

function Test-PowerShellFileSyntax {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][System.IO.FileInfo]$File
  )

  $tokens = $null
  $parseErrors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($File.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null

  $relativePath = Get-RelativeRepoPath -RepoRoot $RepoRoot -Path $File.FullName
  $lastWriteTimeUtc = $File.LastWriteTimeUtc.ToString('o')
  $formattedErrors = @(
    if ($parseErrors) {
      Format-ParseErrors -ParseErrors $parseErrors
    }
  )

  return [ordered]@{
    Path = $relativePath
    LastWriteTimeUtc = $lastWriteTimeUtc
    Passed = ($formattedErrors.Count -eq 0)
    Errors = $formattedErrors
  }
}

$repoRoot = Get-RepoRoot
$cachePath = Get-CachePath -RepoRoot $repoRoot
$cache = Read-ParseCache -CachePath $cachePath
$currentFiles = Get-RepoPowerShellFiles -RepoRoot $repoRoot

$currentPaths = @{}
foreach ($file in $currentFiles) {
  $relativePath = Get-RelativeRepoPath -RepoRoot $repoRoot -Path $file.FullName
  $currentPaths[$relativePath] = $true
}

foreach ($cachedPath in @($cache.Keys)) {
  if (-not $currentPaths.ContainsKey($cachedPath)) {
    $cache.Remove($cachedPath)
  }
}

$checkedCount = 0
$reusedCount = 0

foreach ($file in $currentFiles) {
  $relativePath = Get-RelativeRepoPath -RepoRoot $repoRoot -Path $file.FullName
  $lastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')

  $cachedLastWriteTimeUtc = $null
  if ($cache.ContainsKey($relativePath)) {
    $cachedLastWriteTimeUtc = Convert-ToUtcTimestampString -Value $cache[$relativePath].LastWriteTimeUtc
  }

  if ($cache.ContainsKey($relativePath) -and $cachedLastWriteTimeUtc -eq $lastWriteTimeUtc) {
    $reusedCount++
    continue
  }

  $cache[$relativePath] = Test-PowerShellFileSyntax -RepoRoot $repoRoot -File $file
  $checkedCount++
}

Write-ParseCache -CachePath $cachePath -Cache $cache

$failures = @($cache.Values | Where-Object { -not $_.Passed } | Sort-Object Path)

if ($failures.Count -gt 0) {
  foreach ($failure in $failures) {
    Write-Host ("ParseFile found error(s) in: {0}" -f $failure.Path) -ForegroundColor Red
    foreach ($errorText in $failure.Errors) {
      Write-Host (" - {0}" -f $errorText) -ForegroundColor Red
    }
  }

  Write-Host ("Summary: {0} file(s) with syntax errors. Parsed {1} changed file(s); reused {2} unchanged file result(s)." -f $failures.Count, $checkedCount, $reusedCount) -ForegroundColor Red
  exit 1
}

Write-Host ("ParseFile found no errors in {0} PowerShell file(s). Parsed {1} changed file(s); reused {2} unchanged file result(s)." -f $cache.Count, $checkedCount, $reusedCount) -ForegroundColor Green
