Describe 'SuppressRepeats findings' {
  BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $script:RepoRoot 'lib-write-log-objects.ps1')
    . (Join-Path $script:RepoRoot 'lib-suppress-repeats.ps1')
    . (Join-Path $script:RepoRoot 'health-tests\helpers-for-healthtests.ps1')
    . (Join-Path $script:RepoRoot 'reporting.ps1')
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'Get-ComputerHealth.ps1'), [ref]$tokens, [ref]$parseErrors)
    foreach ($name in @('Convert-TextToLogRecord', 'Convert-WarningLikeObjectToLogRecord', 'Write-HealthFinding', 'Invoke-HealthTest', 'Get-HealthTestTagsMetadata')) {
      $functionAst = $ast.Find({ param($node)
          $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
      . ([scriptblock]::Create($functionAst.Extent.Text))
    }
    $wrapperAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'Invoke-GetComputerHealth.ps1'), [ref]$tokens, [ref]$parseErrors)
    $blockAssignment = $wrapperAst.Find({ param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$healthCheckBlock'
      }, $true)
    . ([scriptblock]::Create($blockAssignment.Extent.Text))
    $script:TargetBlock = $healthCheckBlock
  }

  BeforeEach {
    $script:StatePath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '\state\suppress_repeats.json')
    $script:Config = [pscustomobject]@{ RepeatSuppressionPath = $script:StatePath }
    $script:StartTime = [datetimeoffset]'2026-01-01T12:00:00Z'
    $script:ExcludeTests = @()
    Initialize-LogSystem -OutputConsoleMessages $false
    Set-LogConfig -SuppressedSignatures @()
  }

  It 'removes the marker before signing the description and keeps details separate' {
    $plain = Convert-WarningLikeObjectToLogRecord '[FAILURE] Task failed at 2026-10-18 20:03:03'
    $marked = Convert-WarningLikeObjectToLogRecord "[FAILURE][SuppressRepeats] Task failed at 2026-10-18 20:03:03`nDetail one"
    $marked.SuppressRepeats | Should -BeTrue
    $marked.Level | Should -Be 'failure'
    $marked.Msg | Should -Be $plain.Msg
    $marked.Comment | Should -Be 'Detail one'
    (Get-StringSignature $marked.Msg) | Should -Be (Get-StringSignature $plain.Msg)
    $plain.SuppressRepeats | Should -BeFalse
  }

  It 'only enables repeat handling for actionable levels' -ForEach @(
    @{ Level = 'NOTICE'; Enabled = $true }, @{ Level = 'WARNING'; Enabled = $true },
    @{ Level = 'FAILURE'; Enabled = $true }, @{ Level = 'PASS'; Enabled = $false },
    @{ Level = 'INFO'; Enabled = $false }, @{ Level = 'DEBUG'; Enabled = $false }
  ) {
    $record = Convert-WarningLikeObjectToLogRecord "[$Level][SuppressRepeats] Example"
    $record.SuppressRepeats | Should -Be $Enabled
    $record.Msg | Should -Be 'Example'
  }

  It 'shows the first observation and suppresses monthly repeats while preserving the first timestamp' {
    $first = Update-RepeatSuppressionState -Path $script:StatePath -TestName 'TestA' -Hash '1234abcd' -NowUtc $script:StartTime
    $first.Suppressed | Should -BeFalse
    foreach ($month in 1..4) {
      $now = $script:StartTime.AddMonths($month)
      $repeat = Update-RepeatSuppressionState -Path $script:StatePath -TestName 'TestA' -Hash '1234abcd' -NowUtc $now
      $repeat.Suppressed | Should -BeTrue
      $repeat.FirstSeenUtc | Should -Be $first.FirstSeenUtc
      ([datetimeoffset]$repeat.LastSeenUtc) | Should -Be $now
    }
    $stored = Get-Content $script:StatePath -Raw | ConvertFrom-Json
    @($stored).Count | Should -Be 1
    $stored[0].FirstSeenUtc | Should -Be $first.FirstSeenUtc
    $stored[0].LastSeenUtc | Should -Be $repeat.LastSeenUtc
  }

  It 'expires at exactly 45 days since the last observation' -ForEach @(
    @{ Days = 44; Expected = $true }, @{ Days = 45; Expected = $false }, @{ Days = 46; Expected = $false }
  ) {
    $null = Update-RepeatSuppressionState -Path $script:StatePath -TestName 'TestA' -Hash '1234abcd' -NowUtc $script:StartTime
    $result = Update-RepeatSuppressionState -Path $script:StatePath -TestName 'TestA' -Hash '1234abcd' -NowUtc $script:StartTime.AddDays($Days)
    $result.Suppressed | Should -Be $Expected
  }

  It 'keeps findings independent by test, signature, and target state path' {
    $null = Update-RepeatSuppressionState -Path $script:StatePath -TestName 'TestA' -Hash '1234abcd' -NowUtc $script:StartTime
    $otherTest = Update-RepeatSuppressionState -Path $script:StatePath -TestName 'TestB' -Hash '1234abcd' -NowUtc $script:StartTime
    $otherFinding = Update-RepeatSuppressionState -Path $script:StatePath -TestName 'TestA' -Hash '5678abcd' -NowUtc $script:StartTime
    $otherTarget = Update-RepeatSuppressionState -Path ($script:StatePath + '.other.json') -TestName 'TestA' -Hash '1234abcd' -NowUtc $script:StartTime
    $otherTest.Suppressed | Should -BeFalse
    $otherFinding.Suppressed | Should -BeFalse
    $otherTarget.Suppressed | Should -BeFalse
    $stored = Get-Content $script:StatePath -Raw | ConvertFrom-Json
    @($stored).Count | Should -Be 3
    $original = $stored | Where-Object { $_.TestName -eq 'TestA' -and $_.Hash -eq '1234abcd' }
    ([datetimeoffset]$original.LastSeenUtc) | Should -Be $script:StartTime
  }

  It 'does not hide a finding based on an observation in the future' {
    $null = Update-RepeatSuppressionState -Path $script:StatePath -TestName 'TestA' -Hash '1234abcd' -NowUtc $script:StartTime.AddDays(1)
    $result = Update-RepeatSuppressionState -Path $script:StatePath -TestName 'TestA' -Hash '1234abcd' -NowUtc $script:StartTime
    $result.Suppressed | Should -BeFalse
    $result.FirstSeenUtc | Should -Be $result.LastSeenUtc
  }

  It 'shows the first finding in both console and objects and hides subsequent console repeats with Hide S' {
    Set-LogConfig -OutputConsoleMessages $true -HideStr 'DIPS'
    $script:ConsoleText = @()
    Mock Write-Host { $script:ConsoleText += [string]$Object }
    $record = Convert-WarningLikeObjectToLogRecord '[WARNING][SuppressRepeats] Unique failed execution'
    $first = Write-HealthFinding -Record $record -Emitter 'TestA'
    $first.Suppressed | Should -BeFalse
    $first.SuppressRepeats | Should -BeTrue
    $first.SuppressionSource | Should -Be ''
    ($script:ConsoleText -join '') | Should -Match 'Unique failed execution'
    $script:ConsoleText = @()
    $repeat = Write-HealthFinding -Record $record -Emitter 'TestA'
    $repeat.Suppressed | Should -BeTrue
    $repeat.SuppressionSource | Should -Be 'SuppressRepeats'
    $repeat.Hash | Should -Be $first.Hash
    $script:ConsoleText.Count | Should -Be 0
  }

  It 'does not notify again for changes only in details or severity' {
    $first = Write-HealthFinding -Record (Convert-WarningLikeObjectToLogRecord '[WARNING][SuppressRepeats] Same event') -Emitter 'TestA'
    $repeat = Write-HealthFinding -Record (Convert-WarningLikeObjectToLogRecord "[FAILURE][SuppressRepeats] Same event`nNew details") -Emitter 'TestA'
    $repeat.Suppressed | Should -BeTrue
    $repeat.Level | Should -Be 'failure'
    $repeat.Comment | Should -Be 'New details'
    $repeat.Hash | Should -Be $first.Hash
    $newRun = Write-HealthFinding -Record (Convert-WarningLikeObjectToLogRecord '[FAILURE][SuppressRepeats] Different event') -Emitter 'TestA'
    $newRun.Suppressed | Should -BeFalse
  }

  It 'preserves configured suppression and observes the finding while it is configured' {
    $configPath = Join-Path $TestDrive 'manual-suppressions.txt'
    $record = Convert-WarningLikeObjectToLogRecord '[WARNING][SuppressRepeats] Known event'
    $hash = Get-StringSignature $record.Msg
    Set-Content $configPath "$hash until 2999-12-31" -Encoding ASCII
    $before = Get-Content $configPath -Raw
    Initialize-LogSystem -OutputConsoleMessages $false -SuppressionFilePath $configPath
    $first = Write-HealthFinding -Record $record -Emitter 'TestA'
    $first.SuppressionSource | Should -Be 'Configured'
    $first.LastSeenUtc | Should -Not -BeNullOrEmpty
    Set-LogConfig -SuppressedSignatures @()
    $second = Write-HealthFinding -Record $record -Emitter 'TestA'
    $second.SuppressionSource | Should -Be 'SuppressRepeats'
    (Get-Content $configPath -Raw) | Should -Be $before
  }

  It 'does not create state for ordinary findings' {
    $record = Convert-WarningLikeObjectToLogRecord '[FAILURE] Failed to collect task facts'
    $first = Write-HealthFinding -Record $record -Emitter 'TestA'
    $second = Write-HealthFinding -Record $record -Emitter 'TestA'
    $first.Suppressed | Should -BeFalse
    $second.Suppressed | Should -BeFalse
    Test-Path $script:StatePath | Should -BeFalse
  }

  It 'reports corrupt state without hiding the finding or replacing the file' {
    $null = New-Item (Split-Path -Parent $script:StatePath) -ItemType Directory -Force
    Set-Content $script:StatePath '{broken' -Encoding ASCII
    $record = Convert-WarningLikeObjectToLogRecord '[FAILURE][SuppressRepeats] Failed execution'
    $output = @(Write-HealthFinding -Record $record -Emitter 'TestA')
    $output.Count | Should -Be 2
    $output[0].Message | Should -Match 'Could not update SuppressRepeats state'
    $output[0].SuppressRepeats | Should -BeFalse
    $output[1].Suppressed | Should -BeFalse
    (Get-Content $script:StatePath -Raw).Trim() | Should -Be '{broken'
  }

  It 'reports unavailable state without losing observations or hiding the finding' -ForEach @(
    @{ LockContent = $false }, @{ LockContent = $true }
  ) {
    $record = Convert-WarningLikeObjectToLogRecord '[FAILURE][SuppressRepeats] Failed execution'
    $null = Write-HealthFinding -Record $record -Emitter 'TestA'
    $before = Get-Content $script:StatePath -Raw
    $lockedPath = if ($LockContent) { $script:StatePath } else { $script:StatePath + '.lock' }
    $lock = [IO.File]::Open($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
      $output = @(Write-HealthFinding -Record $record -Emitter 'TestA')
      $output.Count | Should -Be 2
      $output[1].Suppressed | Should -BeFalse
      (Get-Content $script:StatePath -Raw) | Should -Be $before
    }
    finally { $lock.Dispose() }
  }

  It 'keeps a mixed health test selective across repeated runs' {
    function HealthTest-RepeatFixture {
      Write-Warning '[FAILURE][SuppressRepeats] A particular failed execution'
      Write-Warning '[WARNING] A disabled task'
    }
    Mock Get-HealthTestTagsMetadata { [pscustomobject]@{ Tags = @(); TestName = 'RepeatFixture' } }
    $first = @(Invoke-HealthTest 'HealthTest-RepeatFixture' | Where-Object { $_.Level -in @('failure', 'warning') })
    $second = @(Invoke-HealthTest 'HealthTest-RepeatFixture' | Where-Object { $_.Level -in @('failure', 'warning') })
    $first.Count | Should -Be 2
    $first[0].Suppressed | Should -BeFalse
    $second[0].SuppressionSource | Should -Be 'SuppressRepeats'
    $second[1].Suppressed | Should -BeFalse
  }

  It 'keeps automatic repeats out of Postponed even with a large reminder window' {
    $today = [datetime]'2026-01-01'
    Get-HealthEffectiveLevel -Level warning -Suppressed $true -SuppressedUntil $today.AddDays(45) -ShowAsPostponedWindowDays 150 -Today $today -SuppressionSource 'SuppressRepeats' | Should -Be 'warning'
    Get-HealthEffectiveLevel -Level warning -Suppressed $true -SuppressedUntil $today.AddDays(45) -ShowAsPostponedWindowDays 150 -Today $today -SuppressionSource 'Configured' | Should -Be 'postponed'
  }

  It 'identifies suppression by the inventory tag for legacy log objects' {
    function HealthTest-RepeatFixture { Log-Notice 'Known inventory' }
    Mock Get-HealthTestTagsMetadata { [pscustomobject]@{ Tags = @('Suppressed'); TestName = 'RepeatFixture' } }
    $record = Invoke-HealthTest 'HealthTest-RepeatFixture' | Where-Object { $_.Message -eq 'Known inventory' }
    $record.Suppressed | Should -BeTrue
    $record.SuppressionSource | Should -Be 'SuppressedTag'
    $record.SuppressRepeats | Should -BeFalse
    Test-Path $script:StatePath | Should -BeFalse
  }

  It 'preserves state and metadata through the target runner, serialization, and report exports' {
    $targetRoot = Join-Path $TestDrive 'target'
    $bin = Join-Path $targetRoot 'bin'
    $healthTests = Join-Path $bin 'health-tests'
    $null = New-Item $healthTests -ItemType Directory -Force
    foreach ($name in @('Get-ComputerHealth.ps1', 'lib-write-log-objects.ps1', 'lib-suppress-repeats.ps1')) {
      Copy-Item (Join-Path $script:RepoRoot $name) (Join-Path $bin $name)
    }
    Copy-Item (Join-Path $script:RepoRoot 'health-tests\helpers-for-healthtests.ps1') $healthTests
    @'
function HealthTest-RepeatFixture {
<#
Description: Repeat finding fixture.
AppliesTo: All
Scope: Computer
Category: Test
Impact: low
#>
  Write-Warning '[FAILURE][SuppressRepeats] A specific failed execution'
}
'@ | Set-Content (Join-Path $healthTests 'HealthTest-RepeatFixture.ps1') -Encoding ASCII
    $payload = @{
      RootDir = $targetRoot
      WrapperState = @{ NoUpdate = $true; PushUpdate = $false; UpdateZipPath = ''; UpdateZipVersion = ''; ShowAsPostponedWindowDays = 150 }
      ChildHealthParams = @{ OutputObjects = $true; RunWithoutElevation = $true; OnlyTheseTests = @('HealthTest-RepeatFixture') }
    }
    $first = @(& $script:TargetBlock -Payload $payload | Where-Object { $_.Emitter -eq 'HealthTest-RepeatFixture' })
    $second = @(& $script:TargetBlock -Payload $payload | Where-Object { $_.Emitter -eq 'HealthTest-RepeatFixture' })
    $first.Count | Should -Be 1
    $first[0].Suppressed | Should -BeFalse
    $second.Count | Should -Be 1
    $second[0].SuppressRepeats | Should -BeTrue
    $second[0].SuppressionSource | Should -Be 'SuppressRepeats'
    $second[0].EffectiveLevel | Should -Be 'failure'
    $second[0].SuppressedUntil | Should -BeNullOrEmpty
    Test-Path (Join-Path $targetRoot 'state\suppress_repeats.json') | Should -BeTrue
    $remoteCopy = [Management.Automation.PSSerializer]::Deserialize([Management.Automation.PSSerializer]::Serialize($second))
    $exportPath = Join-Path $TestDrive 'repeat-report.clixml'
    Export-HealthMessagesReportData -Messages $remoteCopy -FileName $exportPath
    $rows = @(Import-Clixml $exportPath)
    $interactive = @(Convert-HealthReportRowsToInteractiveRows -Rows $rows)
    $interactive[0].SuppressRepeats | Should -BeTrue
    $interactive[0].SuppressionSource | Should -Be 'SuppressRepeats'
    $interactive[0].FirstSeenUtc | Should -Be $rows[0].FirstSeenUtc
    $interactive[0].LastSeenUtc | Should -Not -BeNullOrEmpty
    $interactive[0].Message | Should -Be 'A specific failed execution'
  }
}
