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
    @{ MinutesAgo = 4; ExpectedLevel = 'INFO' }
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

  It 'emits FAILURE for a Warning replication state with no successful replication time' {
    HealthTest-HyperVReplicationHealth

    $script:warnings | Should -HaveCount 1
    $script:warnings[0] | Should -Be "[FAILURE] replication health for VM 'SRV1(Win 2025)' is at Warning state`nReplicationState: Replicating"
  }
}
