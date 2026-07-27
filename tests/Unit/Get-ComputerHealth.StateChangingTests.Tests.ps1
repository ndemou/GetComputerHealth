Describe 'Guarded state-changing built-in health tests' {
  BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:GetComputerHealthScript = Join-Path $script:RepoRoot 'Get-ComputerHealth.ps1'
    $script:StateChangingTestsPath = Join-Path $script:RepoRoot 'health-tests\HealthTests-that-do-change-state'

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
      $script:GetComputerHealthScript,
      [ref]$tokens,
      [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
      throw ($parseErrors | Out-String)
    }

    $directoryFunction = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-BuiltInHealthTestDirectories'
      }, $true)
    if (-not $directoryFunction) {
      throw 'Get-BuiltInHealthTestDirectories was not found.'
    }

    . ([scriptblock]::Create($directoryFunction.Extent.Text))
  }

  It 'keeps the active tests in the guarded subdirectory' {
    Test-Path -LiteralPath (Join-Path $script:StateChangingTestsPath 'HealthTest-GpupdatePolicyApply.ps1') -PathType Leaf | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $script:StateChangingTestsPath 'HealthTest-Dcdiag.ps1') -PathType Leaf | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $script:RepoRoot 'health-tests\HealthTest-GpupdatePolicyApply.ps1') -PathType Leaf | Should -BeFalse
    Test-Path -LiteralPath (Join-Path $script:RepoRoot 'health-tests\HealthTest-Dcdiag.ps1') -PathType Leaf | Should -BeFalse
  }

  It 'returns only the read-only built-in directory by default' {
    $directories = @(Get-BuiltInHealthTestDirectories -ScriptRoot $script:RepoRoot)

    $directories | Should -HaveCount 1
    $directories[0] | Should -Be (Join-Path $script:RepoRoot 'health-tests')
  }

  It 'adds the guarded directory only with explicit opt-in' {
    $directories = @(
      Get-BuiltInHealthTestDirectories -ScriptRoot $script:RepoRoot -IncludeStateChangingTests
    )

    $directories | Should -HaveCount 2
    $directories | Should -Contain (Join-Path $script:RepoRoot 'health-tests')
    $directories | Should -Contain $script:StateChangingTestsPath
  }

  It 'declares the opt-in switch on both public entry points' {
    (Get-Command -Name $script:GetComputerHealthScript).Parameters.ContainsKey(
      'IReallyWantToRunTestsThatChangeState'
    ) | Should -BeTrue

    $invokeScript = Join-Path $script:RepoRoot 'Invoke-GetComputerHealth.ps1'
    (Get-Command -Name $invokeScript).Parameters.ContainsKey(
      'IReallyWantToRunTestsThatChangeState'
    ) | Should -BeTrue
  }

  It 'lists guarded tests without running them' {
    $tests = @(
      & $script:GetComputerHealthScript -ListAllBuiltInTests -RunWithoutElevation
    )

    ($tests | Where-Object Name -eq 'HealthTest-GpupdatePolicyApply').Description |
      Should -Match '^Actively applies Group Policy'
    ($tests | Where-Object Name -eq 'HealthTest-Dcdiag').Description |
      Should -Match '^Actively runs comprehensive DCDIAG'
  }
}
