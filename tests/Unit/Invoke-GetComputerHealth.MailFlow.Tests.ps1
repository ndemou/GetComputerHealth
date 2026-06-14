Describe 'Invoke-GetComputerHealth mail flow helpers' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $scriptPath = Join-Path $repoRoot 'Invoke-GetComputerHealth.ps1'
    $reportingPath = Join-Path $repoRoot 'reporting.ps1'
    $script:InvokeGetComputerHealthScriptText = Get-Content -LiteralPath $scriptPath -Raw

    . $reportingPath

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)

    foreach ($functionName in @(
        'Get-CachedIpsOfAllDcs',
        'Set-CachedIpsOfAllDcs',
        'Test-ValidCachedIpv4Address',
        'Normalize-IpsOfAllDcs',
        'Resolve-IpsOfAllDcs',
        'Remove-OldInvokeTranscriptLogs',
        'Start-InvokeTranscript',
        'Stop-InvokeTranscript',
        'Read-GchConfigFile',
        'Test-GchConfigKey',
        'Get-GchConfigValue',
        'Resolve-GchConfiguredNonNegativeInteger'
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

        $html | Should -Match '^<div class=''gch-synopsis''>'
        $html | Should -Not -Match 'Synopsis:'
        $html | Should -Match 'background-color:#ff4d4f; color:#fff'
        $html | Should -Match 'background-color:#ffb300; color:#111'
        $html | Should -Match 'background-color:#1e88e5; color:#fff'
        $html | Should -Match ">3 failure</span>"
        $html | Should -Match ">3 failure</span>   <span class='gch-pill'.+>2 warning</span>"
        $html | Should -Match ">2 warning</span>   <span class='gch-pill'.+>1 notice</span>"
        $html | Should -Match '>1 notice</span></div>'
        $html | Should -Not -Match '>failure</span>,'
        $html | Should -Not -Match '>warning</span>,'
        $html | Should -Not -Match '>notice</span>\.'
        $html | Should -Match "<div class='gch-divider'></div>"
        $html | Should -Not -Match '<pre'
    }

  It 'renders notable findings as inline heading blocks with plain suppression command styling' {
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
    $html | Should -Match '>Warning</span><span class=''gch-message''>Disk free space is low</span><span class=''gch-comment''>'
    $html | Should -Match "<div class='gch-root'><div class='gch-row'>"
    $html | Should -Match ([regex]::Escape('◆ Drive C: has only 4% free ◆ Investigate temp usage'))
    $html | Should -Not -Match 'border:1px solid'
    $html | Should -Match ([regex]::Escape('&amp; &quot;c:\it\Get-ComputerHealth\bin\Get-ComputerHealth.ps1&quot; -AddWhitelisting -until 2999-12-31 -sig &#39;deadbeef&#39; -ComputerName SRV1 -comment &quot;warning - Disk free space is low&quot;'))
    $html | Should -Not -Match ([regex]::Escape('Invoke-Command SRV1 {'))
    $html | Should -Not -Match ([regex]::Escape("Drive C: has only 4% free`nInvestigate temp usage"))
    $css = Get-HealthEmailCss
    $css | Should -Match '\.gch-root \{[\s\S]*font-size: 11pt;'
    $css | Should -Match '\.gch-divider-postponed \{[\s\S]*margin: 12px 0;'
    $css | Should -Match '\.gch-postponed \{[\s\S]*font-size: 10pt;'
    $css | Should -Match '\.gch-comment \{[\s\S]*font-family: "Aptos Narrow", Aptos, Arial, sans-serif;[\s\S]*font-size: 9pt;'
    $css | Should -Match '\.gch-command \{[\s\S]*font-size: 6pt;'
    $css | Should -Match '\.gch-signature-top \{[\s\S]*font-size: 9pt;'
    $css | Should -Match '\.gch-signature-bottom \{[\s\S]*font-size: 8pt;'
  }

  It 'renders postponed findings with a separated muted postponed style' {
    $html = Convert-HealthMessagesToHtmlTable -Messages @(
      [pscustomobject]@{
        Level = 'warning'
        EffectiveLevel = 'warning'
        Computer = 'SRV0'
        Message = 'CPU load is high'
        Comment = ''
        Hash = '11111111'
      },
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

    $html | Should -Match "<div class='gch-divider gch-divider-postponed'></div><div class='gch-row'><div><span class='gch-computer' style='color:#30510c'>SRV1</span>"
    $html | Should -Match "</div><div class='gch-divider gch-divider-postponed'></div>"
    $html | Should -Match 'background-color:#30510c; color:#fff'
    $html | Should -Match '>Postponed</span>'
    $html | Should -Match "<span class='gch-computer' style='color:#30510c'>SRV1</span>"
    $html | Should -Match "<span class='gch-message' style='color:#30510c'>Disk free space is low</span><span class='gch-postponed' style='color:#30510c'>"
    $html | Should -Match '\(Warning postponed until 2026-06-01\)</span></div>'
    $html | Should -Not -Match 'Postponed</span>[\s\S]*AddWhitelisting'
  }

  It 'summarizes postponed findings after active notable levels' {
    $html = Convert-HealthSynopsisToHtml -Messages @(
      [pscustomobject]@{ Level = 'warning'; EffectiveLevel = 'warning' },
      [pscustomobject]@{ Level = 'warning'; EffectiveLevel = 'postponed' },
      [pscustomobject]@{ Level = 'failure'; EffectiveLevel = 'failure' }
    )

    $html | Should -Match 'background-color:#30510c; color:#fff'
    $html | Should -Match "class='gch-pill'.+>1 failure</span>   <span class='gch-pill'.+>1 warning</span>   <span class='gch-pill'.+>1 postponed</span>"
  }

  It 'keeps plain suppression commands in html when multiple computers are present' {
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

    $html | Should -Match ([regex]::Escape('&amp; &quot;c:\it\Get-ComputerHealth\bin\Get-ComputerHealth.ps1&quot; -AddWhitelisting -until 2999-12-31 -sig &#39;deadbeef&#39; -ComputerName SRV1 -comment &quot;warning - Disk free space is low&quot;'))
    $html | Should -Match ([regex]::Escape('&amp; &quot;c:\it\Get-ComputerHealth\bin\Get-ComputerHealth.ps1&quot; -AddWhitelisting -until 2999-12-31 -sig &#39;feedbead&#39; -ComputerName SRV2 -comment &quot;notice - A few failed login attempts&quot;'))
    $html | Should -Not -Match ([regex]::Escape('Invoke-Command SRV1 {'))
    $html | Should -Not -Match ([regex]::Escape('Invoke-Command SRV2 {'))
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

  It 'normalizes DateTimeOffset TimeUtc values without throwing' {
    $rows = @(Convert-HealthMessagesToReportRows -Messages @(
        [pscustomobject]@{
          TimeUtc = [datetimeoffset]'2026-05-31T07:03:10+00:00'
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
    $rows[0].TimeUtc | Should -Be '2026-05-31T07:03:10.0000000+00:00'
  }

  It 'normalizes deserialized clixml DateTimeOffset TimeUtc values without throwing' {
    $tempRoot = Join-Path $env:TEMP ('gch-timeutc-clixml-' + [guid]::NewGuid().ToString())
    $path = Join-Path $tempRoot 'rows.clixml'

    try {
      New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
      @(
        [pscustomobject]@{
          TimeUtc = [datetimeoffset]'2026-05-31T07:03:10+00:00'
          Computer = 'SRV1'
          Suppressed = $false
          Level = 'warning'
          Message = 'Disk free space is low'
          Comment = 'Drive C: low'
          Hash = 'deadbeef'
          Emitter = 'HealthTest-Disks'
        }
      ) | Export-Clixml -LiteralPath $path

      $imported = Import-Clixml -LiteralPath $path
      $rows = @(Convert-HealthMessagesToReportRows -Messages $imported)

      $rows.Count | Should -Be 1
      $rows[0].TimeUtc | Should -Be '2026-05-31T07:03:10.0000000Z'
    } finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
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

  It 'shapes interactive rows from the current notable findings set' {
    $rows = @(Convert-HealthReportRowsToInteractiveRows -Rows @(
        [pscustomobject]@{ Computer = 'SRV1'; Suppressed = $false; Level = 'warning'; EffectiveLevel = 'warning'; Message = 'Disk free space is low'; Comment = 'Drive C: low'; Hash = 'deadbeef'; Emitter = 'x'; TimeUtc = 'y'; WhatToDo = 'not-sure' },
        [pscustomobject]@{ Computer = 'SRV2'; Suppressed = $false; Level = 'info'; EffectiveLevel = 'info'; Message = 'Informational'; Comment = ''; Hash = '11111111' },
        [pscustomobject]@{ Computer = 'SRV3'; Suppressed = $false; Level = 'pass'; EffectiveLevel = 'pass'; Message = 'Passed'; Comment = ''; Hash = '22222222' }
      ))

    $rows.Count | Should -Be 3
    $rows[0].Computer | Should -Be 'SRV1'
    $rows[0].PSObject.Properties.Name | Should -Contain 'Hash'
    $rows[0].PSObject.Properties.Name | Should -Contain 'Emitter'
    $rows[0].PSObject.Properties.Name | Should -Not -Contain 'TimeUtc'
  }

  It 'renders the interactive html report controls and rows' {
    $html = Get-HealthInteractiveHtmlReport -Title 'Sample Report' -FooterHtml 'Get-ComputerHealth version 8.0.7, last update 2026-05-31 08:58' -Rows @(
      [pscustomobject]@{
        Computer = 'SRV1'
        Suppressed = $false
        Level = 'warning'
        EffectiveLevel = 'warning'
        Message = 'Disk free space is low'
        Comment = 'Drive C: low'
        Hash = 'deadbeef'
        Emitter = 'UnitTest'
      }
    )

    $html | Should -Match '<title>Sample Report</title>'
    $html | Should -Match '>Get-ComputerHealth version 8.0.7, last update 2026-05-31 08:58<'
    $html | Should -Match 'Copy Action Commands'
    $html | Should -Match 'plain-toggle'
    $html | Should -Match 'Filters:'
    $html | Should -Match 'Visible Columns:'
    $html | Should -Match 'data-column="action" checked'
    $html | Should -Match 'font-size: 16px;'
    $html | Should -Not -Match 'Interactive notable findings for this run'
    $html | Should -Match 'Show Postponed'
    $html | Should -Match 'id="showPostponed" type="checkbox"'
    $html | Should -Match 'id="actionFilter"'
    $html | Should -Match '>All actions<'
    $html | Should -Match '>Suppress<'
    $html | Should -Match '>Postpone<'
    $html | Should -Not -Match 'id="showPostponed" type="checkbox" checked'
    $html | Should -Match 'data-column="message" checked'
    $html | Should -Match 'data-column="emitter"'
    $html | Should -Not -Match 'data-column="emitter" checked'
    $html | Should -Match 'data-column="command"'
    $html | Should -Not -Match 'data-column="command" checked'
    $html | Should -Not -Match 'class="what-filter'
    $html | Should -Not -Match 'id="sortField"'
    $html | Should -Not -Match 'id="sortDirection"'
    $html | Should -Match 'min-width: 190px;'
    $html | Should -Match 'flex: 0 1 210px;'
    $html | Should -Match 'table-layout: auto;'
    $html | Should -Match 'col\.col-width-computer \{ width: 1%; \}'
    $html | Should -Match 'col\.col-width-level \{ width: 1%; \}'
    $html | Should -Match 'col\.col-width-action \{ width: 1%; \}'
    $html | Should -Match 'col\.col-width-emitter \{ width: 1%; \}'
    $html | Should -Match '\.col-emitter \{'
    $html | Should -Match '\.message-info \{'
    $html | Should -Match '\.message-comment \{'
    $html | Should -Match 'font-family: Consolas, "Courier New", monospace;'
    $html | Should -Match '\.postponed-text \{'
    $html | Should -Match '\.show-postponed-status \{'
    $html | Should -Match '\.sort-toggle \{'
    $html | Should -Match '\.sort-toggle\.active \{'
    $html | Should -Match '\.utility-button \{'
    $html | Should -Match 'margin-left: auto;'
    $html | Should -Match '\.utility-button\.hidden \{'
    $html | Should -Match 'data-sort-field="Computer"'
    $html | Should -Match 'data-sort-field="EffectiveLevel"'
    $html | Should -Match 'data-sort-field="WhatToDo"'
    $html | Should -Match 'data-sort-field="Message"'
    $html | Should -Match 'data-sort-field="Emitter"'
    $html | Should -Match 'class="col-action"><button type="button" class="sort-toggle"'
    $html | Should -Match 'class="col-message"><button type="button" class="sort-toggle"'
    $html | Should -Match 'class="col-emitter"><button type="button" class="sort-toggle"'
    $html | Should -Match 'Action Command'
    $html | Should -Match 'Emitter'
    $html | Should -Match 'showing '
    $html | Should -Match 'of '
    $html | Should -Not -Match 'Visible findings: '
    $html | Should -Not -Match 'Loaded findings: '
    $html | Should -Match 'class="footer"'
    $html | Should -Match '<col class="col-command col-width-command">'
    $html | Should -Match '__gchVisibleCommands'
    $html | Should -Match 'navigator\.clipboard'
    $html | Should -Match 'Disk free space is low'
    $html | Should -Match 'buildWhitelistCommand'
    $html | Should -Match 'deadbeef'
    $html | Should -Match 'UnitTest'
    $html | Should -Match "var storageKey = 'gch-report-actions-v2';"
    $html | Should -Match 'ActionHistory: actionHistory\.slice\(-100\)'
    $html | Should -Match 'ActionState: actionState'
    $html | Should -Match 'function sortButtonText\(direction\)'
    $html | Should -Match 'function currentSort\(\)'
    $html | Should -Match 'function parseFilterTokens\(text\)'
    $html | Should -Match 'token\.negated'
    $html | Should -Match 'data-comment-key='
    $html | Should -Match '&#8505;&#65039;'
    $html | Should -Match "\\u25BC"
    $html | Should -Match "\\u25B2"
    $html | Should -Match "\\u25CF"
    $html | Should -Match "document.getElementById\('showPostponedStatus'\)\.textContent = '\(showing ' \+ filtered.length \+ ' of ' \+ rows.length \+ ' findings\)';"
    $html | Should -Match "document.getElementById\('copyVisibleCommands'\)\.classList\.toggle\('hidden', window\.__gchVisibleCommands\.length === 0\);"
    $html | Should -Match '"Computer":"SRV1"'
    $html | Should -Match '"Suppressed":false'
    $html | Should -Match '"Level":"warning"'
    $html | Should -Match '"EffectiveLevel":"warning"'
    $html | Should -Match '"Message":"Disk free space is low"'
    $html | Should -Match '"Comment":"Drive C: low"'
    $html | Should -Match '"Hash":"deadbeef"'
    $html | Should -Match '"Emitter":"UnitTest"'
  }

  It 'builds interactive commands from WhatToDo and hides postponed action buttons' {
    $html = Get-HealthInteractiveHtmlReport -Title 'Sample Report' -Rows @(
      [pscustomobject]@{
        Computer = 'SRV1'
        Suppressed = $false
        Level = 'warning'
        EffectiveLevel = 'warning'
        Message = 'Disk free space is low'
        Comment = 'Drive C: low'
        Hash = 'deadbeef'
        Emitter = 'UnitTest'
        WhatToDo = 'suppress'
      },
      [pscustomobject]@{
        Computer = 'SRV2'
        Suppressed = $false
        Level = 'warning'
        EffectiveLevel = 'warning'
        Message = 'CPU load is high'
        Comment = 'Investigate'
        Hash = 'feedbead'
        Emitter = 'UnitTest'
        WhatToDo = 'postpone'
      },
      [pscustomobject]@{
        Computer = 'SRV3'
        Suppressed = $false
        Level = 'warning'
        EffectiveLevel = 'warning'
        Message = 'Backup failed'
        Comment = 'Fix soon'
        Hash = '12345678'
        Emitter = 'UnitTest'
        WhatToDo = 'must-fix'
      },
      [pscustomobject]@{
        Computer = 'SRV4'
        Suppressed = $true
        Level = 'warning'
        EffectiveLevel = 'postponed'
        Message = 'Known issue'
        Comment = 'Waiting'
        Hash = '87654321'
        Emitter = 'UnitTest'
        WhatToDo = 'postpone'
      }
    )

    $html | Should -Match "var until = '2999-12-31';"
    $html | Should -Match "if \(whatToDo === 'postpone'\)"
    $html | Should -Match "if \(whatToDo === 'must-fix' \|\| whatToDo === 'not-sure' \|\| !whatToDo\)"
    $html | Should -Match "row\.WhatToDo = 'not-sure';"
    $html | Should -Match 'ComputerName: String\(row\.Computer \|\| ''''\)'
    $html | Should -Match 'FindingHash: String\(row\.Hash \|\| ''''\)'
    $html | Should -Match 'WhatToDo: String\(row\.WhatToDo \|\| ''not-sure''\)'
    $html | Should -Match 'if \(actionHistory\.length > 100\)'
    $html | Should -Match "if \(!isPostponed\)"
    $html | Should -Match '\{& \\"c:\\\\it\\\\Get-ComputerHealth\\\\bin\\\\Get-ComputerHealth\.ps1\\" -AddWhitelisting -until '
    $html | Should -Match ' -comment \\"'
    $html | Should -Not -Match '\\\\\\\\"'
    $html | Should -Match 'function commandsShareSingleComputer\(commands\)'
    $html | Should -Match 'function simplifyCommandsForSingleComputer\(commands\)'
    $html | Should -Match 'commands = simplifyCommandsForSingleComputer\(commands\);'
  }

  It 'uses a dedicated active html report path for the email attachment' {
    $paths = Get-HealthReportArtifactPaths -DataDir 'C:\data' -TempDir 'C:\temp' -Timestamp '2026-05-31_07.05'

    $paths.AllMessagesClixmlTempPath | Should -Be 'C:\temp\all-messages-2026-05-31_07.05.clixml'
    $paths.AllMessagesZipPath | Should -Be 'C:\data\all-messages-2026-05-31_07.05.clixml.zip'
    $paths.LastAllFindingsClixmlPath | Should -Be 'C:\temp\last-all-findings.clixml'
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

  It 'drops invalid cached IpsOfAllDcs values and keeps valid ones' {
    $tempRoot = Join-Path $env:TEMP ('gch-ips-cache-' + [guid]::NewGuid().ToString())
    $cachePath = Join-Path $tempRoot 'cache.IpsOfAllDcs.clixml'

    try {
      New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
      Set-CachedIpsOfAllDcs -CachePath $cachePath -IpsOfAllDcs @('10.0.0.1', '-PushUpdate', '10.0.0.2')

      $resolved = Resolve-IpsOfAllDcs -CachePath $cachePath
      $cached = Get-CachedIpsOfAllDcs -CachePath $cachePath

      $resolved | Should -Be @('10.0.0.1', '10.0.0.2')
      $cached | Should -Be @('10.0.0.1', '10.0.0.2')
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

  It 'restarts a transcript after stopping the previous active one' {
    $script:InvokeTranscriptStarted = $false
    $script:StartTranscriptCallCount = 0
    $script:StopTranscriptCallCount = 0

    Mock Start-Transcript {
      $script:StartTranscriptCallCount++
      if ($script:StartTranscriptCallCount -eq 1) {
        throw [System.Management.Automation.RuntimeException]::new('Transcription cannot be started.')
      }
    }

    Mock Stop-Transcript {
      $script:StopTranscriptCallCount++
    }

    try {
      { Start-InvokeTranscript -Path (Join-Path $env:TEMP ('gch-transcript-' + [guid]::NewGuid().ToString() + '.log')) } | Should -Not -Throw
      $script:InvokeTranscriptStarted | Should -BeTrue
      $script:StartTranscriptCallCount | Should -Be 2
      $script:StopTranscriptCallCount | Should -Be 1
    }
    finally {
      Stop-InvokeTranscript
    }

    $script:InvokeTranscriptStarted | Should -BeFalse
  }

  It 'derives targets from messages and computes a timestamp when omitted' {
    $tempRoot = Join-Path $env:TEMP ('gch-reporting-invoke-' + [guid]::NewGuid().ToString())
    $binDir = Join-Path $tempRoot 'bin'
    $configDir = Join-Path $tempRoot 'config'
    $tempDir = Join-Path $tempRoot 'temp'
    $dataDir = Join-Path $tempRoot 'data'
    $script:GetComputerHealthReportingScriptDir = $binDir

    try {
      New-Item -ItemType Directory -Path $binDir, $configDir, $tempDir, $dataDir -Force | Out-Null
      Set-Content -LiteralPath (Join-Path $binDir 'Get-ComputerHealth.ps1') -Value '$VERSION="4.5.6"' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $binDir 'VERSION') -Value '9.9.9' -Encoding UTF8

      Mock Get-EmbeddedGetComputerHealthVersion { '9.9.9' }
      Mock Get-HealthEmailSignature {
        [pscustomobject]@{
          Text = 'Tests started from RUNNER1 Domain contoso.local 10.0.0.10'
          Html = '<div>sig</div>'
          HtmlTop = 'Tests started from RUNNER1 Domain contoso.local 10.0.0.10'
          HtmlBottom = 'signature footer'
        }
      }
      Mock Get-HealthEmailDecision { [pscustomobject]@{ ShouldSend = $true; Reason = 'Email sending forced by -SendReport.' } }
      Mock Test-IsNonInteractiveContext { $false }
      Mock Export-HealthMessagesReportData {}
      Mock Copy-Item {}
      Mock Compress-HealthReportDataFile {}
      Mock Get-HealthInteractiveHtmlReport { '<html>interactive</html>' }
      Mock Save-HealthHtmlReport {}
      Mock Move-HealthReportFile {}
      Mock Invoke-HealthEmail {}

      Invoke-GetComputerHealthReporting -Messages @(
        [pscustomobject]@{
          Computer = 'SRV2'
          Level = 'warning'
          EffectiveLevel = 'warning'
          Suppressed = $false
          Message = 'Disk free space is low'
          Comment = ''
          Hash = 'deadbeef'
          Emitter = 'UnitTest'
        },
        [pscustomobject]@{
          Computer = 'SRV1'
          Level = 'notice'
          EffectiveLevel = 'notice'
          Suppressed = $false
          Message = 'A few failed login attempts'
          Comment = ''
          Hash = 'feedbead'
          Emitter = 'UnitTest'
        }
      ) -SendReport

      Assert-MockCalled Export-HealthMessagesReportData -Times 1 -ParameterFilter {
        $FileName -match [regex]::Escape((Join-Path $tempDir 'all-messages-')) -and
        $FileName -match 'all-messages-\d{4}-\d{2}-\d{2}_\d{2}\.\d{2}\.clixml$'
      }
      Assert-MockCalled Invoke-HealthEmail -Times 1 -ParameterFilter {
        $Subject -eq 'Warning(s) from Get-ComputerHealth of SRV1,SRV2'
      }
    }
    finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'uses provided targets for the subject instead of deriving them from messages' {
    $tempRoot = Join-Path $env:TEMP ('gch-reporting-invoke-' + [guid]::NewGuid().ToString())
    $binDir = Join-Path $tempRoot 'bin'
    $configDir = Join-Path $tempRoot 'config'
    $tempDir = Join-Path $tempRoot 'temp'
    $dataDir = Join-Path $tempRoot 'data'
    $script:GetComputerHealthReportingScriptDir = $binDir

    try {
      New-Item -ItemType Directory -Path $binDir, $configDir, $tempDir, $dataDir -Force | Out-Null
      Set-Content -LiteralPath (Join-Path $binDir 'Get-ComputerHealth.ps1') -Value '$VERSION="4.5.6"' -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $binDir 'VERSION') -Value '9.9.9' -Encoding UTF8

      Mock Get-EmbeddedGetComputerHealthVersion { '9.9.9' }
      Mock Get-HealthEmailSignature {
        [pscustomobject]@{
          Text = 'Tests started from RUNNER1 Domain contoso.local 10.0.0.10'
          Html = '<div>sig</div>'
          HtmlTop = 'Tests started from RUNNER1 Domain contoso.local 10.0.0.10'
          HtmlBottom = 'signature footer'
        }
      }
      Mock Get-HealthEmailDecision { [pscustomobject]@{ ShouldSend = $true; Reason = 'Email sending forced by -SendReport.' } }
      Mock Test-IsNonInteractiveContext { $false }
      Mock Export-HealthMessagesReportData {}
      Mock Copy-Item {}
      Mock Compress-HealthReportDataFile {}
      Mock Get-HealthInteractiveHtmlReport { '<html>interactive</html>' }
      Mock Save-HealthHtmlReport {}
      Mock Move-HealthReportFile {}
      Mock Invoke-HealthEmail {}

      Invoke-GetComputerHealthReporting -Messages @(
        [pscustomobject]@{
          Computer = 'MESSAGEHOST'
          Level = 'warning'
          EffectiveLevel = 'warning'
          Suppressed = $false
          Message = 'Disk free space is low'
          Comment = ''
          Hash = 'deadbeef'
          Emitter = 'UnitTest'
        }
      ) -Targets @('TARGET2', 'TARGET1') -Timestamp '2026-06-06_12.30' -SendReport

      Assert-MockCalled Invoke-HealthEmail -Times 1 -ParameterFilter {
        $Subject -eq 'Warning(s) from Get-ComputerHealth of TARGET1,TARGET2'
      }
    }
    finally {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'does nothing when reporting is invoked with an empty message array' {
    Mock Export-HealthMessagesReportData {}
    Mock Invoke-HealthEmail {}

    Invoke-GetComputerHealthReporting -Messages @()

    Assert-MockCalled Export-HealthMessagesReportData -Times 0
    Assert-MockCalled Invoke-HealthEmail -Times 0
  }
}
