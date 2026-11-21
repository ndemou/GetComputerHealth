# HostRequirement: DC

function HealthTest-DfsReplicationState {
<#
Description: Checks whether DFS Replication folders are in the Normal state.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: None.
#>
  $stateNames = @{0='Uninitialized';1='Initialized';2='Initial_Sync';3='Auto_Recovery';4='Normal';5='Error'}

  $repl = Get-CimInstance -Namespace 'root\MicrosoftDFS' -ClassName 'DfsrReplicatedFolderInfo' -ErrorAction SilentlyContinue |
          Select-Object ReplicatedFolderName, ReplicationGroupName, state

  if (-not $repl) {
    Write-Warning "[FAILURE] Could not query DFSR state (class root\MicrosoftDFS:DfsrReplicatedFolderInfo not found or no data).`nIs DFS Replication installed and running? Do you have permissions?"
    return
  }

  $notNormal = $repl | Where-Object { $_.state -ne 4 }

  foreach ($r in $notNormal) {
    $name = $stateNames[[int]$r.state]
    if (-not $name) { $name = 'Unknown' }
    if ($r.state -in 1,2,3) {
      Write-Warning "[WARNING] DFSR replication for '$($r.ReplicatedFolderName)' is at state $($r.state) ($name) instead of 4 (Normal)"
    } else {
      $details = "Group: $($r.ReplicationGroupName). States: 0 Uninitialized, 1 Initialized, 2 Initial_Sync, 3 Auto_Recovery, 4 Normal, 5 Error."
      Write-Warning "[FAILURE] DFSR replication for '$($r.ReplicatedFolderName)' is at state $($r.state) ($name) instead of 4 (Normal)`n$details"
    }
  }

  if (-not $notNormal) {
    Write-Warning "[PASS] All DFSR replications are at state 4 (Normal)"
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-DfsReplicationState
}
