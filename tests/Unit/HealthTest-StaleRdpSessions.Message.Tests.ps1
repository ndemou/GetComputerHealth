Describe 'HealthTest-StaleRdpSessions message formatting' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $scriptPath = Join-Path $repoRoot 'health-tests\win-os-hyg.ps1'

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
      throw "Failed to parse $scriptPath"
    }

    $funcAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'HealthTest-StaleRdpSessions'
      }, $true)

    if ($null -eq $funcAst) {
      throw "Function not found in ${scriptPath}: HealthTest-StaleRdpSessions"
    }

    . ([scriptblock]::Create($funcAst.Extent.Text))
  }

  It 'omits session id from the notice synopsis' {
    $script:capturedWarnings = @()

    Mock Get-LiveSessionInfo {
      [pscustomobject]@{
        SessionId        = 2
        UserName         = 'mvarto-admin'
        UserPrincipal    = 'MAZARS-GR\mvarto-admin'
        State            = 'WTSDisconnected'
        DisconnectedTime = [TimeSpan]::FromHours(9)
        IdleTime         = [TimeSpan]::FromHours(0)
      }
    }

    Mock Write-Warning {
      param($Message)
      $script:capturedWarnings += $Message
    }

    HealthTest-StaleRdpSessions -Threshold ([TimeSpan]::FromHours(8))

    ($script:capturedWarnings -join "`n") | Should -Match 'Session for MAZARS-GR\\mvarto-admin is disconnected for more than 8 hours'
    ($script:capturedWarnings -join "`n") | Should -Not -Match 'Session 2 for'
  }
}
