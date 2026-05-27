Describe 'Update-GetHealthCode temporary directory selection' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $scriptPath = Join-Path $repoRoot 'Update-GetHealthCode.ps1'

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)

    if ($parseErrors -and $parseErrors.Count -gt 0) {
      throw "Could not parse ${scriptPath}: $($parseErrors[0].Message)"
    }

    $functionNames = @(
      'New-RandomTempDirectoryPath',
      'New-EmptyTempDirectory'
    )

    foreach ($functionName in $functionNames) {
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

  It 'uses a random suffixed temp directory when the default directory cannot be enumerated' {
    $savedTemp = $env:TEMP
    $tempRoot = Join-Path $env:TEMP ('gch-update-temp-test-' + [guid]::NewGuid().ToString())
    $defaultPath = Join-Path $tempRoot 'Update-GetHealthCode'
    $expectedPath = Join-Path $tempRoot 'Update-GetHealthCode.42'

    try {
      New-Item -ItemType Directory -Path $defaultPath -Force | Out-Null
      $env:TEMP = $tempRoot

      Mock Get-Random { 42 }
      Mock Get-ChildItem { throw [System.UnauthorizedAccessException]::new('Access denied for test') } -ParameterFilter {
        $LiteralPath -eq $defaultPath
      }

      $result = New-EmptyTempDirectory -Name 'Update-GetHealthCode'

      $result | Should -Be $expectedPath
      Test-Path -LiteralPath $expectedPath -PathType Container | Should -BeTrue
    } finally {
      $env:TEMP = $savedTemp
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'uses a random suffixed temp directory when the default path is a file' {
    $savedTemp = $env:TEMP
    $tempRoot = Join-Path $env:TEMP ('gch-update-temp-test-' + [guid]::NewGuid().ToString())
    $defaultPath = Join-Path $tempRoot 'Update-GetHealthCode'
    $expectedPath = Join-Path $tempRoot 'Update-GetHealthCode.123'

    try {
      New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
      Set-Content -LiteralPath $defaultPath -Value 'occupied' -NoNewline
      $env:TEMP = $tempRoot

      Mock Get-Random { 123 }

      $result = New-EmptyTempDirectory -Name 'Update-GetHealthCode'

      $result | Should -Be $expectedPath
      Test-Path -LiteralPath $expectedPath -PathType Container | Should -BeTrue
    } finally {
      $env:TEMP = $savedTemp
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
