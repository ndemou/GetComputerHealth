Describe 'HealthTest help blocks' {
  It 'all HealthTest-* functions have the required help block format' {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $healthTestsPath = Join-Path $repoRoot 'health-tests'
    $requiredFields = @('Description', 'AppliesTo', 'Scope', 'Category', 'Impact', 'Uses')
    $allowedAppliesTo = @('All', 'VM', 'Mobile', 'DomainJoined', 'Server', 'Workstation', 'DC', 'PDC', 'HyperV', 'Hyper-V')
    $allowedScopes = @('Computer', 'Domain', 'Forest')
    $allowedCategories = @(
      'Availability/Server Down Signals',
      'Security & Stability Risks',
      'Configuration Hygiene & Best Practices',
      'Audit/Compliance/Informational'
    )
    $allowedTags = @('Essential', 'Policy', 'Suppressed')
    $functionPattern = '(?ms)^[ \t]*function[ \t]+(?<Name>HealthTest-[\w-]+)[ \t]*\{'
    $helpBlocks = @()

    Get-ChildItem -Path $healthTestsPath -Filter *.ps1 -File | ForEach-Object {
      $content = Get-Content -Path $_.FullName -Raw

      foreach ($functionMatch in [regex]::Matches($content, $functionPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
        $remainder = $content.Substring($functionMatch.Index + $functionMatch.Length)
        $blockMatch = [regex]::Match(
          $remainder,
          '^\s*<#[\r\n]+(?<Block>.*?)[\r\n]\s*#>',
          [System.Text.RegularExpressions.RegexOptions]::Singleline
        )

        $blockText = if ($blockMatch.Success) { $blockMatch.Groups['Block'].Value } else { $null }
        $lines = if ($blockText) {
          @(
            $blockText -split '\r?\n' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne '' }
          )
        } else {
          @()
        }

        $actualFields = @()
        foreach ($line in $lines) {
          if ($line -match '^(?<Field>[A-Za-z]+):\s+') {
            $actualFields += $matches['Field']
          }
        }

        $helpBlocks += [pscustomobject]@{
          FilePath                = $_.FullName
          FunctionName            = $functionMatch.Groups['Name'].Value
          BlockText               = $blockText
          HasHelpBlock            = $blockMatch.Success
          ActualFields            = $actualFields
          HasLegacySyntax         = $blockText -match '(?im)^\s*\.(SYNOPSIS|DESCRIPTION)\b'
          FirstLineIsDescription  = (@($lines).Count -gt 0) -and $lines[0] -match '^Description:\s+\S+'
          HasAllFields            = @($requiredFields | Where-Object { $_ -in $actualFields }).Count -eq $requiredFields.Count
          HasExpectedOrder        = $false
        }
        $fields = @($helpBlocks[-1].ActualFields)
        $idx = @{}
        for ($i = 0; $i -lt $fields.Count; $i++) {
          if (-not $idx.ContainsKey($fields[$i])) { $idx[$fields[$i]] = $i }
        }
        $hasPrefixOrder = ($fields.Count -ge 5) -and ((@($fields)[0..4] -join '|') -eq 'Description|AppliesTo|Scope|Category|Impact')
        $usesAfterImpact = $idx.ContainsKey('Uses') -and $idx.ContainsKey('Impact') -and ($idx['Uses'] -gt $idx['Impact'])
        $tagsPositionOk = (-not $idx.ContainsKey('Tags')) -or (
          $idx.ContainsKey('Impact') -and $idx.ContainsKey('Uses') -and
          ($idx['Tags'] -gt $idx['Impact']) -and
          ($idx['Tags'] -lt $idx['Uses'])
        )
        $helpBlocks[-1].HasExpectedOrder = $hasPrefixOrder -and $usesAfterImpact -and $tagsPositionOk
      }
    }

    $helpBlocks.Count | Should -BeGreaterThan 0

    $violations = foreach ($helpBlock in $helpBlocks) {
      if (-not $helpBlock.HasHelpBlock) {
        "$($helpBlock.FunctionName) in $($helpBlock.FilePath) is missing a help block immediately inside the function body."
      }

      if ($helpBlock.HasLegacySyntax) {
        "$($helpBlock.FunctionName) in $($helpBlock.FilePath) uses legacy .SYNOPSIS/.DESCRIPTION syntax."
      }

      if (-not $helpBlock.FirstLineIsDescription) {
        "$($helpBlock.FunctionName) in $($helpBlock.FilePath) must start its help block with 'Description: ...'."
      }

      if (-not $helpBlock.HasAllFields) {
        "$($helpBlock.FunctionName) in $($helpBlock.FilePath) must include all required fields: $($requiredFields -join ', '). Found: $($helpBlock.ActualFields -join ', ')."
      }

      if (-not $helpBlock.HasExpectedOrder) {
        "$($helpBlock.FunctionName) in $($helpBlock.FilePath) must order fields as Description, AppliesTo, Scope, Category, Impact, [Tags optional], Uses. Found: $($helpBlock.ActualFields -join ', ')."
      }

      if ($helpBlock.BlockText) {
        $appliesToMatch = [regex]::Match($helpBlock.BlockText, '(?im)^AppliesTo:\s*(.+)$')
        if ($appliesToMatch.Success) {
          $appliesToValue = $appliesToMatch.Groups[1].Value.Trim()
          if ($appliesToValue -notin $allowedAppliesTo) {
            "$($helpBlock.FunctionName) in $($helpBlock.FilePath) has unsupported AppliesTo value '$appliesToValue'."
          }
        }

        $scopeMatch = [regex]::Match($helpBlock.BlockText, '(?im)^Scope:\s*(.+)$')
        if ($scopeMatch.Success) {
          $scopeValue = $scopeMatch.Groups[1].Value.Trim()
          if ($scopeValue -notin $allowedScopes) {
            "$($helpBlock.FunctionName) in $($helpBlock.FilePath) has unsupported Scope value '$scopeValue'."
          }
        }

        $categoryMatch = [regex]::Match($helpBlock.BlockText, '(?im)^Category:\s*(.+)$')
        if ($categoryMatch.Success) {
          $categoryParts = @($categoryMatch.Groups[1].Value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
          if ($categoryParts.Count -eq 0) {
            "$($helpBlock.FunctionName) in $($helpBlock.FilePath) must provide at least one Category value."
          } else {
            foreach ($categoryPart in $categoryParts) {
              if ($categoryPart -notin $allowedCategories) {
                "$($helpBlock.FunctionName) in $($helpBlock.FilePath) has unsupported Category value '$categoryPart'."
              }
            }
          }
        }

        $impactMatch = [regex]::Match($helpBlock.BlockText, '(?im)^Impact:\s*(.+)$')
        if ($impactMatch.Success) {
          $impactValue = $impactMatch.Groups[1].Value.Trim()
          $impactOk = $impactValue -match '^low$' -or $impactValue -match '^(Medium|High)\((CPU|Disk|Network|RAM|Time)\)(,\s*(Medium|High)\((CPU|Disk|Network|RAM|Time)\))*$'
          if (-not $impactOk) {
            "$($helpBlock.FunctionName) in $($helpBlock.FilePath) has unsupported Impact value '$impactValue'."
          }
        }

        $tagsMatch = [regex]::Match($helpBlock.BlockText, '(?im)^Tags:\s*(.+)$')
        if ($tagsMatch.Success) {
          $tagValues = @($tagsMatch.Groups[1].Value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
          foreach ($tagValue in $tagValues) {
            if ($tagValue -notin $allowedTags) {
              "$($helpBlock.FunctionName) in $($helpBlock.FilePath) has unsupported Tag value '$tagValue'."
            }
          }
        }

        $usesMatch = [regex]::Match($helpBlock.BlockText, '(?im)^Uses:\s*(.+)$')
        if ($usesMatch.Success) {
          $usesValue = $usesMatch.Groups[1].Value.Trim()
          if ($usesValue -ne 'None.') {
            $useEntries = @($usesValue.TrimEnd('.') -split ',\s*' | Where-Object { $_ })
            if ($useEntries.Count -gt 3) {
              "$($helpBlock.FunctionName) in $($helpBlock.FilePath) lists more than three Uses entries."
            }

          }
        }
      }
    }

    @($violations) | Should -BeNullOrEmpty
  }
}
