# HostRequirement: DC

function HealthTest-DfsrBacklog {
<#
Description: Checks DFS Replication backlog and warns when queued updates are high.
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: DFS Replication CIM provider, Get-DfsrConnection, Get-ADDomainController or DNS.
#>
    param(
        [string]$RGName = 'Domain System Volume',
        [string]$Domain
    )

    $isSysvol = $RGName -eq 'Domain System Volume'
    $runFromCollector = $isSysvol -and $Domain
    if (-not $runFromCollector -and -not (Get-Service DFSR -ErrorAction SilentlyContinue)) {
        Write-Output 'No DFSR service; skipping HealthTest-DfsrBacklog.'
        return
    }

    $discoveryCommand = if ($isSysvol) { 'Get-ADDomainController' } else { 'Get-DfsrConnection' }
    if (-not $runFromCollector -and -not (Get-Command $discoveryCommand -ErrorAction SilentlyContinue)) {
        Write-Warning "[WARNING] DFS-R backlog discovery is unavailable for '$RGName'`nRequired cmdlet: $discoveryCommand."
        return
    }

    $namespace = 'root\MicrosoftDfs'
    $localDomain = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName
    $members = @{}
    $incomplete = $false
    $measuredBacklogs = [System.Collections.Generic.List[string]]::new()
    $highBacklogs = [System.Collections.Generic.List[string]]::new()

    function Get-DfsrMember([string]$ComputerName) {
        $member = $members[$ComputerName]
        if (-not $member) {
            $member = [pscustomobject]@{ Session = $null; Folders = $null; QueryError = $null }
            $members[$ComputerName] = $member
        }
        if ($member.QueryError) { throw $member.QueryError }
        if ($null -ne $member.Folders) { return $member }

        try {
            if (-not $member.Session) {
                $member.Session = if ($runFromCollector) {
                    # New-CimSession uses WSMan when a computer name is supplied.
                    New-CimSession -ComputerName $ComputerName -OperationTimeoutSec 15 -ErrorAction Stop
                } elseif ($ComputerName -in $env:COMPUTERNAME, "$env:COMPUTERNAME.$localDomain") {
                    New-CimSession -ErrorAction Stop
                } else {
                    $dcom = New-CimSessionOption -Protocol Dcom
                    New-CimSession -ComputerName $ComputerName -SessionOption $dcom -OperationTimeoutSec 15 -ErrorAction Stop
                }
            }
            $folders = @(Get-CimInstance -CimSession $member.Session -Namespace $namespace -ClassName DfsrReplicatedFolderInfo -OperationTimeoutSec 15 -ErrorAction Stop |
                Where-Object { $_.ReplicationGroupName -eq $RGName -and (-not $isSysvol -or $_.ReplicatedFolderName -eq 'SYSVOL Share') })
            if ($isSysvol -and $folders.Count -ne 1) { throw 'The provider did not return exactly one SYSVOL Share folder.' }
            $member.Folders = $folders
            return $member
        } catch {
            if ($runFromCollector) { $member.QueryError = $_.Exception }
            throw
        }
    }

    try {
        try {
            $connections = if ($isSysvol) {
                # Get-DfsrConnection does not enumerate the built-in SYSVOL group's
                # topology. The provider exposes each member's direct connections.
                $controllers = if ($runFromCollector) {
                    Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$Domain" -Type SRV -DnsOnly -ErrorAction Stop |
                        Where-Object Type -eq SRV |
                        ForEach-Object { $_.NameTarget.TrimEnd('.') } |
                        Sort-Object -Unique
                } else {
                    (Get-ADDomainController -Filter * -ErrorAction Stop).HostName
                }
                if (-not $controllers) { throw 'The domain controller lookup returned no hosts.' }

                # Either endpoint can describe a direction when its peer cannot be queried.
                $connectionsByRoute = [ordered]@{}
                foreach ($memberName in $controllers) {
                    try {
                        $member = Get-DfsrMember $memberName
                        $groupId = [guid]::Parse($member.Folders[0].ReplicationGroupGuid)
                        $configs = Get-CimInstance -CimSession $member.Session -Namespace $namespace -ClassName DfsrConnectionConfig -OperationTimeoutSec 15 -ErrorAction Stop
                        foreach ($config in $configs) {
                            if ([guid]::Parse($config.ReplicationGroupGuid) -ne $groupId) { continue }
                            $partner = if ($config.PartnerDns) { $config.PartnerDns.TrimEnd('.') } else { $config.PartnerName }
                            if ($runFromCollector -and $partner -and $partner -notlike '*.*') { $partner = "$partner.$Domain" }
                            $source = $memberName
                            $destination = $partner
                            if ($config.Inbound) {
                                $source = $partner
                                $destination = $memberName
                            }
                            $connectionsByRoute["$source -> $destination"] = [pscustomobject]@{
                                SourceComputerName = $source
                                DestinationComputerName = $destination
                            }
                        }
                    } catch {
                        $incomplete = $true
                        Write-Warning "[WARNING] Could not discover SYSVOL replication connections`n$($memberName): $($_.Exception.Message)"
                    }
                }
                $connectionsByRoute.Values
            } else {
                Get-DfsrConnection -GroupName $RGName -ErrorAction Stop
            }
        } catch {
            $groupLabel = if ($runFromCollector) { "'$RGName' in '$Domain'" } else { "'$RGName'" }
            Write-Warning "[WARNING] Could not discover DFS-R connections for $groupLabel`n$($_.Exception.Message)"
            return
        }

        foreach ($connection in $connections) {
            $source = $connection.SourceComputerName
            $destination = $connection.DestinationComputerName
            $route = "$source -> $destination"
            try {
                if (-not $source -or -not $destination) { throw 'The connection is missing an endpoint.' }
                $sourceMember = Get-DfsrMember $source
                $destinationMember = Get-DfsrMember $destination
                $matched = $false

                foreach ($sourceFolder in $sourceMember.Folders) {
                    $folderName = $sourceFolder.ReplicatedFolderName
                    $matchingFolders = @($destinationMember.Folders | Where-Object { $_.ReplicatedFolderName -eq $folderName })
                    if (-not $matchingFolders) { continue }
                    $matched = $true

                    try {
                        if ($matchingFolders.Count -ne 1) { throw 'The destination returned an ambiguous folder.' }
                        $destinationFolder = $matchingFolders[0]
                        if ([guid]::Parse($sourceFolder.ReplicationGroupGuid) -ne [guid]::Parse($destinationFolder.ReplicationGroupGuid) -or
                            [guid]::Parse($sourceFolder.ReplicatedFolderGuid) -ne [guid]::Parse($destinationFolder.ReplicatedFolderGuid)) {
                            throw 'The source and destination returned different folder identities.'
                        }

                        $vector = Invoke-CimMethod -CimSession $destinationMember.Session -InputObject $destinationFolder -MethodName GetVersionVector -OperationTimeoutSec 15 -ErrorAction Stop
                        if ($vector.ReturnValue -ne 0 -or [string]::IsNullOrWhiteSpace($vector.VersionVector)) {
                            throw "GetVersionVector returned status '$($vector.ReturnValue)' or no vector."
                        }
                        $total = Invoke-CimMethod -CimSession $sourceMember.Session -InputObject $sourceFolder -MethodName GetOutboundBacklogFileCount -Arguments @{ VersionVector = $vector.VersionVector } -OperationTimeoutSec 15 -ErrorAction Stop
                        $count = [uint32]0
                        if ($total.ReturnValue -ne 0 -or -not [uint32]::TryParse([string]$total.BacklogFileCount, [ref]$count)) {
                            throw "GetOutboundBacklogFileCount returned status '$($total.ReturnValue)' or no valid count."
                        }
                        if ($count -gt 1000) {
                            if ($isSysvol) {
                                Write-Warning "[WARNING] DFS-R backlog high`n$route ($folderName): $count queued files"
                            } else {
                                $highBacklogs.Add("$route ($folderName): $count")
                            }
                        } elseif ($isSysvol) {
                            $measuredBacklogs.Add("$route ($folderName): $count queued files")
                        }
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
        foreach ($member in $members.Values) {
            if ($member.Session) { Remove-CimSession -CimSession $member.Session -ErrorAction SilentlyContinue }
        }
    }

    if ($isSysvol -and $connections) {
        $result = if ($incomplete) { '[INFO] DFS-R backlog measured' } else { '[PASS] DFS-R backlog OK' }
        foreach ($backlog in $measuredBacklogs) {
            Write-Warning "$result`n$backlog"
        }
    } elseif ($highBacklogs.Count -gt 0) {
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
