Describe 'Update-GetHealthCode version parsing' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $scriptPath = Join-Path $repoRoot 'Update-GetHealthCode.ps1'

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)

    foreach ($functionName in @(
        'Get-GetComputerHealthVersionFromMarker',
        'ConvertTo-GetComputerHealthVersionToken',
        'Prepare-ManualUpdateZip'
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

  It 'extracts a normalized version token from a plain X.Y.Z marker fragment' {
    Get-GetComputerHealthVersionFromMarker -Marker 'manual-zip|GetComputerHealth-8.5.3|ABC123' | Should -Be 'v8.5.3'
  }

  It 'accepts a manual zip name that embeds X.Y.Z without a v prefix' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    $cacheDir = Join-Path $tempRoot 'cache'
    $zipPath = Join-Path $tempRoot 'GetComputerHealth-8.5.3.zip'

    try {
      $null = New-Item -ItemType Directory -Path $tempRoot -Force
      Set-Content -LiteralPath $zipPath -Value 'zip-bytes-placeholder' -NoNewline

      $result = Prepare-ManualUpdateZip -ZipPath $zipPath -CacheDir $cacheDir

      $result.ManualMarker | Should -Match '^manual-zip\|v8\.5\.3\|'
      [System.IO.Path]::GetFileName($result.CachedZipPath) | Should -Match '^GetComputerHealth-MANUAL-UPDATE-v8\.5\.3-'
    }
    finally {
      if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }
}
