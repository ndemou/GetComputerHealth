<#
.DESCRIPTION
Converts legacy custom health test scripts so they can be executed directly.

.MANIFEST
ModifiedTopFolders = config
NewTopFolders =
#>

$ErrorActionPreference = 'Stop'

function Get-FunctionInvocationBlock {
  param(
    [Parameter(Mandatory)][string[]]$FunctionNames
  )

  if (-not $FunctionNames) {
    return ''
  }

  $lines = @(
    ''
    '# Added automatically by Get-ComputerHealth disk format migration 7.'
    '# This makes the custom test directly runnable as a script.'
  )
  foreach ($name in $FunctionNames) {
    $lines += $name
  }
  return (($lines -join "`r`n") + "`r`n")
}

function Write-TextPreservingEncoding {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Text,
    [Parameter(Mandatory)][object]$EncodingInfo
  )

  $encoding = $EncodingInfo.DotNetEncodingObj
  if ($null -eq $encoding) {
    throw "Could not determine the encoding of '$Path'."
  }

  $bomBytes = [byte[]]@()
  if ($EncodingInfo.PSObject.Properties['BOMBytes'] -and $EncodingInfo.BOMBytes) {
    $bomBytes = [byte[]]$EncodingInfo.BOMBytes
  }

  $textToWrite = $Text
  if (($bomBytes.Length -gt 0) -and ($textToWrite.Length -gt 0) -and ($textToWrite[0] -eq [char]0xFEFF)) {
    $textToWrite = $textToWrite.Substring(1)
  }

  $bodyBytes = $encoding.GetBytes($textToWrite)
  $allBytes = New-Object byte[] ($bomBytes.Length + $bodyBytes.Length)
  if ($bomBytes.Length -gt 0) {
    [Array]::Copy($bomBytes, 0, $allBytes, 0, $bomBytes.Length)
  }
  if ($bodyBytes.Length -gt 0) {
    [Array]::Copy($bodyBytes, 0, $allBytes, $bomBytes.Length, $bodyBytes.Length)
  }

  [System.IO.File]::WriteAllBytes($Path, $allBytes)
}

try {
  $rootDir = (Get-Location).Path
  $repoRoot = Split-Path -Parent $PSScriptRoot
  $customTestsDir = Join-Path $rootDir 'config\Custom-HealthTests'
  $updaterPath = Join-Path $rootDir 'bin\Update-GetHealthCode.ps1'
  $helperPath = Join-Path $repoRoot 'helpers-text-files.ps1'

  if (-not (Test-Path -LiteralPath $customTestsDir -PathType Container)) {
    Write-Output 'No migration is needed'
    exit 1
  }

  if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
    throw "Missing helper script '$helperPath'."
  }

  . $helperPath

  $scripts = @(Get-ChildItem -LiteralPath $customTestsDir -Filter *.ps1 -File -ErrorAction SilentlyContinue)
  if ($scripts.Count -eq 0) {
    Write-Output 'No migration is needed'
    exit 1
  }

  $changedCount = 0
  foreach ($scriptFile in $scripts) {
    $encodingInfo = Get-TextFileEncoding -Path $scriptFile.FullName -ErrorAction Stop
    $encoding = $encodingInfo.DotNetEncodingObj
    if ($null -eq $encoding) {
      throw "Could not determine the encoding of '$($scriptFile.FullName)'."
    }

    $content = Get-Content -LiteralPath $scriptFile.FullName -Raw -ErrorAction Stop
    if (($content.Length -gt 0) -and ($content[0] -eq [char]0xFEFF)) {
      $content = $content.Substring(1)
    }

    $functionMatches = @(Select-String -LiteralPath $scriptFile.FullName -Pattern '^\s*function\s+(?<Name>(?:HealthTest|CustomHealthTest)-[A-Za-z0-9_-]+)\b' -AllMatches -ErrorAction Stop)
    if ($functionMatches.Count -eq 0) {
      continue
    }

    $functionNames = @(
      $functionMatches |
      ForEach-Object { $_.Matches } |
      ForEach-Object { $_.Groups['Name'].Value } |
      Where-Object { $_ } |
      Sort-Object -Unique
    )

    $missingInvocations = @()
    foreach ($functionName in $functionNames) {
      $callPattern = '(?m)^\s*&?\s*' + [regex]::Escape($functionName) + '\s*(?:#.*)?$'
      if ($content -notmatch $callPattern) {
        $missingInvocations += $functionName
      }
    }

    if (@($missingInvocations).Count -eq 0) {
      continue
    }

    $newContent = $content.TrimEnd("`r", "`n") + (Get-FunctionInvocationBlock -FunctionNames $missingInvocations)
    Write-TextPreservingEncoding -Path $scriptFile.FullName -Text $newContent -EncodingInfo $encodingInfo
    Write-Output ("Appended direct-run invocations to '{0}': {1}" -f $scriptFile.FullName, ($missingInvocations -join ', '))
    $changedCount += 1
  }

  if ($changedCount -eq 0) {
    Write-Output 'No migration is needed'
    exit 1
  }

  Write-Output "PATH_TO_UPDATER=$updaterPath"
  exit 0
}
catch {
  Write-Error $_.Exception.Message
  Write-Error 'Migration failed'
  exit 2
}
