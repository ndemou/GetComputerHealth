Describe 'Invoke-GetComputerHealth notable subject selection' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $scriptPath = Join-Path $repoRoot 'Invoke-GetComputerHealth.ps1'

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)

    $funcAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-HealthNotableSubject'
      }, $true)

    if ($null -eq $funcAst) {
      throw "Function not found in ${scriptPath}: Get-HealthNotableSubject"
    }

    . ([scriptblock]::Create($funcAst.Extent.Text))
  }

  It 'uses Notice(s) when notice is the highest notable level' {
    $subject = Get-HealthNotableSubject -FallbackSubject 'Notable Messages from Get-ComputerHealth of SRV1' -NotableMessages @(
      [pscustomobject]@{ Level = 'notice' }
    )

    $subject | Should -Be 'Notice(s) from Get-ComputerHealth of SRV1'
  }

  It 'uses Warning(s) when warning exists and no failure exists' {
    $subject = Get-HealthNotableSubject -FallbackSubject 'Notable Messages from Get-ComputerHealth of SRV1' -NotableMessages @(
      [pscustomobject]@{ Level = 'notice' },
      [pscustomobject]@{ Level = 'warning' }
    )

    $subject | Should -Be 'Warning(s) from Get-ComputerHealth of SRV1'
  }

  It 'uses Failure(s) when failure exists regardless of lower levels' {
    $subject = Get-HealthNotableSubject -FallbackSubject 'Notable Messages from Get-ComputerHealth of SRV1' -NotableMessages @(
      [pscustomobject]@{ Level = 'notice' },
      [pscustomobject]@{ Level = 'warning' },
      [pscustomobject]@{ Level = 'failure' }
    )

    $subject | Should -Be 'Failure(s) from Get-ComputerHealth of SRV1'
  }

  It 'keeps fallback subject when only non-notable levels are present' {
    $subject = Get-HealthNotableSubject -FallbackSubject 'Notable Messages from Get-ComputerHealth of SRV1' -NotableMessages @(
      [pscustomobject]@{ Level = 'info' },
      [pscustomobject]@{ Level = 'debug' }
    )

    $subject | Should -Be 'Notable Messages from Get-ComputerHealth of SRV1'
  }
}
