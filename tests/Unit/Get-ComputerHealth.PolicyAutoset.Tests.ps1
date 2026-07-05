Describe 'Get-ComputerHealth policy auto-baseline markers' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $scriptPath = Join-Path $repoRoot 'Get-ComputerHealth.ps1'

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)

    foreach ($functionName in @('Get-PolicyBaselineVersion', 'Get-PolicyAutosetMarker', 'Test-PolicyAutosetAlreadyPerformed')) {
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

  It 'defaults missing Policy baseline version to 0' {
    function HealthTest-PolicyBaselineDefault {
<#
Description: Test helper.
AppliesTo: All
Scope: Computer
Category: Test
Impact: low
Tags: Policy
Uses: None.

Policy identity: name and path.
#>
    }

    try {
      Get-PolicyBaselineVersion -FunctionName 'HealthTest-PolicyBaselineDefault' | Should -Be 0
    }
    finally {
      Remove-Item Function:\HealthTest-PolicyBaselineDefault -ErrorAction SilentlyContinue
    }
  }

  It 'reads explicit Policy baseline version from the help block' {
    function HealthTest-PolicyBaselineExplicit {
<#
Description: Test helper.
AppliesTo: All
Scope: Computer
Category: Test
Impact: low
Tags: Policy
Uses: None.

Policy identity: name, path, and payload hash.
Policy baseline version: 7
#>
    }

    try {
      Get-PolicyBaselineVersion -FunctionName 'HealthTest-PolicyBaselineExplicit' | Should -Be 7
    }
    finally {
      Remove-Item Function:\HealthTest-PolicyBaselineExplicit -ErrorAction SilentlyContinue
    }
  }

  It 'rejects invalid Policy baseline version values' {
    function HealthTest-PolicyBaselineInvalid {
<#
Description: Test helper.
AppliesTo: All
Scope: Computer
Category: Test
Impact: low
Tags: Policy
Uses: None.

Policy identity: name and path.
Policy baseline version: one
#>
    }

    try {
      { Get-PolicyBaselineVersion -FunctionName 'HealthTest-PolicyBaselineInvalid' } | Should -Throw
    }
    finally {
      Remove-Item Function:\HealthTest-PolicyBaselineInvalid -ErrorAction SilentlyContinue
    }
  }

  It 'treats a legacy autoset marker as baseline version 1' {
    $tempRoot = Join-Path $env:TEMP ('gch-policy-marker-' + [guid]::NewGuid().ToString())
    $path = Join-Path $tempRoot 'Get-ComputerHealth.sigs-to-suppress.txt'

    try {
      New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
      Set-Content -LiteralPath $path -Value 'POLICY_TEST_WAS_RUN: ListServices' -Encoding ASCII

      Test-PolicyAutosetAlreadyPerformed -PolicyTestName 'ListServices' -PolicyBaselineVersion 1 -SuppressionFilePath $path | Should -BeTrue
      Test-PolicyAutosetAlreadyPerformed -PolicyTestName 'ListServices' -PolicyBaselineVersion 2 -SuppressionFilePath $path | Should -BeFalse

      Add-Content -LiteralPath $path -Value (Get-PolicyAutosetMarker -PolicyTestName 'ListServices' -PolicyBaselineVersion 1) -Encoding ASCII

      Test-PolicyAutosetAlreadyPerformed -PolicyTestName 'ListServices' -PolicyBaselineVersion 1 -SuppressionFilePath $path | Should -BeTrue
      Test-PolicyAutosetAlreadyPerformed -PolicyTestName 'ListServices' -PolicyBaselineVersion 2 -SuppressionFilePath $path | Should -BeFalse
    }
    finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
