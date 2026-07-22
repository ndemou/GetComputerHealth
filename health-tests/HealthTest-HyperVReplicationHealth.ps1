<#
Standalone file for HealthTest-HyperVReplicationHealth.
Generated during the repo-wide health-test split.
#>
# HostRequirement: HyperV

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
            [AllowNull()][object]$ReplicationInfo
        )

        if ($null -eq $ReplicationInfo) {
            return $null
        }

        foreach ($propertyName in @('LastReplicationTime', 'LastSuccessfulReplicationTime', 'LastSuccessfulReplication', 'LastReplicatedTime')) {
            $prop = $ReplicationInfo.PSObject.Properties[$propertyName]
            if ($prop -and $null -ne $prop.Value -and "$($prop.Value)".Trim() -ne '') {
                return $prop.Value
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

        if ($Value -is [datetimeoffset]) {
            return ([datetimeoffset]$Value).LocalDateTime
        }

        $text = ([string]$Value).Trim()
        $parsed = [datetime]::MinValue
        $styles = [System.Globalization.DateTimeStyles]::AssumeLocal
        $culture = [System.Globalization.CultureInfo]::InvariantCulture

        # Do not use culture-sensitive free-form parsing here. Values such as
        # 05/06/2026 are ambiguous across locales, so only parse exact
        # unambiguous timestamp formats when Hyper-V does not provide a
        # strongly typed DateTime/DateTimeOffset value.
        $unambiguousFormats = @(
            'o',
            's',
            'u',
            'yyyy-MM-dd HH:mm:ss',
            'yyyy-MM-ddTHH:mm:ss',
            'yyyy-MM-dd HH:mm:ssK',
            'yyyy-MM-ddTHH:mm:ssK'
        )

        foreach ($format in $unambiguousFormats) {
            if ([datetime]::TryParseExact($text, $format, $culture, $styles, [ref]$parsed)) {
                return $parsed
            }
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
            $replicationDate = ConvertTo-ReplicationDateTime -Value $LastSuccessfulReplicationTime
            if ($null -ne $replicationDate) {
                $replicationTimeText = $replicationDate.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $replicationTimeText = [string]$LastSuccessfulReplicationTime
            }
            $details += "Last successful replication time: $replicationTimeText"
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
                Write-Warning "[FAILURE] Could not query replication details for VM '$($vm.Name)'.`n$($_.Exception.Message)"
                $hadIssue = $true
                continue
            }

            $lastSuccessfulReplicationTime = Get-LastSuccessfulReplicationTime -ReplicationInfo $replicationInfo
            $details = Get-ReplicationDetailText -Vm $vm -LastSuccessfulReplicationTime $lastSuccessfulReplicationTime
            switch -Regex ($replicationHealth) {
                '^(?i)Normal$' {
                }
                '^(?i)Warning$' {
                    $level = Get-ReplicationWarningLevel -LastSuccessfulReplicationTime $lastSuccessfulReplicationTime
                    Write-Warning "[$level] replication health for VM '$($vm.Name)' is at Warning state`n$details"
                    if ($level -ne 'INFO') {
                        $hadIssue = $true
                    }
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

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-HyperVReplicationHealth
}
