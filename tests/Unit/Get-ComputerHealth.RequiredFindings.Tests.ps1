Describe 'Get-ComputerHealth required findings' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $scriptPath = Join-Path $repoRoot 'Get-ComputerHealth.ps1'
    $script:GetComputerHealthScriptText = Get-Content -LiteralPath $scriptPath -Raw

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)

    foreach ($functionName in @(
        'Get-RequiredFindingConfigKeys',
        'Test-RequiredFindingConfigKey',
        'Get-RequiredFindingConfigValue',
        'Normalize-RequiredFindingTestName',
        'Convert-RequiredFindingEntryToHashtable',
        'Read-RequiredFindingsConfig',
        'ConvertTo-RequiredFindingsPowerShellString',
        'Save-RequiredFindingsConfig',
        'Set-RequiredFindingEntry',
        'Get-RequiredFindingsForTest',
        'Get-MissingRequiredFindings',
        'Invoke-RequiredFindingsValidation'
      )) {
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

  It 'declares the SetRequired parameter set and required findings config path' {
    $script:GetComputerHealthScriptText | Should -Match '\[Parameter\(ParameterSetName = ''SetRequired'', Mandatory\)\]\s*\r?\n\s*\[switch\]\$SetAsRequired'
    $script:GetComputerHealthScriptText | Should -Match 'RequiredFindingsPath = Join-Path \$CONFIG_DIR ''required_findings\.psd1'''
    $script:GetComputerHealthScriptText | Should -Match 'Invoke-RequiredFindingsValidation -FunctionName \$FunctionName -Records \$records -RequiredFindings \$script:RequiredFindings'
  }

  It 'reads required findings from psd1 and normalizes keys' {
    $tempRoot = Join-Path $env:TEMP ('gch-required-read-' + [guid]::NewGuid().ToString())
    $path = Join-Path $tempRoot 'required_findings.psd1'

    try {
      New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
      @'
@{
    'HealthTest-UnexpectedListeningPorts' = @{
        'BFC162FA' = @{Description = 'Port 443(IIS) should be listening but is not'; Ts = [datetime]'2025-11-01 12:42'; User = 'ndemou-admin'};
    };
}
'@ | Set-Content -LiteralPath $path -Encoding UTF8

      $config = Read-RequiredFindingsConfig -Path $path

      $config.Keys | Should -Contain 'UnexpectedListeningPorts'
      $config['UnexpectedListeningPorts'].Keys | Should -Contain 'bfc162fa'
      $config['UnexpectedListeningPorts']['bfc162fa'].Description | Should -Be 'Port 443(IIS) should be listening but is not'
      $config['UnexpectedListeningPorts']['bfc162fa'].Ts | Should -Be ([datetime]'2025-11-01 12:42')
      $config['UnexpectedListeningPorts']['bfc162fa'].User | Should -Be 'ndemou-admin'
    }
    finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'saves and updates required finding entries' {
    $tempRoot = Join-Path $env:TEMP ('gch-required-write-' + [guid]::NewGuid().ToString())
    $path = Join-Path $tempRoot 'required_findings.psd1'

    try {
      Set-RequiredFindingEntry -Path $path -TestName 'HealthTest-UnexpectedListeningPorts' -Signature 'BFC162FA' -Description 'Port 443(IIS) should be listening but is not' -Timestamp ([datetime]'2025-11-01 12:42') -User 'ndemou-admin'
      Set-RequiredFindingEntry -Path $path -TestName 'UnexpectedListeningPorts' -Signature '98c134de' -Description 'Port 80(IIS) should be listening but is not' -Timestamp ([datetime]'2025-11-01 12:43') -User 'ndemou-admin'

      $config = Read-RequiredFindingsConfig -Path $path

      (Test-Path -LiteralPath $path -PathType Leaf) | Should -BeTrue
      $config.Keys | Should -Be @('UnexpectedListeningPorts')
      $config['UnexpectedListeningPorts'].Keys | Should -Be @('98c134de', 'bfc162fa')
      $config['UnexpectedListeningPorts']['98c134de'].Description | Should -Be 'Port 80(IIS) should be listening but is not'
      $config['UnexpectedListeningPorts']['bfc162fa'].Description | Should -Be 'Port 443(IIS) should be listening but is not'
    }
    finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'resolves required findings by short or full health test name' {
    $requiredFindings = [ordered]@{
      UnexpectedListeningPorts = [ordered]@{
        bfc162fa = [ordered]@{ Description = 'Port 443(IIS) should be listening but is not'; Ts = [datetime]'2025-11-01 12:42'; User = 'ndemou-admin' }
      }
    }

    $byFullName = Get-RequiredFindingsForTest -RequiredFindings $requiredFindings -FunctionName 'HealthTest-UnexpectedListeningPorts'
    $byShortName = Get-RequiredFindingsForTest -RequiredFindings $requiredFindings -FunctionName 'UnexpectedListeningPorts'

    $byFullName.Keys | Should -Contain 'bfc162fa'
    $byShortName.Keys | Should -Contain 'bfc162fa'
  }

  It 'finds required signatures that were not emitted' {
    $requiredForTest = [ordered]@{
      'bfc162fa' = [ordered]@{ Description = 'Port 443(IIS) should be listening but is not'; Ts = [datetime]'2025-11-01 12:42'; User = 'ndemou-admin' }
      '98c134de' = [ordered]@{ Description = 'Port 80(IIS) should be listening but is not'; Ts = [datetime]'2025-11-01 12:42'; User = 'ndemou-admin' }
    }

    $missing = @(Get-MissingRequiredFindings -Records @(
        [pscustomobject]@{ Hash = '98c134de'; Message = 'Port 80(IIS) should be listening but is not' }
      ) -RequiredFindingsForTest $requiredForTest)

    $missing.Count | Should -Be 1
    $missing[0].Signature | Should -Be 'bfc162fa'
    $missing[0].Description | Should -Be 'Port 443(IIS) should be listening but is not'
  }

  It 'emits failure records for missing required findings' {
    function Log-Failure {
      param([Parameter(Mandatory)][string]$Msg, [string]$Comment = '', [string]$Emitter)
      [pscustomobject]@{
        Level = 'failure'
        Message = $Msg
        Comment = $Comment
        Emitter = $Emitter
      }
    }

    try {
      $results = @(Invoke-RequiredFindingsValidation -FunctionName 'HealthTest-UnexpectedListeningPorts' -Records @(
          [pscustomobject]@{
            Level = 'warning'
            Message = 'Port 80(IIS) should be listening but is not'
            Hash = '98c134de'
          }
        ) -RequiredFindings ([ordered]@{
            UnexpectedListeningPorts = [ordered]@{
              'bfc162fa' = [ordered]@{ Description = 'Port 443(IIS) should be listening but is not'; Ts = [datetime]'2025-11-01 12:42'; User = 'ndemou-admin' }
              '98c134de' = [ordered]@{ Description = 'Port 80(IIS) should be listening but is not'; Ts = [datetime]'2025-11-01 12:42'; User = 'ndemou-admin' }
            }
          }))

      $results.Count | Should -Be 2
      $results[1].Level | Should -Be 'failure'
      $results[1].Message | Should -Be 'Port 443(IIS) should be listening but is not'
      $results[1].Comment | Should -Be 'Required finding with signature bfc162fa was not emitted by UnexpectedListeningPorts'
      $results[1].Emitter | Should -Be 'HealthTest-UnexpectedListeningPorts'
    }
    finally {
      Remove-Item Function:\Log-Failure -ErrorAction SilentlyContinue
    }
  }
}
