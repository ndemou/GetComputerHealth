Describe 'HealthTest-HyperVReplicationHealth' {
  BeforeAll {
    . (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'health-tests\HealthTest-HyperVReplicationHealth.ps1')

    function Get-VM {}
    function Get-VMReplication {}
  }

  BeforeEach {
    $script:warnings = @()
    $script:now = [datetime]'2026-05-18T10:45:00'
    $script:lastSuccessfulReplicationTime = $null

    Mock Get-Date { $script:now }
    Mock Get-VM {
      @(
        [pscustomobject]@{
          Name = 'SRV1(Win 2025)'
          ReplicationMode = 'Primary'
          ReplicationHealth = 'Warning'
          ReplicationState = 'Replicating'
          State = 'Off'
        }
      )
    }
    Mock Get-VMReplication {
      if ($null -eq $script:lastSuccessfulReplicationTime) {
        return [pscustomobject]@{}
      }

      return [pscustomobject]@{
        LastReplicationTime = $script:lastSuccessfulReplicationTime
      }
    }
    Mock Write-Warning { $script:warnings += $Message }
  }

  It 'emits <ExpectedLevel> for a Warning replication state last replicated <MinutesAgo> minutes ago' -TestCases @(
    @{ MinutesAgo = 4; ExpectedLevel = 'INFO'; ExpectedMessageCount = 2 }
    @{ MinutesAgo = 10; ExpectedLevel = 'NOTICE'; ExpectedMessageCount = 1 }
    @{ MinutesAgo = 30; ExpectedLevel = 'WARNING'; ExpectedMessageCount = 1 }
    @{ MinutesAgo = 41; ExpectedLevel = 'FAILURE'; ExpectedMessageCount = 1 }
  ) {
    param(
      [int]$MinutesAgo,
      [string]$ExpectedLevel,
      [int]$ExpectedMessageCount
    )

    $script:lastSuccessfulReplicationTime = $script:now.AddMinutes(-1 * $MinutesAgo)

    HealthTest-HyperVReplicationHealth

    $script:warnings | Should -HaveCount $ExpectedMessageCount
    $script:warnings[0] | Should -Match "^\[$ExpectedLevel\] replication health for VM 'SRV1\(Win 2025\)' is at Warning state"
    $script:warnings[0] | Should -Match 'ReplicationState: Replicating'
    $script:warnings[0] | Should -Match 'Last successful replication time: 2026-05-18 \d{2}:\d{2}:\d{2}'

    if ($ExpectedLevel -eq 'INFO') {
      $script:warnings[1] | Should -Be "[PASS] All Hyper-V VMs have healthy replication and no replica VM is running."
    }
  }

  It 'parses unambiguous ISO string replication times' {
    $script:lastSuccessfulReplicationTime = '2026-05-18T10:35:00'

    HealthTest-HyperVReplicationHealth

    $script:warnings | Should -HaveCount 1
    $script:warnings[0] | Should -Match "^\[NOTICE\] replication health for VM 'SRV1\(Win 2025\)' is at Warning state"
    $script:warnings[0] | Should -Match 'Last successful replication time: 2026-05-18 10:35:00'
  }

  It 'treats culture-ambiguous text replication times as missing' {
    $script:lastSuccessfulReplicationTime = '05/06/2026 10:43:17'

    HealthTest-HyperVReplicationHealth

    $script:warnings | Should -HaveCount 1
    $script:warnings[0] | Should -Match "^\[FAILURE\] replication health for VM 'SRV1\(Win 2025\)' is at Warning state"
    $script:warnings[0] | Should -Match 'Last successful replication time: 05/06/2026 10:43:17'
  }

  It 'emits FAILURE and skips derived warning-level findings when Get-VMReplication fails' {
    Mock Get-VMReplication { throw 'RPC server unavailable' }

    HealthTest-HyperVReplicationHealth

    $script:warnings | Should -HaveCount 1
    $script:warnings[0] | Should -Be "[FAILURE] Could not query replication details for VM 'SRV1(Win 2025)'.`nRPC server unavailable"
  }

  It 'emits FAILURE for a Warning replication state with no successful replication time' {
    HealthTest-HyperVReplicationHealth

    $script:warnings | Should -HaveCount 1
    $script:warnings[0] | Should -Be "[FAILURE] replication health for VM 'SRV1(Win 2025)' is at Warning state`nReplicationState: Replicating"
  }
}
