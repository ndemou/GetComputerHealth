Describe 'HealthTest-DfsrBacklog' {
    BeforeAll {
        . "$PSScriptRoot\..\..\health-tests\HealthTest-DfsrBacklog.ps1"

        function Get-DfsrConnection { [CmdletBinding()] param($GroupName) }
        function Get-DfsrBacklog { [CmdletBinding()] param() }
        function Get-ADDomainController { [CmdletBinding()] param($Filter) }
        function New-CimSession { [CmdletBinding()] param($ComputerName, $SessionOption, $OperationTimeoutSec) }
        function Get-CimInstance { [CmdletBinding()] param($CimSession, $Namespace, $ClassName, $OperationTimeoutSec) }
        function Invoke-CimMethod { [CmdletBinding()] param($CimSession, $InputObject, $MethodName, $Arguments, $OperationTimeoutSec) }
        function Remove-CimSession { [CmdletBinding()] param($CimSession) }
    }

    BeforeEach {
        $script:group = 'TestGroup'
        $script:folder = 'Data'
        $script:missingComputer = $null
        $script:vectorFailure = $null
        $script:total = 0
        $script:connections = @([pscustomobject]@{ SourceComputerName = 'NODEA'; DestinationComputerName = 'NODEB' })
        Mock Get-Service { [pscustomobject]@{ Name = 'DFSR' } }
        Mock Get-DfsrConnection { $script:connections }
        Mock Get-DfsrBacklog { 1..100 }
        Mock Get-ADDomainController {
            [pscustomobject]@{ HostName = 'NODEA' }
            [pscustomobject]@{ HostName = 'NODEB' }
        }
        Mock New-CimSession { [pscustomobject]@{ ComputerName = $ComputerName } }
        Mock Remove-CimSession {}
        Mock Get-CimInstance {
            $groupGuid = '16f1aac8-aba0-4d98-a51a-ac993a1bd29f'
            if ($ClassName -eq 'DfsrReplicatedFolderInfo' -and $CimSession.ComputerName -ne $script:missingComputer) {
                [pscustomobject]@{
                    ReplicationGroupName = $script:group
                    ReplicatedFolderName = $script:folder
                    ReplicationGroupGuid = $groupGuid
                    ReplicatedFolderGuid = 'ab2b6697-5a7d-4c4d-9105-886ab06aef1b'
                }
            }
            if ($ClassName -eq 'DfsrConnectionConfig' -and $CimSession.ComputerName -eq 'NODEA') {
                [pscustomobject]@{ ReplicationGroupGuid = $groupGuid; Inbound = $false; PartnerDns = 'NODEB' }
            }
        }
        Mock Invoke-CimMethod {
            if ($MethodName -eq 'GetVersionVector') {
                $status = if ($CimSession.ComputerName -eq $script:vectorFailure) { 5 } else { 0 }
                [pscustomobject]@{ ReturnValue = $status; VersionVector = 'vector-B' }
            } elseif ($MethodName -eq 'GetOutboundBacklogFileCount' -and $Arguments.VersionVector -eq 'vector-B') {
                [pscustomobject]@{ ReturnValue = 0; BacklogFileCount = $script:total }
            }
        }
    }

    It 'uses the provider total <Count> rather than the capped 100-item sample' -ForEach @(
        @{ Count = 0; Level = 'PASS' }
        @{ Count = 1000; Level = 'PASS' }
        @{ Count = 1001; Level = 'WARNING' }
    ) {
        $script:total = $Count
        $findings = @(HealthTest-DfsrBacklog -RGName $script:group 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match "^\[$Level\]"
        if ($Count -gt 1000) { $findings[0].Message | Should -Match "$Count" }
        Should -Invoke Get-DfsrBacklog -Exactly -Times 0
    }

    It 'distinguishes <Case> discovery from a healthy backlog' -ForEach @(
        @{ Case = 'failed'; DiscoveryFails = $true; Level = 'WARNING' }
        @{ Case = 'empty'; DiscoveryFails = $false; Level = 'INFO' }
    ) {
        $script:connections = @()
        if ($DiscoveryFails) { Mock Get-DfsrConnection { throw 'DFSR provider unavailable' } }

        $findings = @(HealthTest-DfsrBacklog -RGName $script:group 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match "^\[$Level\]"
    }

    It 'continues after a failed partner and reports a high backlog on another route' {
        $script:connections += [pscustomobject]@{ SourceComputerName = 'NODEA'; DestinationComputerName = 'NODEC' }
        $script:vectorFailure = 'NODEB'
        $script:total = 2048

        $findings = @(HealthTest-DfsrBacklog -RGName $script:group 3>&1)

        $findings | Should -HaveCount 2
        $findings[0].Message | Should -Match 'NODEA -> NODEB.*GetVersionVector returned status'
        $findings[1].Message | Should -Match 'NODEA -> NODEC.*2048'
    }

    It 'discovers the default SYSVOL topology using the provider' {
        $script:group = 'Domain System Volume'
        $script:folder = 'SYSVOL Share'

        $findings = @(HealthTest-DfsrBacklog 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match '^\[PASS\]'
        Should -Invoke Get-DfsrConnection -Exactly -Times 0
        Should -Invoke Invoke-CimMethod -Exactly -Times 1 -ParameterFilter { $MethodName -eq 'GetOutboundBacklogFileCount' }
    }

    It 'warns when the provider does not expose SYSVOL' {
        $script:group = 'Domain System Volume'
        $script:folder = 'SYSVOL Share'
        $script:missingComputer = 'NODEA'

        $findings = @(HealthTest-DfsrBacklog 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match '^\[WARNING\] Could not discover SYSVOL'
    }
}
