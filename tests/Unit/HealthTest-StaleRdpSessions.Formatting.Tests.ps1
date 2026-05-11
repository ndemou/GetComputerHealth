Describe 'HealthTest-StaleRdpSessions message formatting' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $repoRoot 'health-tests\win-os-hyg.ps1')
  }

  It 'does not include a session number in disconnected session synopsis' {
    $script:captured = @()

    Mock Get-LiveSessionInfo {
      @(
        [pscustomobject]@{
          SessionId = 2
          State = 'WTSDisconnected'
          SessionName = $null
          UserName = 'mvarto-admin'
          UserPrincipal = 'CONTOSO\jane-admin'
          LogonTime = $null
          ConnectTime = $null
          DisconnectTime = $null
          LastInputTime = $null
          DisconnectedTime = [timespan]::FromHours(9)
          IdleTime = [timespan]::FromMinutes(1)
          SessionAge = $null
          ClientName = $null
          ClientAddress = $null
          Protocol = $null
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
  }
}
