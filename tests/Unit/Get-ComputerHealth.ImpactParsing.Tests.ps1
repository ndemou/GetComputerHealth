Describe 'Get-ComputerHealth impact parsing' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $scriptPath = Join-Path $repoRoot 'Get-ComputerHealth.ps1'

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)

    $funcAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-HealthTestTagsMetadata'
      }, $true)

    if ($null -eq $funcAst) {
      throw "Function not found in ${scriptPath}: Get-HealthTestTagsMetadata"
    }

    . ([scriptblock]::Create($funcAst.Extent.Text))
  }

  It 'marks High(Time) tests as slow' {
    function HealthTest-ImpactParsingCanonical {
<#
Description: Test helper.
AppliesTo: All
Scope: Computer
Category: Test
Impact: High(Time), Medium(CPU)
Uses: None.
#>
      [CmdletBinding()]
      param()
    }

    try {
      (Get-HealthTestTagsMetadata -FunctionName 'HealthTest-ImpactParsingCanonical').IsSlowTest | Should -BeTrue
    } finally {
      Remove-Item Function:\HealthTest-ImpactParsingCanonical -ErrorAction SilentlyContinue
    }
  }

  It 'marks legacy Time(High) tests as slow' {
    function HealthTest-ImpactParsingLegacy {
<#
Description: Test helper.
AppliesTo: All
Scope: Computer
Category: Test
Impact: Time(High), CPU(High)
Uses: None.
#>
      [CmdletBinding()]
      param()
    }

    try {
      (Get-HealthTestTagsMetadata -FunctionName 'HealthTest-ImpactParsingLegacy').IsSlowTest | Should -BeTrue
    } finally {
      Remove-Item Function:\HealthTest-ImpactParsingLegacy -ErrorAction SilentlyContinue
    }
  }

  It 'does not mark non-time high impacts as slow' {
    function HealthTest-ImpactParsingCpuOnly {
<#
Description: Test helper.
AppliesTo: All
Scope: Computer
Category: Test
Impact: High(CPU), Medium(Disk)
Uses: None.
#>
      [CmdletBinding()]
      param()
    }

    try {
      (Get-HealthTestTagsMetadata -FunctionName 'HealthTest-ImpactParsingCpuOnly').IsSlowTest | Should -BeFalse
    } finally {
      Remove-Item Function:\HealthTest-ImpactParsingCpuOnly -ErrorAction SilentlyContinue
    }
  }
}
