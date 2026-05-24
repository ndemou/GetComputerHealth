Describe 'HealthTest-StaleRdpSessions message formatting' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $repoRoot 'health-tests\win-os-hyg.ps1')
  }

  It 'does not include a session number in disconnected session synopsis and omits extra timing fields' {
    $script:captured = @()

    Mock Get-LiveSessionInfo {
      @(
        [pscustomobject]@{
          SessionId = 2
          State = 'WTSDisconnected'
          SessionName = $null
          UserName = 'mvarto-admin'
          UserPrincipal = 'CONTOSO\jane-admin'
          LogonTime = [datetime]'2026-05-19 12:44:16'
          ConnectTime = [datetime]'2026-05-19 12:44:12'
          DisconnectTime = [datetime]'2026-05-19 12:45:47'
          LastInputTime = [datetime]'2026-05-19 12:45:47'
          DisconnectedTime = [timespan]::FromHours(9)
          IdleTime = [timespan]'5.02:46:35.4570867'
          SessionAge = [timespan]'5.02:48:06.4696412'
          ClientName = $null
          ClientAddress = $null
          Protocol = 'ConsoleOrUnknown'
        }
      )
    }

    Mock Write-Warning {
      param($Message)
      $script:captured += $Message
    }

    HealthTest-StaleRdpSessions -Threshold ([timespan]::FromHours(8))

    $script:captured.Count | Should -BeGreaterThan 0
    ($script:captured -join "`n") | Should -Match 'User CONTOSO\\jane-admin has a disconnected session for more than 8 hours'
    ($script:captured -join "`n") | Should -Not -Match 'Session 2 for'
    ($script:captured -join "`n") | Should -Not -Match 'ConnectTime:'
    ($script:captured -join "`n") | Should -Not -Match 'DisconnectTime:'
    ($script:captured -join "`n") | Should -Not -Match 'DisconnectedTime:'
    ($script:captured -join "`n") | Should -Not -Match 'SessionAge:'
  }
}
