Describe 'Get-ComputerHealth hide parameter' {
  BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:GetComputerHealthScript = Join-Path $script:RepoRoot 'Get-ComputerHealth.ps1'
  }

  It 'accepts lowercase hide flags' {
    {
      & $script:GetComputerHealthScript `
        -Hide 'dips' `
        -DoNothing `
        -RunWithoutElevation
    } | Should -Not -Throw
  }
}
