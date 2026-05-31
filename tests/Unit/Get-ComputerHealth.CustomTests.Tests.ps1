Describe 'Get-ComputerHealth custom test scripts' {
  BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:GetComputerHealthScript = Join-Path $script:RepoRoot 'Get-ComputerHealth.ps1'
  }

  It 'runs a custom script selected by full path and adds script reference metadata' {
    $tempRoot = Join-Path $env:TEMP ('gch-custom-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $customScriptPath = Join-Path $tempRoot 'full-path-test.ps1'

    try {
      @'
Write-Warning "[PASS] Full path custom test worked"
'@ | Set-Content -LiteralPath $customScriptPath -Encoding ASCII
      $expectedScriptPath = (Get-Item -LiteralPath $customScriptPath -ErrorAction Stop).FullName

      $records = @(
        & $script:GetComputerHealthScript `
          -RunWithoutElevation `
          -OutputObjects `
          -OnlyTheseTests $customScriptPath
      )

      $passRecord = $records | Where-Object { $_.Level -eq 'pass' -and $_.Message -eq 'Full path custom test worked' } | Select-Object -First 1
      $passRecord | Should -Not -BeNullOrEmpty
      $passRecord.Emitter | Should -Be $expectedScriptPath
      $passRecord.Comment | Should -Match ([regex]::Escape("(see custom test '$expectedScriptPath')"))
    }
    finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'runs a custom script selected by relative path from the caller location' {
    $tempRoot = Join-Path $env:TEMP ('gch-custom-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $customScriptPath = Join-Path $tempRoot 'relative-test.ps1'
    $oldLocation = Get-Location

    try {
      @'
Write-Warning "[PASS] Relative path custom test worked"
'@ | Set-Content -LiteralPath $customScriptPath -Encoding ASCII

      Set-Location -LiteralPath $tempRoot
      $records = @(
        & $script:GetComputerHealthScript `
          -RunWithoutElevation `
          -OutputObjects `
          -OnlyTheseTests '.\relative-test.ps1'
      )

      @($records | Where-Object { $_.Level -eq 'pass' -and $_.Message -eq 'Relative path custom test worked' }).Count | Should -Be 1
    }
    finally {
      Set-Location -LiteralPath $oldLocation
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'runs a custom script selected by file name when IncludeTestsFromFolder is supplied' {
    $tempRoot = Join-Path $env:TEMP ('gch-custom-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $customScriptPath = Join-Path $tempRoot 'legacy-object-test.ps1'

    try {
      @'
Write-Output ([pscustomobject]@{
  TimeUtc    = [DateTimeOffset]::UtcNow
  Computer   = $env:COMPUTERNAME
  Level      = 'notice'
  Hash       = '12345678'
  Suppressed = $false
  Message    = 'Legacy custom object worked'
  Comment    = ''
  Emitter    = 'placeholder'
})
'@ | Set-Content -LiteralPath $customScriptPath -Encoding ASCII
      $expectedScriptPath = (Get-Item -LiteralPath $customScriptPath -ErrorAction Stop).FullName

      $records = @(
        & $script:GetComputerHealthScript `
          -RunWithoutElevation `
          -OutputObjects `
          -IncludeTestsFromFolder $tempRoot `
          -OnlyTheseTests 'legacy-object-test.ps1'
      )

      $record = $records | Where-Object { $_.Level -eq 'notice' -and $_.Message -eq 'Legacy custom object worked' } | Select-Object -First 1
      $record | Should -Not -BeNullOrEmpty
      $record.Emitter | Should -Be $expectedScriptPath
      $record.Comment | Should -Match ([regex]::Escape("(see custom test '$expectedScriptPath')"))
    }
    finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'accepts the legacy ScriptPath alias when invoking custom scripts from a folder' {
    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:GetComputerHealthScript, [ref]$tokens, [ref]$parseErrors)
    $funcAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Invoke-HealthTestsFromFolder'
      }, $true)

    $funcAst | Should -Not -BeNullOrEmpty
    . ([scriptblock]::Create($funcAst.Extent.Text))

    $command = Get-Command Invoke-HealthTestsFromFolder -ErrorAction Stop

    $command.Parameters.ContainsKey('FolderPath') | Should -BeTrue
    $command.Parameters['FolderPath'].Aliases | Should -Contain 'ScriptPath'
  }

  It 'skips custom test entries whose script path cannot be determined' {
    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:GetComputerHealthScript, [ref]$tokens, [ref]$parseErrors)
    $funcAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Invoke-HealthTestsFromFolder'
      }, $true)

    $funcAst | Should -Not -BeNullOrEmpty
    . ([scriptblock]::Create($funcAst.Extent.Text))
    $script:InvokedScriptPaths = @()
    $script:WarningMessages = @()
    $script:InfoMessages = @()

    function Get-CustomHealthTestFilesFromPath {
      param([string]$Path)
      @(
        'C:\CustomTests\alpha.ps1'
        [pscustomobject]@{ FullName = '' }
        [pscustomobject]@{ Name = 'missing-full-name' }
      )
    }
    function Invoke-CustomHealthTestScript {
      param([string]$ScriptPath)
      $script:InvokedScriptPaths += $ScriptPath
    }
    function Log-Warning {
      param([string]$Message)
      $script:WarningMessages += $Message
    }
    function Log-Info {
      param([string]$Message)
      $script:InfoMessages += $Message
    }

    Invoke-HealthTestsFromFolder -FolderPath 'C:\CustomTests'

    $script:InvokedScriptPaths | Should -Be @('C:\CustomTests\alpha.ps1')
    $script:WarningMessages.Count | Should -Be 2
  }
}
