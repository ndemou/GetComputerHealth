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
      'ConvertTo-GchHashtable',
      'Get-GchInstallConfigTemplateText',
      'Write-GchInstallConfigTemplate',
      'Get-GchInstallOption',
      'ConvertTo-GchPsd1Literal',
      'ConvertTo-GchPsd1Text',
      'Write-GchConfigFilesFromInstallConfig',
      'New-UpdateStagingDirectory',
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

  It 'creates a fresh staging directory for each update' {
    $savedTemp = $env:TEMP
    $tempRoot = Join-Path $TestDrive 'separate-stages'
    try {
      New-Item -ItemType Directory -Path $tempRoot | Out-Null
      $env:TEMP = $tempRoot
      $first = New-UpdateStagingDirectory
      $firstFile = Join-Path $first 'payload.txt'
      Set-Content -LiteralPath $firstFile -Value 'first update'

      $second = New-UpdateStagingDirectory

      $second | Should -Not -Be $first
      Split-Path -Parent $second | Should -Be $tempRoot
      Test-Path -LiteralPath $second -PathType Container | Should -BeTrue
      Get-Content -LiteralPath $firstFile | Should -Be 'first update'
    } finally {
      $env:TEMP = $savedTemp
    }
  }

  It 'installs a cached GitHub release across a self-rerun and backs up changed files' {
    $savedTemp = $env:TEMP
    $tempRoot = Join-Path $TestDrive 'staging'
    $installRoot = Join-Path $TestDrive 'installed'
    $packageRoot = Join-Path $TestDrive 'package'
    $packageContent = Join-Path $packageRoot 'GetComputerHealth-fixture'
    $installedUpdater = Join-Path $installRoot 'bin\Update-GetHealthCode.ps1'
    $packageUpdater = Join-Path $packageContent 'Update-GetHealthCode.ps1'
    $installedPayload = Join-Path $installRoot 'bin\payload[1].txt'
    $unchangedFile = Join-Path $installRoot 'bin\unchanged[1].txt'
    $unchangedTime = [datetime]::new(2020, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    $cachePath = Join-Path $installRoot 'config\Get-ComputerHealth-latest-release-meta.json'
    $zipPath = Join-Path $installRoot 'temp\GetComputerHealth-release-v8.0.0-1.zip'
    try {
      $directories = @($tempRoot, $packageContent)
      $directories += 'bin', 'config', 'data', 'temp' | ForEach-Object { Join-Path $installRoot $_ }
      New-Item -ItemType Directory -Path $directories -Force | Out-Null
      $env:TEMP = $tempRoot
      Copy-Item -LiteralPath $scriptPath -Destination $installedUpdater
      Copy-Item -LiteralPath $scriptPath -Destination $packageUpdater
      Add-Content -LiteralPath $packageUpdater -Value '# Self-rerun fixture'
      Set-Content -LiteralPath $installedPayload -Value 'old payload' -Encoding ASCII
      Set-Content -LiteralPath (Join-Path $packageContent 'payload[1].txt') -Value 'new payload' -Encoding ASCII
      Set-Content -LiteralPath $unchangedFile -Value 'same payload' -Encoding ASCII
      Copy-Item -LiteralPath $unchangedFile -Destination $packageContent
      [System.IO.File]::SetLastWriteTimeUtc($unchangedFile, $unchangedTime)
      Set-Content -LiteralPath (Join-Path $installRoot 'data\disk-format.psd1') -Value '@{ CurrentDiskFormat = 7; LatestCompatibleCodeVersion = 8 }'
      @{
        fetchedAt = (Get-Date).ToString('o')
        release = @{ id = 1; tag_name = 'v8.0.0'; zipball_url = 'https://example.invalid/unexpected-download' }
      } | ConvertTo-Json | Set-Content -LiteralPath $cachePath
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      [System.IO.Compression.ZipFile]::CreateFromDirectory($packageRoot, $zipPath)

      $messages = & $installedUpdater 6>&1 | ForEach-Object { [string]$_ }

      @($messages -like 'Timing: Release ZIP extraction*').Count | Should -Be 1
      @($messages -like '*Reusing staged release files*').Count | Should -Be 1
      @($messages -like 'Timing: * File replacement*').Count | Should -Be 2
      Get-Content -LiteralPath $installedPayload | Should -Be 'new payload'
      (Get-Item -LiteralPath $unchangedFile).LastWriteTimeUtc | Should -Be $unchangedTime
      $payloadBackup = Get-ChildItem -LiteralPath (Join-Path $installRoot 'temp') -Filter '*.bak' |
        Where-Object { $_.Name.StartsWith('payload[1].txt.') }
      @($payloadBackup).Count | Should -Be 1
      Get-Content -LiteralPath $payloadBackup.FullName | Should -Be 'old payload'
      (Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json).installedReleaseMarker | Should -Be 'ndemou/GetComputerHealth|v8.0.0|1'
      @(Get-ChildItem -LiteralPath $tempRoot -Force).Count | Should -Be 0
      @(Get-ChildItem -LiteralPath (Join-Path $installRoot 'log') -Filter 'Update-GetHealthCode-*.log').Count | Should -Be 2
    } finally {
      $env:TEMP = $savedTemp
    }
  }

  It 'writes customized installer config files as PowerShell data files' {
    $tempRoot = Join-Path $env:TEMP ('gch-install-config-test-' + [guid]::NewGuid().ToString())
    $installConfig = @{
      Options = @{
        InstallDir = 'C:\IT\GetComputerHealth'
      }
      ConfigFiles = @{
        'gch.psd1' = @{
          AutomaticUpdates = $false
          SendReports = 'Auto'
          IpsOfAllDCs = @('10.1.2.3', '10.1.2.4')
        }
        'Send-Message.psd1' = @{
          Server = 'smtp.contoso.com'
          From = 'SERVER01+alerts@contoso.com'
          To = 'ops@contoso.com;admin@contoso.com'
        }
      }
    }

    try {
      Get-GchInstallOption -InstallConfig $installConfig -Name 'InstallDir' | Should -Be 'C:\IT\GetComputerHealth'
      Write-GchConfigFilesFromInstallConfig -InstallConfig $installConfig -ConfigDirectory $tempRoot

      $gchConfig = Import-PowerShellDataFile -LiteralPath (Join-Path $tempRoot 'gch.psd1')
      $messageConfig = Import-PowerShellDataFile -LiteralPath (Join-Path $tempRoot 'Send-Message.psd1')

      $gchConfig.AutomaticUpdates | Should -BeFalse
      $gchConfig.SendReports | Should -Be 'Auto'
      $gchConfig.IpsOfAllDCs | Should -Be @('10.1.2.3', '10.1.2.4')
      $messageConfig.Server | Should -Be 'smtp.contoso.com'
    } finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'rejects unsafe customized installer config file names' {
    $installConfig = @{
      ConfigFiles = @{
        '..\gch.psd1' = @{
          AutomaticUpdates = $true
        }
      }
    }

    { Write-GchConfigFilesFromInstallConfig -InstallConfig $installConfig -ConfigDirectory $env:TEMP } | Should -Throw
  }

  It 'generates an installer configuration template that can be imported' {
    $tempRoot = Join-Path $env:TEMP ('gch-install-template-test-' + [guid]::NewGuid().ToString())
    $templatePath = Join-Path $tempRoot 'GetComputerHealth.install.psd1'

    try {
      $writtenPath = Write-GchInstallConfigTemplate -Path $templatePath
      $templateConfig = ConvertTo-GchHashtable -Value $writtenPath

      Test-Path -LiteralPath $writtenPath -PathType Leaf | Should -BeTrue
      Get-GchInstallOption -InstallConfig $templateConfig -Name 'InstallDir' | Should -Be 'C:\IT\GetComputerHealth'
      Test-GchConfigKey -Config (Get-GchConfigValue -Config $templateConfig -Key 'ConfigFiles') -Key 'gch.psd1' | Should -BeTrue
    } finally {
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
      Test-Path -LiteralPath (Join-Path $rootDir 'config\4-to-5.bak') -PathType Container | Should -BeTrue
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
