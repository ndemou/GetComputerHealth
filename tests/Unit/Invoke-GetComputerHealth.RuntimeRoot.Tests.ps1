Describe 'Invoke-GetComputerHealth runtime root resolution' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $scriptPath = Join-Path $repoRoot 'Invoke-GetComputerHealth.ps1'

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)

    $funcAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Resolve-GetComputerHealthRuntimeRoot'
      }, $true)

    if ($null -eq $funcAst) {
      throw "Function not found in ${scriptPath}: Resolve-GetComputerHealthRuntimeRoot"
    }

    . ([scriptblock]::Create($funcAst.Extent.Text))
  }

  It 'keeps the current root when Get-ComputerHealth.ps1 still exists there' {
    $tempRoot = Join-Path $env:TEMP ('gch-runtime-root-' + [guid]::NewGuid().ToString())
    $binDir = Join-Path $tempRoot 'bin'

    try {
      New-Item -ItemType Directory -Path $binDir -Force | Out-Null
      Set-Content -LiteralPath (Join-Path $binDir 'Get-ComputerHealth.ps1') -Value '$VERSION="4.0.0"' -NoNewline

      Resolve-GetComputerHealthRuntimeRoot -RootDir $tempRoot | Should -Be $tempRoot
    } finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'switches to the migrated Get-ComputerHealth subroot when the legacy root lost Get-ComputerHealth.ps1' {
    $tempRoot = Join-Path $env:TEMP ('gch-runtime-root-' + [guid]::NewGuid().ToString())
    $migratedBinDir = Join-Path $tempRoot 'Get-ComputerHealth\bin'

    try {
      New-Item -ItemType Directory -Path $migratedBinDir -Force | Out-Null
      Set-Content -LiteralPath (Join-Path $migratedBinDir 'Get-ComputerHealth.ps1') -Value '$VERSION="4.0.0"' -NoNewline

      Resolve-GetComputerHealthRuntimeRoot -RootDir $tempRoot | Should -Be (Join-Path $tempRoot 'Get-ComputerHealth')
    } finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'falls back to the legacy parent root when invoked from Get-ComputerHealth but only the legacy layout exists' {
    $tempRoot = Join-Path $env:TEMP ('gch-runtime-root-' + [guid]::NewGuid().ToString())
    $legacyBinDir = Join-Path $tempRoot 'bin'
    $candidateRoot = Join-Path $tempRoot 'Get-ComputerHealth'

    try {
      New-Item -ItemType Directory -Path $legacyBinDir, $candidateRoot -Force | Out-Null
      Set-Content -LiteralPath (Join-Path $legacyBinDir 'Get-ComputerHealth.ps1') -Value '$VERSION="4.0.0"' -NoNewline

      Resolve-GetComputerHealthRuntimeRoot -RootDir $candidateRoot | Should -Be $tempRoot
    } finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
