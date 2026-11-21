# HostRequirement: DC

function HealthTest-DfsrBacklog {
<#
Description: Checks DFS Replication backlog and warns when queued updates are high.
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-DfsrConnection, Get-ADDomainController, DFS Replication CIM provider.
#>
    param([string]$RGName = 'Domain System Volume')

    if (-not (Get-Service DFSR -ErrorAction SilentlyContinue)) {
        Write-Output 'No DFSR service; skipping HealthTest-DfsrBacklog.'
        return
    }

    $isSysvol = $RGName -eq 'Domain System Volume'
    $discoveryCommand = if ($isSysvol) { 'Get-ADDomainController' } else { 'Get-DfsrConnection' }
    if (-not (Get-Command $discoveryCommand -ErrorAction SilentlyContinue)) {
        Write-Warning "[WARNING] DFS-R backlog discovery is unavailable for '$RGName'`nRequired cmdlet: $discoveryCommand."
        return
    }

    $namespace = 'root\MicrosoftDfs'
    $localDomain = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName
    $sessions = @{}
    $foldersByComputer = @{}
    $incomplete = $false
    $highBacklogs = [System.Collections.Generic.List[string]]::new()

    function Get-DfsrFolders([string]$ComputerName) {
        if (-not $sessions.ContainsKey($ComputerName)) {
            if ($ComputerName -in $env:COMPUTERNAME, "$env:COMPUTERNAME.$localDomain") {
                $sessions[$ComputerName] = New-CimSession -ErrorAction Stop
            } else {
                $dcom = New-CimSessionOption -Protocol Dcom
                $sessions[$ComputerName] = New-CimSession -ComputerName $ComputerName -SessionOption $dcom -OperationTimeoutSec 15 -ErrorAction Stop
            }
        }
        if (-not $foldersByComputer.ContainsKey($ComputerName)) {
            $foldersByComputer[$ComputerName] = @(Get-CimInstance -CimSession $sessions[$ComputerName] -Namespace $namespace -ClassName DfsrReplicatedFolderInfo -OperationTimeoutSec 15 -ErrorAction Stop |
                Where-Object { $_.ReplicationGroupName -eq $RGName -and (-not $isSysvol -or $_.ReplicatedFolderName -eq 'SYSVOL Share') })
        }
        return $foldersByComputer[$ComputerName]
    }

    try {
        try {
            $connections = if ($isSysvol) {
                # Get-DfsrConnection does not enumerate the built-in SYSVOL group's
                # topology. The provider exposes each member's direct connections.
                $controllers = @(Get-ADDomainController -Filter * -ErrorAction Stop)
                if (-not $controllers) { throw 'The domain controller lookup returned no hosts.' }

                foreach ($controller in $controllers) {
                    $memberName = $controller.HostName
                    try {
                        $folders = @(Get-DfsrFolders $memberName)
                        if ($folders.Count -ne 1) { throw 'The provider did not return exactly one SYSVOL Share folder.' }
                        $groupId = [guid]::Parse($folders[0].ReplicationGroupGuid)
                        $configs = Get-CimInstance -CimSession $sessions[$memberName] -Namespace $namespace -ClassName DfsrConnectionConfig -OperationTimeoutSec 15 -ErrorAction Stop
                        foreach ($config in $configs) {
                            if ([guid]::Parse($config.ReplicationGroupGuid) -ne $groupId -or $config.Inbound) { continue }
                            $partner = if ($config.PartnerDns) { $config.PartnerDns } else { $config.PartnerName }
                            [pscustomobject]@{ SourceComputerName = $memberName; DestinationComputerName = $partner }
                        }
                    } catch {
                        $incomplete = $true
                        Write-Warning "[WARNING] Could not discover SYSVOL replication connections`n$($memberName): $($_.Exception.Message)"
                    }
                }
            } else {
                Get-DfsrConnection -GroupName $RGName -ErrorAction Stop
            }
        } catch {
            Write-Warning "[WARNING] Could not discover DFS-R connections for '$RGName'`n$($_.Exception.Message)"
            return
        }

        foreach ($connection in $connections) {
            $source = $connection.SourceComputerName
            $destination = $connection.DestinationComputerName
            $route = "$source -> $destination"
            try {
                if (-not $source -or -not $destination) { throw 'The connection is missing an endpoint.' }
                $sourceFolders = @(Get-DfsrFolders $source)
                $destinationFolders = @(Get-DfsrFolders $destination)
                $matched = $false

                foreach ($sourceFolder in $sourceFolders) {
                    $folderName = $sourceFolder.ReplicatedFolderName
                    $matchingFolders = @($destinationFolders | Where-Object { $_.ReplicatedFolderName -eq $folderName })
                    if (-not $matchingFolders) { continue }
                    $matched = $true

                    try {
                        if ($matchingFolders.Count -ne 1) { throw 'The destination returned an ambiguous folder.' }
                        $destinationFolder = $matchingFolders[0]
                        if ([guid]::Parse($sourceFolder.ReplicationGroupGuid) -ne [guid]::Parse($destinationFolder.ReplicationGroupGuid) -or
                            [guid]::Parse($sourceFolder.ReplicatedFolderGuid) -ne [guid]::Parse($destinationFolder.ReplicatedFolderGuid)) {
                            throw 'The source and destination returned different folder identities.'
                        }

                        $vector = Invoke-CimMethod -CimSession $sessions[$destination] -InputObject $destinationFolder -MethodName GetVersionVector -OperationTimeoutSec 15 -ErrorAction Stop
                        if ($vector.ReturnValue -ne 0 -or [string]::IsNullOrWhiteSpace($vector.VersionVector)) {
                            throw "GetVersionVector returned status '$($vector.ReturnValue)' or no vector."
                        }
                        $total = Invoke-CimMethod -CimSession $sessions[$source] -InputObject $sourceFolder -MethodName GetOutboundBacklogFileCount -Arguments @{ VersionVector = $vector.VersionVector } -OperationTimeoutSec 15 -ErrorAction Stop
                        $count = [uint32]0
                        if ($total.ReturnValue -ne 0 -or -not [uint32]::TryParse([string]$total.BacklogFileCount, [ref]$count)) {
                            throw "GetOutboundBacklogFileCount returned status '$($total.ReturnValue)' or no valid count."
                        }
                        if ($count -gt 1000) { $highBacklogs.Add("$route ($folderName): $count") }
                    } catch {
                        $incomplete = $true
                        Write-Warning "[WARNING] Could not read DFS-R backlog`n$route ($folderName): $($_.Exception.Message)"
                    }
                }

                if (-not $matched) { throw 'The provider returned no shared replicated folder.' }
            } catch {
                $incomplete = $true
                Write-Warning "[WARNING] Could not read DFS-R backlog`n$($route): $($_.Exception.Message)"
            }
        }
    } finally {
        foreach ($session in $sessions.Values) {
            Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue
        }
    }

    if ($highBacklogs.Count -gt 0) {
        Write-Warning "[WARNING] DFS-R backlog high`n$($highBacklogs -join ' | ')"
    } elseif (-not $incomplete) {
        if ($connections) {
            Write-Warning '[PASS] DFS-R backlog OK'
        } else {
            Write-Warning "[INFO] No DFS-R connections found for '$RGName'"
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    HealthTest-DfsrBacklog
}
