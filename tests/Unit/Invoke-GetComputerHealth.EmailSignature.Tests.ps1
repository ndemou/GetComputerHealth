Describe 'Invoke-GetComputerHealth email signature helpers' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $scriptPath = Join-Path $repoRoot 'Invoke-GetComputerHealth.ps1'
    $script:InvokeGetComputerHealthScriptPath = $scriptPath

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)

    foreach ($functionName in @('Get-HealthEmailSignature', 'Add-HealthEmailSignature', 'Get-EmbeddedGetComputerHealthVersion')) {
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

  It 'prefers the VERSION file contents and timestamp' {
    $tempRoot = Join-Path $env:TEMP ('gch-email-signature-' + [guid]::NewGuid().ToString())
    $versionPath = Join-Path $tempRoot 'VERSION'

    try {
      New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
      Set-Content -LiteralPath $versionPath -Value '9.9.9' -NoNewline
      (Get-Item -LiteralPath $versionPath).LastWriteTime = [datetime]'2026-04-01 07:08:00'

      $signature = Get-HealthEmailSignature -VersionFilePath $versionPath -FallbackVersion '0.0.0' -FallbackTimestampPath $script:InvokeGetComputerHealthScriptPath

      $signature.Text | Should -Be 'Get-ComputerHealth version 9.9.9, last update 2026-04-01 07:08'
      $signature.Html | Should -Be 'Get-ComputerHealth version 9.9.9, last update 2026-04-01 07:08'
    } finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'falls back to the embedded version and script timestamp when VERSION is missing' {
    $tempRoot = Join-Path $env:TEMP ('gch-email-signature-' + [guid]::NewGuid().ToString())
    $fallbackScriptPath = Join-Path $tempRoot 'Get-ComputerHealth.ps1'

    try {
      New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
      Set-Content -LiteralPath $fallbackScriptPath -Value '$VERSION="4.5.6"' -NoNewline
      (Get-Item -LiteralPath $fallbackScriptPath).LastWriteTime = [datetime]'2026-02-03 04:05:00'

      $embeddedVersion = Get-EmbeddedGetComputerHealthVersion -ScriptPath $fallbackScriptPath
      $signature = Get-HealthEmailSignature -VersionFilePath (Join-Path $tempRoot 'missing-VERSION') -FallbackVersion $embeddedVersion -FallbackTimestampPath $fallbackScriptPath

      $embeddedVersion | Should -Be '4.5.6'
      $signature.Text | Should -Be 'Get-ComputerHealth version 4.5.6, last update 2026-02-03 04:05'
    } finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'appends the signature to plain text and html bodies' {
    $signature = [pscustomobject]@{
      Text = 'Get-ComputerHealth version 1.2.3, last update 2026-01-02 03:04'
      Html = 'Get-ComputerHealth version 1.2.3, last update 2026-01-02 03:04'
    }

    $plain = Add-HealthEmailSignature -Body 'Relax :-)' -Signature $signature
    $html = Add-HealthEmailSignature -Body '<pre>body</pre>' -BodyAsHtml -Signature $signature

    $plain | Should -Be "Relax :-)`r`n`r`nGet-ComputerHealth version 1.2.3, last update 2026-01-02 03:04"
    $html | Should -Be "<pre>body</pre><div style='margin-top:12px; color:#666; font-family:Consolas, ""Courier New"", monospace; font-size:12px'>Get-ComputerHealth version 1.2.3, last update 2026-01-02 03:04</div>"
  }
}
