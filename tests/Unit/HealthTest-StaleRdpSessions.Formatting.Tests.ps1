Describe 'HealthTest-DesktopSessions message formatting' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $repoRoot 'health-tests\win-os-hyg.ps1')
  }

  It 'does not include a session number in disconnected session synopsis and omits extra timing fields' {
    $script:captured = @()

    Mock Get-CimInstance {
      [pscustomobject]@{
        FreePhysicalMemory = 1024 * 1024
      }
    } -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' }

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
          ProcessCount = 5
          CPUPercent = 3.2
          MemoryMB = 42.5
          IO_MBps = 0.125
        }
      )
    }

    Mock Write-Warning {
      param($Message)
      $script:captured += $Message
    }

    HealthTest-DesktopSessions -Threshold ([timespan]::FromHours(8))

    $script:captured.Count | Should -BeGreaterThan 0
    ($script:captured -join "`n") | Should -Match 'User CONTOSO\\jane-admin has a disconnected session for more than 8 hours'
    ($script:captured -join "`n") | Should -Not -Match 'Session 2 for'
    ($script:captured -join "`n") | Should -Not -Match 'ConnectTime:'
    ($script:captured -join "`n") | Should -Not -Match 'DisconnectTime:'
    ($script:captured -join "`n") | Should -Not -Match 'DisconnectedTime:'
    ($script:captured -join "`n") | Should -Not -Match 'SessionAge:'
    ($script:captured -join "`n") | Should -Match 'ProcessCount: 5'
    ($script:captured -join "`n") | Should -Match 'CPUPercent: 3.2%'
    ($script:captured -join "`n") | Should -Match 'MemoryMB: 42.5'
    ($script:captured -join "`n") | Should -Match 'IO_MBps: 0.125'
  }

  It 'adds independent warnings when a disconnected session heavily impacts RAM and CPU even if it is not stale' {
    $script:captured = @()

    Mock Get-CimInstance {
      [pscustomobject]@{
        FreePhysicalMemory = 500 * 1024
      }
    } -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' }

    Mock Get-LiveSessionInfo {
      @(
        [pscustomobject]@{
          SessionId = 7
          State = 'WTSDisconnected'
          SessionName = 'rdp-tcp#2'
          UserName = 'jane-admin'
          UserPrincipal = 'CONTOSO\jane-admin'
          LogonTime = [datetime]'2026-05-19 12:44:16'
          LastInputTime = [datetime]'2026-05-19 12:45:47'
          DisconnectedTime = [timespan]::FromHours(2)
          IdleTime = [timespan]::FromHours(2)
          ClientName = 'ws-22'
          ClientAddress = '10.0.0.22'
          Protocol = 'RDP'
          ProcessCount = 8
          CPUPercent = 27.4
          MemoryMB = 150.0
          IO_MBps = 1.75
        }
      )
    }

    Mock Write-Warning {
      param($Message)
      $script:captured += $Message
    }

    HealthTest-DesktopSessions -Threshold ([timespan]::FromHours(8))

    $script:captured.Count | Should -Be 2
    $script:captured[0] | Should -Match 'materially impacting RAM availability'
    $script:captured[1] | Should -Match 'considerable CPU usage'
    ($script:captured -join "`n") | Should -Match 'ProcessCount: 8'
    ($script:captured -join "`n") | Should -Match 'CPUPercent: 27.4%'
    ($script:captured -join "`n") | Should -Match 'MemoryMB: 150'
    ($script:captured -join "`n") | Should -Match 'IO_MBps: 1.75'
  }
}
