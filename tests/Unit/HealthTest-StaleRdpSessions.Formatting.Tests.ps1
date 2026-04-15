Describe 'HealthTest-StaleRdpSessions message formatting' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $scriptPath = Join-Path $repoRoot 'health-tests\win-os-hyg.ps1'

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)

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

  It 'does not include a session number in disconnected session synopsis' {
    $captured = @()

    Mock Get-LiveSessionInfo {
      @(
        [pscustomobject]@{
          SessionId = 2
          State = 'WTSDisconnected'
          UserName = 'mvarto-admin'
          UserPrincipal = 'CONTOSO\jane-admin'
          DisconnectedTime = [timespan]::FromHours(9)
          IdleTime = [timespan]::FromMinutes(1)
        }
      )
    }

    Mock Write-Warning {
      param($Message)
      $script:captured += $Message
    }

    HealthTest-StaleRdpSessions -Threshold ([timespan]::FromHours(8))

    $captured.Count | Should -BeGreaterThan 0
    ($captured -join "`n") | Should -Match 'User CONTOSO\\jane-admin has a disconnected session for more than 8 hours'
    ($captured -join "`n") | Should -Not -Match 'Session 2 for'
  }
}
