Describe 'Microsoft installed software update classification' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $scriptPath = Join-Path $repoRoot 'health-tests\win-os-hyg.ps1'

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)

    foreach ($functionName in @('Test-IsMicrosoftInstalledSoftwareUpdate', 'Get-InstalledSoftwareFindingLevel')) {
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

  It 'classifies SQL Server GDR security updates as Microsoft updates' {
    Test-IsMicrosoftInstalledSoftwareUpdate -Name 'GDR 2155 for SQL Server 2019 KB5068405' -Publisher 'Microsoft Corporation' | Should -Be $true
  }

  It 'classifies generic Microsoft KB security updates as Microsoft updates' {
    Test-IsMicrosoftInstalledSoftwareUpdate -Name 'Security Update for Microsoft Windows (KB5031364)' -Publisher 'Microsoft Corporation' | Should -Be $true
  }

  It 'does not classify ordinary Microsoft products as updates' {
    Test-IsMicrosoftInstalledSoftwareUpdate -Name 'Microsoft SQL Server 2019 Setup (English)' -Publisher 'Microsoft Corporation' | Should -Be $false
  }

  It 'does not classify non-Microsoft updates with similar wording as Microsoft updates' {
    Test-IsMicrosoftInstalledSoftwareUpdate -Name 'Security Update KB1234567 for Contoso App' -Publisher 'Contoso Ltd' | Should -Be $false
  }

  It 'returns info for Microsoft update-like installs and notice otherwise' {
    Get-InstalledSoftwareFindingLevel -Name 'GDR 2155 for SQL Server 2019 KB5068405' -Publisher 'Microsoft Corporation' | Should -Be 'info'
    Get-InstalledSoftwareFindingLevel -Name 'Microsoft SQL Server 2019 Setup (English)' -Publisher 'Microsoft Corporation' | Should -Be 'notice'
  }
}
