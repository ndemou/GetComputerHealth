Describe 'HealthTest-DfsReplicationState' {
  BeforeAll {
    . "$PSScriptRoot\..\..\health-tests\HealthTest-DfsReplicationState.ps1"
  }

  It 'reports state 5 as a failure with the replication group and state legend' {
    Mock Get-CimInstance {
      [pscustomobject]@{
        ReplicatedFolderName = 'Test folder'
        ReplicationGroupName = 'Test group'
        State = 5
      }
    }

    $findings = @(HealthTest-DfsReplicationState 3>&1)

    $findings | Should -HaveCount 1
    $lines = $findings[0].Message -split "`n", 2
    $lines[0] | Should -BeExactly "[FAILURE] DFSR replication for 'Test folder' is at state 5 (Error) instead of 4 (Normal)"
    $lines[1] | Should -BeExactly 'Group: Test group. States: 0 Uninitialized, 1 Initialized, 2 Initial_Sync, 3 Auto_Recovery, 4 Normal, 5 Error.'
  }
}
