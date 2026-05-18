<#
Only for Hyper-V servers
#>

function HealthTest-HyperVRunningVMs {
<#
Description: Lists running Hyper-V virtual machines on the host.
AppliesTo: HyperV
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: Get-VM.
#>
    $ok=$true
    $all_vm = Get-VM
    $all_vm |?{$_.state -ne 'Running' -and $_.AutomaticStartAction -eq 'Start'} | %{
        Write-Warning "[FAILURE] VM $($_.name) should be running but is not"
        $ok=$false
    }
    if ($all_vm |?{$_.AutomaticStartAction -eq 'Start'}) {
        if ($ok) {Write-Warning "[PASS] All VMs that are set to always auto-start are running"}
    } else {
        Write-Warning "[info] No VM is set to always auto-start"
    }
}

function HealthTest-HyperVReplicationHealth {
<#
Description: Checks Hyper-V VM replication health, missing replication, and running replica VMs.
AppliesTo: HyperV
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-VM, Get-VMReplication.
#>
    function Get-LastSuccessfulReplicationTime {
        param(
            [Parameter(Mandatory)][object]$Vm,
            [AllowNull()][object]$ReplicationInfo
        )

        foreach ($source in @($ReplicationInfo, $Vm)) {
            if ($null -eq $source) { continue }
            foreach ($propertyName in @('LastReplicationTime', 'LastSuccessfulReplicationTime', 'LastSuccessfulReplication', 'LastReplicatedTime')) {
                $prop = $source.PSObject.Properties[$propertyName]
                if ($prop -and $null -ne $prop.Value -and "$($prop.Value)".Trim() -ne '') {
                    return $prop.Value
                }
            }
        }

        return $null
    }

    function ConvertTo-ReplicationDateTime {
        param(
            [AllowNull()][object]$Value
        )

        if ($null -eq $Value -or "$Value".Trim() -eq '') {
            return $null
        }

        if ($Value -is [datetime]) {
            return [datetime]$Value
        }

        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::CurrentCulture, [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsed)) {
            return $parsed
        }

        if ([datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsed)) {
            return $parsed
        }

        return $null
    }

    function Get-ReplicationWarningLevel {
        param(
            [AllowNull()][object]$LastSuccessfulReplicationTime
        )

        $lastSuccessfulReplicationDate = ConvertTo-ReplicationDateTime -Value $LastSuccessfulReplicationTime
        if ($null -eq $lastSuccessfulReplicationDate) {
            return 'FAILURE'
        }

        $age = (Get-Date) - $lastSuccessfulReplicationDate
        if ($age.TotalMinutes -le 5) { return 'INFO' }
        if ($age.TotalMinutes -le 20) { return 'NOTICE' }
        if ($age.TotalMinutes -le 40) { return 'WARNING' }

        return 'FAILURE'
    }

    function Get-ReplicationDetailText {
        param(
            [Parameter(Mandatory)][object]$Vm,
            [AllowNull()][object]$LastSuccessfulReplicationTime
        )

        $details = @()

        $state = $Vm.PSObject.Properties['ReplicationState']
        if ($state -and $null -ne $state.Value -and "$($state.Value)".Trim() -ne '') {
            $details += "ReplicationState: $($state.Value)"
        }

        if ($LastSuccessfulReplicationTime) {
            $details += "Last successful replication time: $LastSuccessfulReplicationTime"
        }

        if ($details.Count -eq 0) {
            return "No additional replication details available."
        }

        return ($details -join "`n")
    }

    $allVm = @(Get-VM)
    $hadIssue = $false

    foreach ($vm in $allVm) {
        $replicationMode = [string]$vm.ReplicationMode
        $replicationHealth = [string]$vm.ReplicationHealth
        $state = [string]$vm.State
        $replicationInfo = $null

        if ($replicationMode -in @('Primary', 'Replica')) {
            try {
                $replicationInfo = Get-VMReplication -VMName $vm.Name -ErrorAction Stop
            }
            catch {
            }

            $lastSuccessfulReplicationTime = Get-LastSuccessfulReplicationTime -Vm $vm -ReplicationInfo $replicationInfo
            $details = Get-ReplicationDetailText -Vm $vm -LastSuccessfulReplicationTime $lastSuccessfulReplicationTime
            switch -Regex ($replicationHealth) {
                '^(?i)Normal$' {
                }
                '^(?i)Warning$' {
                    $level = Get-ReplicationWarningLevel -LastSuccessfulReplicationTime $lastSuccessfulReplicationTime
                    Write-Warning "[$level] replication health for VM '$($vm.Name)' is at Warning state`n$details"
                    $hadIssue = $true
                }
                '^(?i)Critical$' {
                    Write-Warning "[FAILURE] replication health for VM '$($vm.Name)' is at Critical state`n$details"
                    $hadIssue = $true
                }
                default {
                    Write-Warning "[FAILURE] replication health for VM '$($vm.Name)' is at $replicationHealth state.`n$details"
                    $hadIssue = $true
                }
            }
        }
        elseif ($replicationMode -eq 'None') {
            Write-Warning "[WARNING] VM '$($vm.Name)' is not configured for replication"
            $hadIssue = $true
        }

        if ($state -eq 'Running' -and $replicationMode -eq 'Replica') {
            Write-Warning "[NOTICE] VM '$($vm.Name)' which is a Replica instead of a Primary is running`nThis is only OK during a Test Failover."
            $hadIssue = $true
        }
    }

    if (-not $hadIssue) {
        Write-Warning "[PASS] All Hyper-V VMs have healthy replication and no replica VM is running."
    }
}
