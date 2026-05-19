Describe 'HealthTest-HyperVReplicationHealth' {
  BeforeAll {
    . (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'health-tests\OnlyIfHostIs-HyperV.ps1')

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
    @{ MinutesAgo = 10; ExpectedLevel = 'NOTICE' }
    @{ MinutesAgo = 30; ExpectedLevel = 'WARNING' }
    @{ MinutesAgo = 41; ExpectedLevel = 'FAILURE' }
  ) {
    param(
      [int]$MinutesAgo,
      [string]$ExpectedLevel
    )

    $script:lastSuccessfulReplicationTime = $script:now.AddMinutes(-1 * $MinutesAgo)

    HealthTest-HyperVReplicationHealth

    $script:warnings | Should -HaveCount 1
    $script:warnings[0] | Should -Match "^\[$ExpectedLevel\] replication health for VM 'SRV1\(Win 2025\)' is at Warning state"
    $script:warnings[0] | Should -Match 'ReplicationState: Replicating'
    $script:warnings[0] | Should -Match 'Last successful replication time:'
  }

  It 'does not treat INFO warning-level replication as an issue and emits PASS summary' {
    $script:lastSuccessfulReplicationTime = $script:now.AddMinutes(-4)

    HealthTest-HyperVReplicationHealth

    $script:warnings | Should -HaveCount 2
    $script:warnings[0] | Should -Match "^\[INFO\] replication health for VM 'SRV1\(Win 2025\)' is at Warning state"
    $script:warnings[1] | Should -Be "[PASS] All Hyper-V VMs have healthy replication and no replica VM is running."
  }

  It 'parses unambiguous ISO string replication times' {
    $script:lastSuccessfulReplicationTime = '2026-05-18T10:35:00'

    HealthTest-HyperVReplicationHealth

    $script:warnings | Should -HaveCount 1
    $script:warnings[0] | Should -Match "^\[NOTICE\] replication health for VM 'SRV1\(Win 2025\)' is at Warning state"
    $script:warnings[0] | Should -Match 'Last successful replication time: 2026-05-18T10:35:00'
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
