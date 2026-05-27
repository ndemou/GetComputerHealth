Describe 'Update-GetHealthCode temporary directory selection' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $scriptPath = Join-Path $repoRoot 'Update-GetHealthCode.ps1'

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)

    if ($parseErrors -and $parseErrors.Count -gt 0) {
      throw "Could not parse ${scriptPath}: $($parseErrors[0].Message)"
    }

    $functionNames = @(
      'Write-UpdateEvent',
      'New-RandomTempDirectoryPath',
      'New-EmptyTempDirectory',
      'Get-GchDefaultConfigText',
      'Ensure-GchConfigFile',
      'Read-GchConfigFile',
      'Test-GchConfigKey',
      'Get-GchConfigValue',
      'Test-GchFalsyValue',
      'Resolve-GchConfiguredRepoUrl',
      'Resolve-GchConfiguredNonNegativeInteger',
      'Get-DiskFormatStateText',
      'Read-DiskFormatState',
      'Write-DiskFormatState',
      'Get-GetComputerHealthMajorVersion',
      'ConvertTo-DiskFormatManifestList',
      'Read-DiskFormatMigrationManifest',
      'Get-DiskFormatMigrationScripts',
      'Remove-OldDiskFormatMigrationBackups',
      'Backup-DiskFormatMigrationFolders',
      'Restore-DiskFormatMigrationFolders',
      'Remove-DiskFormatMigrationNewFolders',
      'Invoke-DiskFormatMigrationScript',
      'Invoke-DiskFormatMigrations'
    )

    foreach ($functionName in $functionNames) {
      $funcAst = $ast.Find({
          param($node)
          $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -eq $functionName
        }, $true)

      if ($null -eq $funcAst) {
        throw "Function not found in ${scriptPath}: $functionName"
      }

      . ([scriptblock]::Create($funcAst.Extent.Text))
    }
  }

  It 'uses a random suffixed temp directory when the default directory cannot be enumerated' {
    $savedTemp = $env:TEMP
    $tempRoot = Join-Path $env:TEMP ('gch-update-temp-test-' + [guid]::NewGuid().ToString())
    $defaultPath = Join-Path $tempRoot 'Update-GetHealthCode'
    $expectedPath = Join-Path $tempRoot 'Update-GetHealthCode.42'

    try {
      New-Item -ItemType Directory -Path $defaultPath -Force | Out-Null
      $env:TEMP = $tempRoot

      Mock Get-Random { 42 }
      Mock Get-ChildItem { throw [System.UnauthorizedAccessException]::new('Access denied for test') } -ParameterFilter {
        $LiteralPath -eq $defaultPath
      }

      $result = New-EmptyTempDirectory -Name 'Update-GetHealthCode'

      $result | Should -Be $expectedPath
      Test-Path -LiteralPath $expectedPath -PathType Container | Should -BeTrue
    } finally {
      $env:TEMP = $savedTemp
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'uses a random suffixed temp directory when the default path is a file' {
    $savedTemp = $env:TEMP
    $tempRoot = Join-Path $env:TEMP ('gch-update-temp-test-' + [guid]::NewGuid().ToString())
    $defaultPath = Join-Path $tempRoot 'Update-GetHealthCode'
    $expectedPath = Join-Path $tempRoot 'Update-GetHealthCode.123'

    try {
      New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
      Set-Content -LiteralPath $defaultPath -Value 'occupied' -NoNewline
      $env:TEMP = $tempRoot

      Mock Get-Random { 123 }

      $result = New-EmptyTempDirectory -Name 'Update-GetHealthCode'

      $result | Should -Be $expectedPath
      Test-Path -LiteralPath $expectedPath -PathType Container | Should -BeTrue
    } finally {
      $env:TEMP = $savedTemp
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'creates the default gch.psd1 file' {
    $tempRoot = Join-Path $env:TEMP ('gch-config-test-' + [guid]::NewGuid().ToString())
    $configPath = Join-Path $tempRoot 'config\gch.psd1'

    try {
      Ensure-GchConfigFile -Path $configPath -RepoUrl 'https://github.com/ndemou/GetComputerHealth' -ShowAsPostponedWindowDays 150
      $config = Read-GchConfigFile -Path $configPath

      Test-GchConfigKey -Config $config -Key 'AutomaticUpdates' | Should -BeTrue
      Get-GchConfigValue -Config $config -Key 'AutomaticUpdates' | Should -BeTrue
      Get-GchConfigValue -Config $config -Key 'RepoUrl' | Should -Be 'https://github.com/ndemou/GetComputerHealth'
      Get-GchConfigValue -Config $config -Key 'ShowAsPostponedWindowDays' | Should -Be 150
      Test-GchFalsyValue -Value (Get-GchConfigValue -Config $config -Key 'AutomaticUpdates') | Should -BeFalse
    } finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'validates configured repo url and postponed window values' {
    Resolve-GchConfiguredRepoUrl -RepoUrl 'https://github.com/owner/repo.git' | Should -Be 'https://github.com/owner/repo'
    Resolve-GchConfiguredNonNegativeInteger -Value '0' -Key 'ShowAsPostponedWindowDays' | Should -Be 0
    Resolve-GchConfiguredNonNegativeInteger -Value 150 -Key 'ShowAsPostponedWindowDays' | Should -Be 150

    { Resolve-GchConfiguredRepoUrl -RepoUrl 'https://example.com/owner/repo' } | Should -Throw
    { Resolve-GchConfiguredNonNegativeInteger -Value -1 -Key 'ShowAsPostponedWindowDays' } | Should -Throw
  }

  It 'treats common disabled AutomaticUpdates values as falsy' {
    Test-GchFalsyValue -Value $false | Should -BeTrue
    Test-GchFalsyValue -Value 0 | Should -BeTrue
    Test-GchFalsyValue -Value 'false' | Should -BeTrue
    Test-GchFalsyValue -Value 'off' | Should -BeTrue
    Test-GchFalsyValue -Value $true | Should -BeFalse
  }

  It 'defaults missing disk format state to version 4 compatibility' {
    $tempRoot = Join-Path $env:TEMP ('gch-disk-format-state-' + [guid]::NewGuid().ToString())
    $statePath = Join-Path $tempRoot 'data\disk-format.psd1'

    try {
      $state = Read-DiskFormatState -Path $statePath

      $state.CurrentDiskFormat | Should -Be 4
      $state.LatestCompatibleCodeVersion | Should -Be 4
    } finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'writes and reads disk format state' {
    $tempRoot = Join-Path $env:TEMP ('gch-disk-format-state-' + [guid]::NewGuid().ToString())
    $statePath = Join-Path $tempRoot 'data\disk-format.psd1'

    try {
      Write-DiskFormatState -Path $statePath -CurrentDiskFormat 5 -LatestCompatibleCodeVersion 6
      $state = Read-DiskFormatState -Path $statePath

      $state.CurrentDiskFormat | Should -Be 5
      $state.LatestCompatibleCodeVersion | Should -Be 6
    } finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'parses migration manifests and selects migrations in ascending version order' {
    $tempRoot = Join-Path $env:TEMP ('gch-disk-format-migrations-' + [guid]::NewGuid().ToString())
    $migrationDir = Join-Path $tempRoot 'disk-format-migrations'
    $migration4 = Join-Path $migrationDir 'migrate-to-version-4.ps1'
    $migration6 = Join-Path $migrationDir 'migrate-to-version-6.ps1'

    try {
      New-Item -ItemType Directory -Path $migrationDir -Force | Out-Null
      @'
<#
.DESCRIPTION
Test migration.

.MANIFEST
ModifiedTopFolders = temp, config
NewTopFolders = data
#>
'@ | Set-Content -LiteralPath $migration4 -Encoding UTF8
      @'
<#
.DESCRIPTION
Test migration.

.MANIFEST
ModifiedTopFolders = log
NewTopFolders =
#>
'@ | Set-Content -LiteralPath $migration6 -Encoding UTF8

      $manifest = Read-DiskFormatMigrationManifest -ScriptPath $migration4
      $manifest.ModifiedTopFolders | Should -Be @('temp', 'config')
      $manifest.NewTopFolders | Should -Be @('data')

      $migrations = @(Get-DiskFormatMigrationScripts -MigrationDir $migrationDir -SourceDiskFormat 4 -TargetCodeVersion 6)
      $migrations.Count | Should -Be 1
      $migrations[0].Version | Should -Be 6
    } finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'runs disk format migrations, creates backups, and persists the final format' {
    $tempRoot = Join-Path $env:TEMP ('gch-disk-format-run-' + [guid]::NewGuid().ToString())
    $rootDir = Join-Path $tempRoot 'install'
    $releaseRoot = Join-Path $tempRoot 'release'
    $configDir = Join-Path $rootDir 'config'
    $binDir = Join-Path $rootDir 'bin'
    $migrationDir = Join-Path $releaseRoot 'disk-format-migrations'
    $migrationScript = Join-Path $migrationDir 'migrate-to-version-5.ps1'

    try {
      New-Item -ItemType Directory -Path $configDir, $binDir, $migrationDir -Force | Out-Null
      Set-Content -LiteralPath (Join-Path $configDir 'sample.txt') -Value 'before' -NoNewline
      Set-Content -LiteralPath (Join-Path $binDir 'Update-GetHealthCode.ps1') -Value '# updater' -NoNewline

      @'
<#
.DESCRIPTION
Creates the data folder.

.MANIFEST
ModifiedTopFolders = config
NewTopFolders = data
#>
$dataDir = Join-Path (Get-Location).Path 'data'
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
Set-Content -LiteralPath (Join-Path $dataDir 'created.txt') -Value 'created' -NoNewline
Write-Output ("PATH_TO_UPDATER={0}" -f (Join-Path (Get-Location).Path 'bin\Update-GetHealthCode.ps1'))
exit 0
'@ | Set-Content -LiteralPath $migrationScript -Encoding UTF8

      $result = Invoke-DiskFormatMigrations -RootDir $rootDir -ReleaseRoot $releaseRoot -TargetCodeVersion 'v5.0.0'
      $state = Read-DiskFormatState -Path (Join-Path $rootDir 'data\disk-format.psd1')

      $result.RanMigrations | Should -BeTrue
      $state.CurrentDiskFormat | Should -Be 5
      $state.LatestCompatibleCodeVersion | Should -Be 5
      Test-Path -LiteralPath (Join-Path $rootDir 'config.4-to-5.bak') -PathType Container | Should -BeTrue
      Test-Path -LiteralPath (Join-Path $rootDir 'data\created.txt') -PathType Leaf | Should -BeTrue
    } finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'restores modified folders and deletes new folders when a migration fails' {
    $tempRoot = Join-Path $env:TEMP ('gch-disk-format-fail-' + [guid]::NewGuid().ToString())
    $rootDir = Join-Path $tempRoot 'install'
    $releaseRoot = Join-Path $tempRoot 'release'
    $configDir = Join-Path $rootDir 'config'
    $migrationDir = Join-Path $releaseRoot 'disk-format-migrations'
    $migrationScript = Join-Path $migrationDir 'migrate-to-version-5.ps1'

    try {
      New-Item -ItemType Directory -Path $configDir, $migrationDir -Force | Out-Null
      Set-Content -LiteralPath (Join-Path $configDir 'sample.txt') -Value 'before' -NoNewline

      @'
<#
.DESCRIPTION
Fails after mutation.

.MANIFEST
ModifiedTopFolders = config
NewTopFolders = data
#>
Set-Content -LiteralPath (Join-Path (Get-Location).Path 'config\sample.txt') -Value 'after' -NoNewline
New-Item -ItemType Directory -Path (Join-Path (Get-Location).Path 'data') -Force | Out-Null
Write-Error 'Migration failed'
exit 2
'@ | Set-Content -LiteralPath $migrationScript -Encoding UTF8

      { Invoke-DiskFormatMigrations -RootDir $rootDir -ReleaseRoot $releaseRoot -TargetCodeVersion 'v5.0.0' } | Should -Throw
      Get-Content -LiteralPath (Join-Path $configDir 'sample.txt') -Raw | Should -Be 'before'
      Test-Path -LiteralPath (Join-Path $rootDir 'data') | Should -BeFalse
    } finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
