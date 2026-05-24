# Provides:
#  - New-ZipFromFolder: Creates a zip file from a folder keeping that folder as the top-level entry in the zip.
param(
  [switch]$IncludeVersionlessZipScenario = ($env:GCH_TEST_INSTALLER_INCLUDE_VERSIONLESS -eq '1')
)

. (Join-Path $PSScriptRoot 'helpers-files.ps1')
. (Join-Path $PSScriptRoot 'test-helpers.ps1')

function Invoke-InstallerScenario {
  param(
    [Parameter(Mandatory)]
    [string]$ScenarioName,
    [switch]$UseVersionlessZip,
    [switch]$PassVersionArgument
  )

  Write-Host ("Running installer scenario: {0}" -f $ScenarioName) -ForegroundColor Cyan

  $runRoot = New-TestRunRoot -Name 'gch-installer'
  $paths = Get-TestPaths -RepoRoot (Split-Path -Parent $PSScriptRoot) -RunRoot $runRoot
  $zipPathInUse = $paths.ReleaseZipPath

  try {
    Assert-CommandAvailable 'robocopy'
    Assert-PathExists -Path $paths.HelperScript -Message "Missing helper script required by installer test: $($paths.HelperScript)"
    Assert-PathExists -Path $paths.UpdateScriptSource -Message "Missing installer script under test: $($paths.UpdateScriptSource)"
    Assert-DirectoryWritable -Path $paths.ReleaseRoot
    Assert-DirectoryWritable -Path $paths.InstallRoot

    . $paths.HelperScript

    Invoke-RobocopyChecked -Source $paths.RepoRoot -Destination $paths.ReleaseRoot -ExcludeDirectories @('.git')

    foreach ($zipPath in @($paths.ReleaseZipPath, $paths.ReleaseZipPathVersionless)) {
      if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
      }
    }

    New-ZipFromFolder -SourceFolderPath $paths.RepoRoot -DestinationPath $paths.ReleaseZipPath -Exclude @('*.bak','*.tmp','.git') -NoCompression

    if ($UseVersionlessZip) {
      Move-Item -LiteralPath $paths.ReleaseZipPath -Destination $paths.ReleaseZipPathVersionless -Force
      $zipPathInUse = $paths.ReleaseZipPathVersionless
    }

    Copy-Item -LiteralPath $paths.UpdateScriptSource -Destination $paths.InstallRoot -Force

    $updateParams = @{
      Reinstall = $true
      UpdateFromZip = $zipPathInUse
    }
    if ($PassVersionArgument) {
      $updateParams['Version'] = $paths.RepoVersion
    }

    & (Join-Path $paths.InstallRoot 'Update-GetHealthCode.ps1') @updateParams
  } finally {
    foreach ($zipPath in @($paths.ReleaseZipPath, $paths.ReleaseZipPathVersionless)) {
      if ($zipPath -and (Test-Path -LiteralPath $zipPath)) {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
      }
    }
    Remove-TestRunRoot -Path $runRoot
  }
}

Invoke-InstallerScenario -ScenarioName 'versioned-zip-name'

if ($IncludeVersionlessZipScenario) {
  Invoke-InstallerScenario -ScenarioName 'versionless-zip-name-with-Version' -UseVersionlessZip -PassVersionArgument
}
