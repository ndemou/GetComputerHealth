Describe 'Update-GetHealthCode legacy layout migration' {
  BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:UpdateScriptPath = Join-Path $script:RepoRoot 'Update-GetHealthCode.ps1'
    $script:UpdateScriptText = Get-Content -LiteralPath $script:UpdateScriptPath -Raw

    $helperBlockMatch = [regex]::Match(
      $script:UpdateScriptText,
      '(?ms)^function Write-UpdateEvent .*?^#\s+HELPER FUNCTIONS END',
      [System.Text.RegularExpressions.RegexOptions]::Multiline
    )

    if (-not $helperBlockMatch.Success) {
      throw "Could not extract helper functions from $script:UpdateScriptPath"
    }

    . ([scriptblock]::Create($helperBlockMatch.Value))
  }

  BeforeEach {
    $script:TestRoot = Join-Path $env:TEMP ('gch-legacy-migration-' + [guid]::NewGuid().ToString())
    $null = New-Item -ItemType Directory -Path $script:TestRoot -Force
    $script:LogDir = Join-Path $script:TestRoot 'logs'
    $null = New-Item -ItemType Directory -Path $script:LogDir -Force
    $script:UPDATE_LOG_PATH = Join-Path $script:LogDir 'Update-GetHealthCode.log'
    $script:LOG_DIR = $script:LogDir
  }

  AfterEach {
    if ($script:TestRoot -and (Test-Path -LiteralPath $script:TestRoot)) {
      Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'detects only legacy v3 installs with the required suppressions file' {
    $legacyRoot = Join-Path $script:TestRoot 'legacy-root'
    $legacyBin = Join-Path $legacyRoot 'bin'
    $legacyConfig = Join-Path $legacyRoot 'config'
    $null = New-Item -ItemType Directory -Path $legacyBin, $legacyConfig -Force

    '$VERSION="3.9.1"' | Out-File -LiteralPath (Join-Path $legacyBin 'Get-ComputerHealth.ps1') -Encoding UTF8
    '# suppressions' | Out-File -LiteralPath (Join-Path $legacyConfig 'Get-ComputerHealth.sigs-to-suppress.txt') -Encoding UTF8

    Test-GetComputerHealthLegacyRootMigrationNeeded -ScriptBinDir $legacyBin -LegacyRootDir $legacyRoot | Should -BeTrue

    '$VERSION="4.0.0"' | Out-File -LiteralPath (Join-Path $legacyBin 'Get-ComputerHealth.ps1') -Encoding UTF8
    Test-GetComputerHealthLegacyRootMigrationNeeded -ScriptBinDir $legacyBin -LegacyRootDir $legacyRoot | Should -BeFalse

    '$VERSION="3.9.1"' | Out-File -LiteralPath (Join-Path $legacyBin 'Get-ComputerHealth.ps1') -Encoding UTF8
    Remove-Item -LiteralPath (Join-Path $legacyConfig 'Get-ComputerHealth.sigs-to-suppress.txt') -Force
    Test-GetComputerHealthLegacyRootMigrationNeeded -ScriptBinDir $legacyBin -LegacyRootDir $legacyRoot | Should -BeFalse
  }

  It 'moves and copies legacy project files into the Get-ComputerHealth subdirectory' {
    $legacyRoot = Join-Path $script:TestRoot 'legacy-root'
    $targetRoot = Join-Path $legacyRoot 'Get-ComputerHealth'
    $legacyBin = Join-Path $legacyRoot 'bin'
    $legacyConfig = Join-Path $legacyRoot 'config'
    $legacyLog = Join-Path $legacyRoot 'log'
    $legacyTemp = Join-Path $legacyRoot 'temp'
    $null = New-Item -ItemType Directory -Path $legacyBin, $legacyConfig, $legacyLog, $legacyTemp -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $legacyBin 'health-tests'), (Join-Path $legacyConfig 'Custom-HealthTests') -Force

    '$VERSION="3.9.1"' | Out-File -LiteralPath (Join-Path $legacyBin 'Get-ComputerHealth.ps1') -Encoding UTF8
    'invoke' | Out-File -LiteralPath (Join-Path $legacyBin 'Invoke-GetComputerHealth.ps1') -Encoding UTF8
    'log helpers' | Out-File -LiteralPath (Join-Path $legacyBin 'lib-write-log-objects.ps1') -Encoding UTF8
    'updater' | Out-File -LiteralPath (Join-Path $legacyBin 'Update-GetHealthCode.ps1') -Encoding UTF8
    'readme' | Out-File -LiteralPath (Join-Path $legacyBin 'README.md') -Encoding UTF8
    'send helper' | Out-File -LiteralPath (Join-Path $legacyBin 'Send-Message.ps1') -Encoding UTF8
    'custom helper' | Out-File -LiteralPath (Join-Path $legacyBin 'helpers-for-custom-ht.ps1') -Encoding UTF8
    'network helper' | Out-File -LiteralPath (Join-Path $legacyBin 'helpers-networking.ps1') -Encoding UTF8
    'process helper' | Out-File -LiteralPath (Join-Path $legacyBin 'helpers-processes.ps1') -Encoding UTF8
    @'
& C:\IT\bin\Update-GetHealthCode.ps1
& C:\IT\bin\Invoke-GetComputerHealth.ps1 -Computers "ALL_DOMAIN_SERVERS"
'@ | Out-File -LiteralPath (Join-Path $legacyBin 'Invoke-GetHealthDomainComputers.ps1') -Encoding UTF8
    'health test body' | Out-File -LiteralPath (Join-Path $legacyBin 'health-tests\sample.ps1') -Encoding UTF8
    '# suppressions' | Out-File -LiteralPath (Join-Path $legacyConfig 'Get-ComputerHealth.sigs-to-suppress.txt') -Encoding UTF8
    'custom script' | Out-File -LiteralPath (Join-Path $legacyConfig 'Custom-HealthTests\example.ps1') -Encoding UTF8
    'alert config' | Out-File -LiteralPath (Join-Path $legacyConfig 'send-alert.conf') -Encoding UTF8
    'mail config' | Out-File -LiteralPath (Join-Path $legacyConfig 'Send-Message.conf') -Encoding UTF8
    'old invoke log' | Out-File -LiteralPath (Join-Path $legacyLog 'Invoke-GetHealthDomainComputers-2026-05-06.log') -Encoding UTF8
    'old update log' | Out-File -LiteralPath (Join-Path $legacyLog 'Update-GetHealthCode-2026-05-06.log') -Encoding UTF8
    'sheet' | Out-File -LiteralPath (Join-Path $legacyTemp 'notable-messages-2026-05-06.xlsx') -Encoding UTF8
    'bak' | Out-File -LiteralPath (Join-Path $legacyTemp 'GetComputerHealth.bak') -Encoding UTF8
    'zip' | Out-File -LiteralPath (Join-Path $legacyTemp 'samplehealth.zip') -Encoding UTF8

    $migration = Move-GetComputerHealthLegacyInstallLayout -LegacyRootDir $legacyRoot -TargetRootDir $targetRoot -CurrentUpdateFromZipPath (Join-Path $legacyTemp 'samplehealth.zip')

    Test-Path -LiteralPath (Join-Path $targetRoot 'bin\Get-ComputerHealth.ps1') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $targetRoot 'bin\health-tests\sample.ps1') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $targetRoot 'config\Custom-HealthTests\example.ps1') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $targetRoot 'config\Get-ComputerHealth.sigs-to-suppress.txt') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $targetRoot 'config\send-alert.conf') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $targetRoot 'config\Send-Message.conf') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $targetRoot 'log\Invoke-GetHealthDomainComputers-2026-05-06.log') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $targetRoot 'temp\samplehealth.zip') | Should -BeTrue

    Test-Path -LiteralPath (Join-Path $legacyRoot 'bin\Get-ComputerHealth.ps1') | Should -BeFalse
    Test-Path -LiteralPath (Join-Path $legacyRoot 'config\Custom-HealthTests') | Should -BeFalse
    Test-Path -LiteralPath (Join-Path $legacyRoot 'config\Get-ComputerHealth.sigs-to-suppress.txt') | Should -BeFalse
    Test-Path -LiteralPath (Join-Path $legacyRoot 'temp\samplehealth.zip') | Should -BeFalse

    Test-Path -LiteralPath (Join-Path $legacyRoot 'bin\Send-Message.ps1') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $legacyRoot 'config\send-alert.conf') | Should -BeTrue

    $legacyDomainScriptContent = Get-Content -LiteralPath (Join-Path $legacyRoot 'bin\Invoke-GetHealthDomainComputers.ps1') -Raw
    $legacyDomainScriptContent | Should -Match ([regex]::Escape('C:\IT\Get-ComputerHealth\bin\Update-GetHealthCode.ps1'))
    $legacyDomainScriptContent | Should -Match ([regex]::Escape('C:\IT\Get-ComputerHealth\bin\Invoke-GetComputerHealth.ps1'))
    $legacyDomainScriptContent | Should -Not -Match ([regex]::Escape('C:\IT\bin\Update-GetHealthCode.ps1'))
    $legacyDomainScriptContent | Should -Not -Match ([regex]::Escape('C:\IT\bin\Invoke-GetComputerHealth.ps1'))

    $migration.RerunScriptPath | Should -Be (Join-Path $targetRoot 'bin\Update-GetHealthCode.ps1')
    $migration.UpdateFromZipPath | Should -Be (Join-Path $targetRoot 'temp\samplehealth.zip')
  }

  It 'copies an external UpdateFromZip into the migrated temp folder for the rerun' {
    $legacyRoot = Join-Path $script:TestRoot 'legacy-root'
    $targetRoot = Join-Path $legacyRoot 'Get-ComputerHealth'
    $legacyBin = Join-Path $legacyRoot 'bin'
    $legacyConfig = Join-Path $legacyRoot 'config'
    $externalDir = Join-Path $script:TestRoot 'external'
    $null = New-Item -ItemType Directory -Path $legacyBin, $legacyConfig, $externalDir -Force

    '$VERSION="3.9.1"' | Out-File -LiteralPath (Join-Path $legacyBin 'Get-ComputerHealth.ps1') -Encoding UTF8
    '# suppressions' | Out-File -LiteralPath (Join-Path $legacyConfig 'Get-ComputerHealth.sigs-to-suppress.txt') -Encoding UTF8
    'updater' | Out-File -LiteralPath (Join-Path $legacyBin 'Update-GetHealthCode.ps1') -Encoding UTF8
    $externalZip = Join-Path $externalDir 'GetComputerHealth-test.zip'
    'zip body' | Out-File -LiteralPath $externalZip -Encoding UTF8

    $migration = Move-GetComputerHealthLegacyInstallLayout -LegacyRootDir $legacyRoot -TargetRootDir $targetRoot -CurrentUpdateFromZipPath $externalZip

    $migration.UpdateFromZipPath | Should -Be (Join-Path $targetRoot 'temp\GetComputerHealth-test.zip')
    Test-Path -LiteralPath $migration.UpdateFromZipPath | Should -BeTrue
    Test-Path -LiteralPath $externalZip | Should -BeTrue
  }
}
