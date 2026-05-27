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

    $legacyTempDir = Join-Path $paths.TestRoot 'temp'
    $legacyWorkbookPath = Join-Path $legacyTempDir 'all-messages-legacy.xlsx'
    New-Item -ItemType Directory -Path $legacyTempDir -Force | Out-Null
    Set-Content -LiteralPath $legacyWorkbookPath -Value 'legacy workbook placeholder' -NoNewline

    Copy-Item -LiteralPath $paths.UpdateScriptSource -Destination $paths.InstallRoot -Force

    $updateParams = @{
      Reinstall = $true
      UpdateFromZip = $zipPathInUse
    }
    if ($PassVersionArgument) {
      $updateParams['Version'] = $paths.RepoVersion
    }

    & (Join-Path $paths.InstallRoot 'Update-GetHealthCode.ps1') @updateParams

    $migratedWorkbookPath = Join-Path $paths.TestRoot 'data\all-messages-legacy.xlsx'
    Assert-PathExists -Path $migratedWorkbookPath -Message "Expected disk format migration to move legacy workbook to data: $migratedWorkbookPath"
    Assert-True -Condition (-not (Test-Path -LiteralPath $legacyWorkbookPath)) -Message "Expected disk format migration to remove legacy workbook from temp: $legacyWorkbookPath"

    $diskFormatStatePath = Join-Path $paths.TestRoot 'data\disk-format.psd1'
    Assert-PathExists -Path $diskFormatStatePath -Message "Expected disk format state file to exist: $diskFormatStatePath"
    $diskFormatState = Import-PowerShellDataFile -LiteralPath $diskFormatStatePath -ErrorAction Stop
    Assert-True -Condition ([int]$diskFormatState.CurrentDiskFormat -ge 5) -Message "Expected CurrentDiskFormat to be at least 5."
    Assert-True -Condition ([int]$diskFormatState.LatestCompatibleCodeVersion -ge 5) -Message "Expected LatestCompatibleCodeVersion to be at least 5."
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
