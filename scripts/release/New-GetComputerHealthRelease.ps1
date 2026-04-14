<#
.SYNOPSIS
Creates and publishes a new GetComputerHealth GitHub release.

.DESCRIPTION
Performs the repository release flow end to end:
- syncs `main` with `origin`
- bumps the embedded semantic version in `Get-ComputerHealth.ps1`
- runs the standard unit and smoke test wrappers
- builds a versioned release zip with the expected top-level folder shape
- validates installation from that zip
- commits and pushes the version bump
- creates a GitHub release with the zip asset attached

.PARAMETER Part
Semantic version part to increment. Defaults to `Minor`.

.EXAMPLE
.\scripts\release\New-GetComputerHealthRelease.ps1

.EXAMPLE
.\scripts\release\New-GetComputerHealthRelease.ps1 -Part Patch
#>
[CmdletBinding()]
param(
  [ValidateSet('Major','Minor','Patch')]
  [string]$Part = 'Minor'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
  param([Parameter(Mandatory)][string]$Message)
  Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor Cyan
}

function Assert-CommandAvailable {
  param([Parameter(Mandatory)][string]$Name)
  if (-not (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $Name"
  }
}

function Get-RepoRoot {
  $root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
  return $root.ProviderPath
}

function Get-EmbeddedVersion {
  param([Parameter(Mandatory)][string]$Path)
  $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
  $match = [regex]::Match($content, '(?m)^\$VERSION\s*=\s*"(?<Version>\d+\.\d+\.\d+)"')
  if (-not $match.Success) {
    throw "Could not find embedded version in $Path"
  }
  return [version]$match.Groups['Version'].Value
}

function Get-LatestSemanticTagVersion {
  $tags = @(git tag --list)
  $versions = foreach ($tag in $tags) {
    if ($tag -match '^(?:v)?(?<Version>\d+\.\d+\.\d+)$') {
      [version]$Matches['Version']
    }
  }

  if (-not $versions -or $versions.Count -eq 0) {
    return [version]'0.0.0'
  }

  return ($versions | Sort-Object -Descending | Select-Object -First 1)
}

function Get-MaxVersion {
  param(
    [Parameter(Mandatory)][version]$Left,
    [Parameter(Mandatory)][version]$Right
  )
  if ($Left -ge $Right) { return $Left }
  return $Right
}

function Get-IncrementedVersion {
  param(
    [Parameter(Mandatory)][version]$BaseVersion,
    [Parameter(Mandatory)][string]$VersionPart
  )

  switch ($VersionPart) {
    'Major' { return [version]::new($BaseVersion.Major + 1, 0, 0) }
    'Minor' { return [version]::new($BaseVersion.Major, $BaseVersion.Minor + 1, 0) }
    'Patch' { return [version]::new($BaseVersion.Major, $BaseVersion.Minor, $BaseVersion.Build + 1) }
    default { throw "Unsupported version part: $VersionPart" }
  }
}

function Set-EmbeddedVersion {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Version
  )

  $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
  $updated = [regex]::Replace(
    $content,
    '(?m)^\$VERSION\s*=\s*"(?<Version>\d+\.\d+\.\d+)"',
    ('$VERSION="{0}"' -f $Version),
    1
  )

  if ($updated -eq $content) {
    throw "Embedded version update made no change in $Path"
  }

  [System.IO.File]::WriteAllText($Path, $updated, [System.Text.UTF8Encoding]::new($false))
}

function Get-GitHubRepoSlug {
  $originUrl = (git remote get-url origin).Trim()
  if ($originUrl -match 'github\.com[:/](?<Owner>[^/]+)/(?<Repo>[^/.]+?)(?:\.git)?$') {
    return ('{0}/{1}' -f $Matches['Owner'], $Matches['Repo'])
  }
  throw "Could not parse GitHub repo slug from origin URL: $originUrl"
}

function New-ReleaseZip {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$Version
  )

  $buildRoot = Join-Path $RepoRoot 'temp\release-build'
  $packageName = 'GetComputerHealth-{0}' -f $Version
  $packageRoot = Join-Path $buildRoot $packageName
  $zipPath = Join-Path $buildRoot ($packageName + '.zip')

  if (Test-Path -LiteralPath $buildRoot) {
    Remove-Item -LiteralPath $buildRoot -Recurse -Force
  }

  New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null

  Get-ChildItem -LiteralPath $RepoRoot -Force | Where-Object {
    $_.Name -notin @('.git','temp')
  } | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $packageRoot -Recurse -Force
  }

  Compress-Archive -LiteralPath $packageRoot -DestinationPath $zipPath -CompressionLevel NoCompression -Force

  if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
    throw "Release zip was not created: $zipPath"
  }

  return $zipPath
}

function Test-ReleaseZipInstall {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$ZipPath,
    [Parameter(Mandatory)][string]$ExpectedVersion
  )

  $validateRoot = Join-Path $RepoRoot 'temp\install-validate'
  $binPath = Join-Path $validateRoot 'bin'
  $installScriptPath = Join-Path $binPath 'install.ps1'

  if (Test-Path -LiteralPath $validateRoot) {
    Remove-Item -LiteralPath $validateRoot -Recurse -Force
  }

  New-Item -ItemType Directory -Path $binPath -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $RepoRoot 'install.ps1') -Destination $installScriptPath -Force

  Push-Location $binPath
  try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Source $ZipPath -Reinstall
  }
  finally {
    Pop-Location
  }

  $versionFilePath = Join-Path $validateRoot 'VERSION'
  if (-not (Test-Path -LiteralPath $versionFilePath -PathType Leaf)) {
    throw "Installer validation did not produce VERSION file: $versionFilePath"
  }

  $installedVersion = (Get-Content -LiteralPath $versionFilePath -Raw -ErrorAction Stop).Trim()
  if ($installedVersion -ne $ExpectedVersion) {
    throw "Installer validation wrote VERSION '$installedVersion' instead of '$ExpectedVersion'"
  }
}

$repoRoot = Get-RepoRoot
Set-Location $repoRoot

Assert-CommandAvailable -Name 'git'
Assert-CommandAvailable -Name 'gh'
Assert-CommandAvailable -Name 'powershell'

$status = @(git status --porcelain)
if ($status.Count -gt 0) {
  throw "Working tree is not clean. Commit, stash, or discard changes before creating a release."
}

$branch = (git rev-parse --abbrev-ref HEAD).Trim()
if ($branch -ne 'main') {
  throw "Release script must be run from branch 'main'. Current branch: $branch"
}

$versionScriptPath = Join-Path $repoRoot 'Get-ComputerHealth.ps1'
$repoSlug = Get-GitHubRepoSlug

Write-Step 'Fetching latest origin state and tags'
git fetch --tags origin | Out-Host

Write-Step 'Rebasing local main onto origin/main'
git pull --rebase origin main | Out-Host

$embeddedVersion = Get-EmbeddedVersion -Path $versionScriptPath
$latestTagVersion = Get-LatestSemanticTagVersion
$baseVersion = Get-MaxVersion -Left $embeddedVersion -Right $latestTagVersion
$newVersion = Get-IncrementedVersion -BaseVersion $baseVersion -VersionPart $Part
$newVersionText = $newVersion.ToString()
$releaseTag = 'v{0}' -f $newVersionText

if (git tag --list $releaseTag) {
  throw "Tag already exists: $releaseTag"
}

Write-Step ("Bumping version from {0} to {1}" -f $embeddedVersion, $newVersionText)
Set-EmbeddedVersion -Path $versionScriptPath -Version $newVersionText

Write-Step 'Running unit tests'
& powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-unit-tests.ps1

Write-Step 'Running smoke tests'
& .\tests\run-all-tests.ps1 -Smoke

Write-Step 'Building release zip'
$zipPath = New-ReleaseZip -RepoRoot $repoRoot -Version $newVersionText

Write-Step 'Validating installation from the release zip'
Test-ReleaseZipInstall -RepoRoot $repoRoot -ZipPath $zipPath -ExpectedVersion $newVersionText

Write-Step 'Committing version bump'
git add -- $versionScriptPath | Out-Host
git commit -m ("Bump version to {0}" -f $newVersionText) | Out-Host

Write-Step 'Pushing main to origin'
git push origin main | Out-Host

Write-Step ("Creating GitHub release {0}" -f $releaseTag)
gh release create $releaseTag $zipPath --target main --title $releaseTag --generate-notes | Out-Host

Write-Step 'Release completed successfully'
Write-Host ("Version: {0}" -f $newVersionText)
Write-Host ("Tag: {0}" -f $releaseTag)
Write-Host ("Zip: {0}" -f $zipPath)
Write-Host ("Repo: {0}" -f $repoSlug)
