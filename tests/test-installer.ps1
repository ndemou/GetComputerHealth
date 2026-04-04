# Provides:
#  - New-ZipFromFolder: Creates a zip file from a folder keeping that folder as the top-level entry in the zip.
. (Join-Path $PSScriptRoot 'test-helpers.ps1')

$runRoot = New-TestRunRoot -Name 'gch-installer'
$paths = Get-TestPaths -RepoRoot (Split-Path -Parent $PSScriptRoot) -RunRoot $runRoot

try {
  Assert-CommandAvailable 'robocopy'
  Assert-PathExists -Path $paths.HelperScript -Message "Missing helper script required by installer test: $($paths.HelperScript)"
  Assert-PathExists -Path $paths.UpdateScriptSource -Message "Missing installer script under test: $($paths.UpdateScriptSource)"
  Assert-DirectoryWritable -Path $paths.ReleaseRoot
  Assert-DirectoryWritable -Path $paths.InstallRoot

  . $paths.HelperScript

  Invoke-RobocopyChecked -Source $paths.RepoRoot -Destination $paths.ReleaseRoot -ExcludeDirectories @('.git')

  if (Test-Path -LiteralPath $paths.ReleaseZipPath) {
    Remove-Item -LiteralPath $paths.ReleaseZipPath -Force
  }

  New-ZipFromFolder -SourceFolderPath $paths.RepoRoot -DestinationPath $paths.ReleaseZipPath -Exclude @('*.bak','*.tmp','.git') -NoCompression

  Copy-Item -LiteralPath $paths.UpdateScriptSource -Destination $paths.InstallRoot -Force

  & (Join-Path $paths.InstallRoot 'Update-GetHealthCode.ps1') -Reinstall $paths.ReleaseZipPath
} finally {
  Remove-TestRunRoot -Path $runRoot
}
