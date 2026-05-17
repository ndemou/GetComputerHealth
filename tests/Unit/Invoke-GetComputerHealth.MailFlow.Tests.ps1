Describe 'Invoke-GetComputerHealth mail flow helpers' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $scriptPath = Join-Path $repoRoot 'Invoke-GetComputerHealth.ps1'
    $script:InvokeGetComputerHealthScriptText = Get-Content -LiteralPath $scriptPath -Raw

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)

    foreach ($functionName in @(
        'Test-IsNonInteractiveContext',
        'Resolve-HealthEmailPreference',
        'Get-HealthSuppressionCommand',
        'Convert-HealthMessagesToHtmlTable',
        'Convert-HealthMessagesToExcelRows',
        'Get-CachedIpsOfAllDcs',
        'Set-CachedIpsOfAllDcs',
        'Resolve-IpsOfAllDcs',
        'Save-HealthHtmlReport'
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

  It 'defaults to not sending email in interactive sessions' {
    $result = Resolve-HealthEmailPreference -NonInteractiveContext:(Test-IsNonInteractiveContext -SessionId 1 -UserInteractive $true)
    $result | Should -BeFalse
  }

  It 'defaults to sending email in non-interactive sessions' {
    $result = Resolve-HealthEmailPreference -NonInteractiveContext:(Test-IsNonInteractiveContext -SessionId 0 -UserInteractive $false)
    $result | Should -BeTrue
  }

  It 'lets explicit switches override the default send-mail behavior' {
    (Resolve-HealthEmailPreference -SendReport -NonInteractiveContext:$false) | Should -BeTrue
    (Resolve-HealthEmailPreference -NoSendReport -NonInteractiveContext:$true) | Should -BeFalse
  }

  It 'keeps the legacy NoSendMessage switch as a compatibility alias' {
    $script:InvokeGetComputerHealthScriptText | Should -Match '\[Alias\(''NoSendMessage'', ''NoSendMail''\)\]\s*\r?\n\s*\[switch\]\$NoSendReport'
  }

  It 'renders notable findings as an html table with comment and suppression command styling' {
    $html = Convert-HealthMessagesToHtmlTable -Messages @(
      [pscustomobject]@{
        Level = 'warning'
        Computer = 'SRV1'
        Message = 'Disk free space is low'
        Comment = "Drive C: has only 4% free`nInvestigate temp usage"
        Hash = 'deadbeef'
      }
    )

    $html | Should -Not -Match '<thead>'
    $html | Should -Match '>SRV1</div><div'
    $html | Should -Match '>Warning</div>'
    $html | Should -Match 'Drive C: has only 4% free<br>Investigate temp usage'
    $html | Should -Match ([regex]::Escape('Invoke-Command SRV1 {c:\it\Get-ComputerHealth\bin\Get-ComputerHealth.ps1 -AddWhitelisting -until 2999-12-31 -sig &#39;deadbeef&#39; -ComputerName SRV1 -comment &quot;warning - Disk free space is low&quot;}'))
  }

  It 'shapes Excel rows in Invoke-GetComputerHealth including suppression commands' {
    $rows = @(Convert-HealthMessagesToExcelRows -Messages @(
        [pscustomobject]@{
          Computer = 'SRV1'
          Suppressed = $false
          Level = 'warning'
          Message = 'Disk free space is low'
          Comment = 'Drive C: low'
          Hash = 'deadbeef'
          Emitter = 'HealthTest-Disks'
        }
      ))

    $rows.Count | Should -Be 1
    $rows[0].Computer | Should -Be 'SRV1'
    $rows[0].Level | Should -Be 'warning'
    $rows[0].CommandToSuppressMsg | Should -Be 'Invoke-Command SRV1 {c:\it\Get-ComputerHealth\bin\Get-ComputerHealth.ps1 -AddWhitelisting -until 2999-12-31 -sig ''deadbeef'' -ComputerName SRV1 -comment "warning - Disk free space is low"}'
  }

  It 'does not generate Excel suppression commands for suppressed or informational rows' {
    $rows = @(Convert-HealthMessagesToExcelRows -Messages @(
        [pscustomobject]@{ Computer = 'SRV1'; Suppressed = $true; Level = 'warning'; Message = 'Already suppressed'; Comment = ''; Hash = '11111111'; Emitter = '' },
        [pscustomobject]@{ Computer = 'SRV2'; Suppressed = $false; Level = 'info'; Message = 'Informational'; Comment = ''; Hash = '22222222'; Emitter = '' }
      ))

    $rows[0].CommandToSuppressMsg | Should -Be ''
    $rows[1].CommandToSuppressMsg | Should -Be ''
  }

  It 'uses cached IpsOfAllDcs values when the argument is omitted' {
    $tempRoot = Join-Path $env:TEMP ('gch-ips-cache-' + [guid]::NewGuid().ToString())
    $cachePath = Join-Path $tempRoot 'cache.IpsOfAllDcs.clixml'

    try {
      New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
      Set-CachedIpsOfAllDcs -CachePath $cachePath -IpsOfAllDcs @('10.0.0.1', '10.0.0.2')

      $resolved = Resolve-IpsOfAllDcs -CachePath $cachePath

      $resolved | Should -Be @('10.0.0.1', '10.0.0.2')
    }
    finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'caches IpsOfAllDcs when a value is provided' {
    $tempRoot = Join-Path $env:TEMP ('gch-ips-cache-' + [guid]::NewGuid().ToString())
    $cachePath = Join-Path $tempRoot 'cache.IpsOfAllDcs.clixml'

    try {
      $resolved = Resolve-IpsOfAllDcs -IpsOfAllDcs @('10.1.0.1') -WasProvided -CachePath $cachePath
      $cached = Get-CachedIpsOfAllDcs -CachePath $cachePath

      $resolved | Should -Be @('10.1.0.1')
      $cached | Should -Be @('10.1.0.1')
    }
    finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'saves the generated html report to disk' {
    $tempRoot = Join-Path $env:TEMP ('gch-html-report-' + [guid]::NewGuid().ToString())
    $reportPath = Join-Path $tempRoot 'last-report.html'
    $html = '<div>hello report</div>'

    try {
      Save-HealthHtmlReport -Path $reportPath -Html $html

      (Test-Path -LiteralPath $reportPath -PathType Leaf) | Should -BeTrue
      (Get-Content -LiteralPath $reportPath -Raw) | Should -Match ([regex]::Escape($html))
    }
    finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
