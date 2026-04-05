Describe 'HealthTest help blocks' {
  It 'all HealthTest-* functions have the required help block format' {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $healthTestsPath = Join-Path $repoRoot 'health-tests'
    $requiredFields = @('Description', 'AppliesTo', 'Scope', 'Category', 'Impact', 'Uses')
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
          HasHelpBlock            = $blockMatch.Success
          ActualFields            = $actualFields
          HasLegacySyntax         = $blockText -match '(?im)^\s*\.(SYNOPSIS|DESCRIPTION)\b'
          FirstLineIsDescription  = (@($lines).Count -gt 0) -and $lines[0] -match '^Description:\s+\S+'
          HasAllFields            = @($requiredFields | Where-Object { $_ -in $actualFields }).Count -eq $requiredFields.Count
          HasExpectedOrder        = (@($actualFields).Count -ge $requiredFields.Count) -and ((@($actualFields)[0..($requiredFields.Count - 1)] -join '|') -eq ($requiredFields -join '|'))
        }
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
        "$($helpBlock.FunctionName) in $($helpBlock.FilePath) must order fields as: $($requiredFields -join ', '). Found: $($helpBlock.ActualFields -join ', ')."
      }
    }

    @($violations) | Should -BeNullOrEmpty
  }
}
