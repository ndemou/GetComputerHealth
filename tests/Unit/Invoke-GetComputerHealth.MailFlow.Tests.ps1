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
        'Get-HealthEmailDecision',
        'Get-HealthSuppressionCommand',
        'Convert-HealthSynopsisToHtml',
        'Convert-HealthMessagesToHtmlTable',
        'Get-RelaxHtmlBody',
        'Convert-HealthMessagesToReportRows',
        'Export-HealthMessagesReportData',
        'Compress-HealthReportDataFile',
        'Convert-HealthReportRowsToInteractiveRows',
        'Get-HealthReportArtifactPaths',
        'Import-HealthMessagesReportData',
        'Get-HealthInteractiveHtmlReport',
        'Get-CachedIpsOfAllDcs',
        'Set-CachedIpsOfAllDcs',
        'Resolve-IpsOfAllDcs',
        'Save-HealthHtmlReport',
        'Move-HealthReportFile',
        'Remove-OldInvokeTranscriptLogs',
        'Read-GchConfigFile',
        'Test-GchConfigKey',
        'Get-GchConfigValue',
        'Resolve-GchConfiguredNonNegativeInteger',
        'Get-HealthSuppressionExpiryMap',
        'Get-HealthEffectiveLevel'
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

  It 'explains that interactive sessions do not send email by default' {
    $decision = Get-HealthEmailDecision -NonInteractiveContext:(Test-IsNonInteractiveContext -SessionId 1 -UserInteractive $true)

    $decision.ShouldSend | Should -BeFalse
    $decision.Reason | Should -Be 'Email sending disabled by default because the script is running in an interactive context.'
  }

  It 'explains that non-interactive sessions send email by default' {
    $decision = Get-HealthEmailDecision -NonInteractiveContext:(Test-IsNonInteractiveContext -SessionId 0 -UserInteractive $false)

    $decision.ShouldSend | Should -BeTrue
    $decision.Reason | Should -Be 'Email sending enabled by default because the script is running in a non-interactive context.'
  }

  It 'explains explicit email send overrides' {
    $forcedSend = Get-HealthEmailDecision -SendReport -NonInteractiveContext:$false
    $forcedSkip = Get-HealthEmailDecision -NoSendReport -NonInteractiveContext:$true

    $forcedSend.ShouldSend | Should -BeTrue
    $forcedSend.Reason | Should -Be 'Email sending forced by -SendReport.'
    $forcedSkip.ShouldSend | Should -BeFalse
    $forcedSkip.Reason | Should -Be 'Email sending disabled by -NoSendReport.'
  }

  It 'keeps the legacy NoSendMessage switch as a compatibility alias' {
    $script:InvokeGetComputerHealthScriptText | Should -Match '\[Alias\(''NoSendMessage'', ''NoSendMail''\)\]\s*\r?\n\s*\[switch\]\$NoSendReport'
  }

    It 'renders a one-line html synopsis with bright highlighted levels' {
        $html = Convert-HealthSynopsisToHtml -Messages @(
            [pscustomobject]@{ Level = 'failure' },
            [pscustomobject]@{ Level = 'failure' },
            [pscustomobject]@{ Level = 'failure' },
      [pscustomobject]@{ Level = 'warning' },
            [pscustomobject]@{ Level = 'warning' },
            [pscustomobject]@{ Level = 'notice' }
        )

        $html | Should -Match '^<div style=''margin:0 0 8px 0;'
        $html | Should -Not -Match 'Synopsis:'
        $html | Should -Match 'background-color:#ff4d4f; color:#fff'
        $html | Should -Match 'background-color:#ffb300; color:#111'
        $html | Should -Match 'background-color:#1e88e5; color:#fff'
        $html | Should -Match "font-weight:700; font-size:120%'>3</span>"
        $html | Should -Match '>failure</span>   <span style=''font-weight:700; font-size:120%''>2</span>'
        $html | Should -Match '>warning</span>   <span style=''font-weight:700; font-size:120%''>1</span>'
        $html | Should -Match '>notice</span></div>'
        $html | Should -Not -Match '>failure</span>,'
        $html | Should -Not -Match '>warning</span>,'
        $html | Should -Not -Match '>notice</span>\.'
        $html | Should -Match "border-top:1px solid #cfcfcf; margin:0 0 12px 0"
        $html | Should -Not -Match '<pre'
    }

  It 'renders notable findings as inline heading blocks with comment and suppression command styling' {
    $html = Convert-HealthMessagesToHtmlTable -Messages @(
      [pscustomobject]@{
        Level = 'warning'
        Computer = 'SRV1'
        Message = 'Disk free space is low'
        Comment = "Drive C: has only 4% free`nInvestigate temp usage"
        Hash = 'deadbeef'
      }
    )

    $html | Should -Not -Match '<table'
    $html | Should -Match '>SRV1</span>'
    $html | Should -Match 'background-color:#ffb300; color:#111'
    $html | Should -Match '>Warning</span><span style=''margin-left:8px''>Disk free space is low</span>'
    $html | Should -Match 'margin-bottom:10px; font-family:Segoe UI, Arial, sans-serif; font-size:12px; color:#000'
    $html | Should -Not -Match 'border:1px solid'
    $html | Should -Match 'Drive C: has only 4% free<br>Investigate temp usage'
    $html | Should -Match ([regex]::Escape('c:\it\Get-ComputerHealth\bin\Get-ComputerHealth.ps1 -AddWhitelisting -until 2999-12-31 -sig &#39;deadbeef&#39; -ComputerName SRV1 -comment &quot;warning - Disk free space is low&quot;'))
    $html | Should -Not -Match ([regex]::Escape('Invoke-Command SRV1 {'))
  }

  It 'renders postponed findings with a green effective level and postponement detail' {
    $html = Convert-HealthMessagesToHtmlTable -Messages @(
      [pscustomobject]@{
        Level = 'warning'
        EffectiveLevel = 'postponed'
        Computer = 'SRV1'
        Message = 'Disk free space is low'
        Comment = ''
        Hash = 'deadbeef'
        Suppressed = $true
        SuppressedUntil = [datetime]'2026-06-01'
      }
    )

    $html | Should -Match 'background-color:#2e7d32; color:#fff'
    $html | Should -Match '>Postponed</span>'
    $html | Should -Match 'Postponed until 2026-06-01, real level warning'
    $html | Should -Not -Match ([regex]::Escape('c:\it\Get-ComputerHealth\bin\Get-ComputerHealth.ps1 -AddWhitelisting'))
  }

  It 'summarizes postponed findings after active notable levels' {
    $html = Convert-HealthSynopsisToHtml -Messages @(
      [pscustomobject]@{ Level = 'warning'; EffectiveLevel = 'warning' },
      [pscustomobject]@{ Level = 'warning'; EffectiveLevel = 'postponed' },
      [pscustomobject]@{ Level = 'failure'; EffectiveLevel = 'failure' }
    )

    $html | Should -Match 'background-color:#2e7d32; color:#fff'
    $html | Should -Match "font-weight:700; font-size:120%'>1</span> <span.+>failure</span>   <span style='font-weight:700; font-size:120%'>1</span> <span.+>warning</span>   <span style='font-weight:700; font-size:120%'>1</span> <span.+>postponed</span>"
  }

  It 'keeps Invoke-Command wrapping in html when multiple computers are present' {
    $html = Convert-HealthMessagesToHtmlTable -Messages @(
      [pscustomobject]@{
        Level = 'warning'
        Computer = 'SRV1'
        Message = 'Disk free space is low'
        Comment = ''
        Hash = 'deadbeef'
      },
      [pscustomobject]@{
        Level = 'notice'
        Computer = 'SRV2'
        Message = 'A few failed login attempts'
        Comment = ''
        Hash = 'feedbead'
      }
    )

    $html | Should -Match ([regex]::Escape('Invoke-Command SRV1 {c:\it\Get-ComputerHealth\bin\Get-ComputerHealth.ps1 -AddWhitelisting -until 2999-12-31 -sig &#39;deadbeef&#39; -ComputerName SRV1 -comment &quot;warning - Disk free space is low&quot;}'))
    $html | Should -Match ([regex]::Escape('Invoke-Command SRV2 {c:\it\Get-ComputerHealth\bin\Get-ComputerHealth.ps1 -AddWhitelisting -until 2999-12-31 -sig &#39;feedbead&#39; -ComputerName SRV2 -comment &quot;notice - A few failed login attempts&quot;}'))
  }

  It 'renders the Relax html body as the email-safe card layout' {
    $html = Get-RelaxHtmlBody
    $leafEmoji = [char]::ConvertFromUtf32(0x1F343)

    $html | Should -Match '<!DOCTYPE html>'
    $html | Should -Match '<title>Relax - Email Safe Version</title>'
    $html | Should -Match 'class="swing-effect"'
    $html | Should -Match 'background-color: #eef2f5;'
    $html | Should -Match 'border: 1px solid #e2e8f0;'
    $html | Should -Match ([regex]::Escape($leafEmoji))
    $html | Should -Match 'letter-spacing: 10px; color: #718096; font-size: 28px;'
    $html | Should -Match '>\s*Relax\s*<'
  }

  It 'shapes report rows in Invoke-GetComputerHealth' {
    $rows = @(Convert-HealthMessagesToReportRows -Messages @(
        [pscustomobject]@{
          TimeUtc = [datetime]'2026-05-30T10:15:00Z'
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
    $rows[0].TimeUtc | Should -Be '2026-05-30T10:15:00.0000000Z'
    $rows[0].Computer | Should -Be 'SRV1'
    $rows[0].Level | Should -Be 'warning'
    $rows[0].WhatToDo | Should -Be 'not-sure'
    $rows[0].Hash | Should -Be 'deadbeef'
  }

  It 'saves and reloads report data as zipped clixml' {
    $tempRoot = Join-Path $env:TEMP ('gch-report-data-' + [guid]::NewGuid().ToString())
    $dataDir = Join-Path $tempRoot 'data'
    $tempPath = Join-Path $tempRoot 'all-messages-2026-05-30_10.15.clixml'
    $zipPath = Join-Path $dataDir 'all-messages-2026-05-30_10.15.clixml.zip'

    try {
      New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
      Export-HealthMessagesReportData -Messages @(
        [pscustomobject]@{
          Computer = 'SRV1'
          Suppressed = $false
          Level = 'warning'
          EffectiveLevel = 'warning'
          Message = 'Disk free space is low'
          Comment = 'Drive C: low'
          Hash = 'deadbeef'
          Emitter = 'HealthTest-Disks'
        }
      ) -FileName $tempPath
      Compress-HealthReportDataFile -SourcePath $tempPath -DestinationPath $zipPath

      $rows = @(Import-HealthMessagesReportData -DataDir $dataDir -CutoffDate ([datetime]'2026-05-01'))

      (Test-Path -LiteralPath $tempPath -PathType Leaf) | Should -BeFalse
      (Test-Path -LiteralPath $zipPath -PathType Leaf) | Should -BeTrue
      $rows.Count | Should -Be 1
      $rows[0].Computer | Should -Be 'SRV1'
      $rows[0].Hash | Should -Be 'deadbeef'
    } finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'filters interactive rows down to actionable levels and fields' {
    $rows = @(Convert-HealthReportRowsToInteractiveRows -Rows @(
        [pscustomobject]@{ Computer = 'SRV1'; Suppressed = $false; Level = 'warning'; EffectiveLevel = 'warning'; Message = 'Disk free space is low'; Comment = 'Drive C: low'; Hash = 'deadbeef'; Emitter = 'x'; TimeUtc = 'y'; WhatToDo = 'not-sure' },
        [pscustomobject]@{ Computer = 'SRV2'; Suppressed = $false; Level = 'info'; EffectiveLevel = 'info'; Message = 'Informational'; Comment = ''; Hash = '11111111' },
        [pscustomobject]@{ Computer = 'SRV3'; Suppressed = $false; Level = 'pass'; EffectiveLevel = 'pass'; Message = 'Passed'; Comment = ''; Hash = '22222222' }
      ))

    $rows.Count | Should -Be 1
    $rows[0].Computer | Should -Be 'SRV1'
    $rows[0].PSObject.Properties.Name | Should -Contain 'Hash'
    $rows[0].PSObject.Properties.Name | Should -Not -Contain 'Emitter'
    $rows[0].PSObject.Properties.Name | Should -Not -Contain 'TimeUtc'
  }

  It 'renders the interactive html report controls and rows' {
    $html = Get-HealthInteractiveHtmlReport -Title 'Sample Report' -Rows @(
      [pscustomobject]@{
        Computer = 'SRV1'
        Suppressed = $false
        Level = 'warning'
        EffectiveLevel = 'warning'
        Message = 'Disk free space is low'
        Comment = 'Drive C: low'
        Hash = 'deadbeef'
      }
    )

    $html | Should -Match '<title>Sample Report</title>'
    $html | Should -Match 'Hide suppressed'
    $html | Should -Match 'data-filter="postpone"'
    $html | Should -Match 'data-column="command"'
    $html | Should -Match 'Interactive findings report from the last 3 months'
    $html | Should -Match 'Disk free space is low'
    $html | Should -Match 'buildWhitelistCommand'
    $html | Should -Match 'deadbeef'
  }

  It 'uses a dedicated active html report path for the email attachment' {
    $paths = Get-HealthReportArtifactPaths -DataDir 'C:\data' -TempDir 'C:\temp' -Timestamp '2026-05-31_07.05'

    $paths.AllMessagesClixmlTempPath | Should -Be 'C:\temp\all-messages-2026-05-31_07.05.clixml'
    $paths.AllMessagesZipPath | Should -Be 'C:\data\all-messages-2026-05-31_07.05.clixml.zip'
    $paths.InteractiveReportTempPath | Should -Be 'C:\temp\interactive-report-2026-05-31_07.05.html'
    $paths.LastInteractiveReportHtmlPath | Should -Be 'C:\temp\last-interactive-report.html'
    $paths.LastEmailBodyHtmlPath | Should -Be 'C:\temp\last-report.html'
  }

  It 'loads active suppression expiry dates with last applicable entry winning' {
    $tempRoot = Join-Path $env:TEMP ('gch-suppression-map-' + [guid]::NewGuid().ToString())
    $path = Join-Path $tempRoot 'Get-ComputerHealth.sigs-to-suppress.txt'

    try {
      New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
      @(
        '11111111 UNTIL 2026-06-01 # active'
        '22222222 UNTIL 2026-01-01 # expired'
        '33333333 # permanent'
        '44444444 UNTIL 2026-07-01 # first'
        '44444444 UNTIL 2026-01-01 # later expired removes it'
      ) | Set-Content -LiteralPath $path -Encoding UTF8

      $map = Get-HealthSuppressionExpiryMap -Path $path -Today ([datetime]'2026-05-01')

      $map.ContainsKey('11111111') | Should -BeTrue
      $map['11111111'] | Should -Be ([datetime]'2026-06-01')
      $map.ContainsKey('22222222') | Should -BeFalse
      $map.ContainsKey('33333333') | Should -BeTrue
      $map['33333333'] | Should -BeNullOrEmpty
      $map.ContainsKey('44444444') | Should -BeFalse
    } finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'marks suppressed findings as postponed only when expiry is within the configured window' {
    Get-HealthEffectiveLevel -Level 'warning' -Suppressed:$true -SuppressedUntil ([datetime]'2026-06-01') -ShowAsPostponedWindowDays 150 -Today ([datetime]'2026-05-01') | Should -Be 'postponed'
    Get-HealthEffectiveLevel -Level 'warning' -Suppressed:$true -SuppressedUntil ([datetime]'2026-12-01') -ShowAsPostponedWindowDays 150 -Today ([datetime]'2026-05-01') | Should -Be 'warning'
    Get-HealthEffectiveLevel -Level 'warning' -Suppressed:$false -SuppressedUntil ([datetime]'2026-06-01') -ShowAsPostponedWindowDays 150 -Today ([datetime]'2026-05-01') | Should -Be 'warning'
  }

  It 'loads ShowAsPostponedWindowDays from gch.psd1-compatible data' {
    $tempRoot = Join-Path $env:TEMP ('gch-config-read-' + [guid]::NewGuid().ToString())
    $configPath = Join-Path $tempRoot 'gch.psd1'

    try {
      New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
      @'
@{
    ShowAsPostponedWindowDays = 30
}
'@ | Set-Content -LiteralPath $configPath -Encoding UTF8

      $config = Read-GchConfigFile -Path $configPath

      Test-GchConfigKey -Config $config -Key 'ShowAsPostponedWindowDays' | Should -BeTrue
      Resolve-GchConfiguredNonNegativeInteger -Value (Get-GchConfigValue -Config $config -Key 'ShowAsPostponedWindowDays') -Key 'ShowAsPostponedWindowDays' | Should -Be 30
    } finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
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

  It 'uses a single cached IpsOfAllDcs value when the argument is omitted' {
    $tempRoot = Join-Path $env:TEMP ('gch-ips-cache-' + [guid]::NewGuid().ToString())
    $cachePath = Join-Path $tempRoot 'cache.IpsOfAllDcs.clixml'

    try {
      New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
      Set-CachedIpsOfAllDcs -CachePath $cachePath -IpsOfAllDcs @('10.0.0.1')

      $resolved = Resolve-IpsOfAllDcs -CachePath $cachePath

      $resolved | Should -Be @('10.0.0.1')
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
    $reportPath = Join-Path $tempRoot 'last-interactive-report.html'
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

  It 'replaces the last interactive report when moving a timestamped html report into place' {
    $tempRoot = Join-Path $env:TEMP ('gch-html-move-' + [guid]::NewGuid().ToString())
    $sourcePath = Join-Path $tempRoot 'interactive-report-2026-05-31_07.05.html'
    $destinationPath = Join-Path $tempRoot 'last-interactive-report.html'

    try {
      New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
      Set-Content -LiteralPath $sourcePath -Value 'new-report' -Encoding UTF8
      Set-Content -LiteralPath $destinationPath -Value 'old-report' -Encoding UTF8

      Move-HealthReportFile -SourcePath $sourcePath -DestinationPath $destinationPath

      (Test-Path -LiteralPath $sourcePath -PathType Leaf) | Should -BeFalse
      ((Get-Content -LiteralPath $destinationPath -Raw).TrimEnd("`r", "`n")) | Should -Be 'new-report'
    }
    finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'deletes only old Invoke-GetComputerHealth transcript logs' {
    $tempRoot = Join-Path $env:TEMP ('gch-transcript-cleanup-' + [guid]::NewGuid().ToString())
    $oldTranscript = Join-Path $tempRoot 'Invoke-GetHealthDomainComputers-2026-01-01_00.00.log'
    $newTranscript = Join-Path $tempRoot 'Invoke-GetHealthDomainComputers-2026-05-01_00.00.log'
    $oldOtherLog = Join-Path $tempRoot 'Other-2026-01-01.log'
    $cutoff = [datetime]'2026-04-01T00:00:00'

    try {
      New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
      Set-Content -LiteralPath $oldTranscript -Value 'old transcript' -NoNewline
      Set-Content -LiteralPath $newTranscript -Value 'new transcript' -NoNewline
      Set-Content -LiteralPath $oldOtherLog -Value 'other old log' -NoNewline

      (Get-Item -LiteralPath $oldTranscript).LastWriteTime = [datetime]'2026-02-01T00:00:00'
      (Get-Item -LiteralPath $newTranscript).LastWriteTime = [datetime]'2026-05-01T00:00:00'
      (Get-Item -LiteralPath $oldOtherLog).LastWriteTime = [datetime]'2026-02-01T00:00:00'

      Remove-OldInvokeTranscriptLogs -LogDir $tempRoot -CutoffDate $cutoff

      Test-Path -LiteralPath $oldTranscript -PathType Leaf | Should -BeFalse
      Test-Path -LiteralPath $newTranscript -PathType Leaf | Should -BeTrue
      Test-Path -LiteralPath $oldOtherLog -PathType Leaf | Should -BeTrue
    } finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
