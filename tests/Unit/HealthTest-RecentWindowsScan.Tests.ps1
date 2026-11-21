Describe 'HealthTest-RecentWindowsScan' {
    BeforeAll {
        . "$PSScriptRoot\..\..\health-tests\HealthTest-RecentWindowsScan.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            "$PSScriptRoot\..\..\Get-ComputerHealth.ps1", [ref]$null, [ref]$null)
        foreach ($name in 'Convert-TextToLogRecord', 'Convert-WarningLikeObjectToLogRecord') {
            $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }

        function Get-MpComputerStatus { [CmdletBinding()] param() }
    }

    BeforeEach {
        $script:now = [datetime]'2026-11-21T12:00:00'
        Mock Get-Date { $script:now }
        Mock Get-ChildItem {} -ParameterFilter { $Path -eq 'HKLM:\SYSTEM\Setup' }
        Mock Get-ItemProperty {} -ParameterFilter { $Name -eq 'InstallDate' }
        Mock Get-CimInstance {}
        Mock Get-MpComputerStatus { throw 'Defender scan data unavailable' }
    }

    It 'uses installation age <Age> days to produce <Level> when scan history is missing' -ForEach @(
        @{ Age = 3; Level = 'PASS' }
        @{ Age = 4; Level = 'WARNING' }
        @{ Age = 8; Level = 'FAILURE' }
    ) {
        $script:installDate = $script:now.AddDays(-$Age)
        Mock Get-CimInstance { [pscustomobject]@{ InstallDate = $script:installDate } }

        $findings = @(HealthTest-RecentWindowsScan 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match "^\[$Level\] Defender scan history is unavailable"
        $findings[0].Message | Should -Match "installation age is $Age days"
        $findings[0].Message | Should -Match 'Defender scan data unavailable'
    }

    It 'returns unknown installation age without emitting a warning itself' {
        Mock Get-ItemProperty { throw 'Registry unavailable' } -ParameterFilter { $Name -eq 'InstallDate' }
        Mock Get-CimInstance { throw 'WMI unavailable' }

        $result = @(Get-WindowsOriginalInstallDate 3>&1)

        $result | Should -HaveCount 1
        $result[0].InstallDate | Should -BeNullOrEmpty
        $result[0].AgeDays | Should -BeNullOrEmpty
        $result[0].Details | Should -Match 'WMI unavailable'
    }

    It 'converts missing evidence to one classified finding with provider details' {
        Mock Get-ItemProperty { throw 'Registry unavailable' } -ParameterFilter { $Name -eq 'InstallDate' }
        Mock Get-CimInstance { throw 'WMI unavailable' }

        $findings = @(HealthTest-RecentWindowsScan 3>&1)

        $findings | Should -HaveCount 1
        $record = Convert-WarningLikeObjectToLogRecord $findings[0]
        $record.Level | Should -Be 'warning'
        $record.Msg | Should -Be 'Could not determine Defender scan recency'
        $record.Comment | Should -Match 'Defender scan data unavailable'
        $record.Comment | Should -Match 'Registry unavailable'
        $record.Comment | Should -Match 'WMI unavailable'
    }

    It 'ignores invalid and future dates and unknown Defender age sentinels' {
        Mock Get-MpComputerStatus {
            [pscustomobject]@{ FullScanAge = [uint32]::MaxValue; QuickScanEndTime = $script:now.AddDays(1) }
        }
        Mock Get-ItemProperty { [pscustomobject]@{ InstallDate = 0 } } -ParameterFilter { $Name -eq 'InstallDate' }
        Mock Get-CimInstance { [pscustomobject]@{ InstallDate = $script:now.AddDays(1) } }

        $findings = @(HealthTest-RecentWindowsScan 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match '^\[WARNING\] Could not determine Defender scan recency'
    }

    It 'uses a valid scan without looking up the installation date' {
        Mock Get-MpComputerStatus { [pscustomobject]@{ QuickScanEndTime = $script:now.AddDays(-1) } }
        Mock Get-WindowsOriginalInstallDate { throw 'Unexpected install query' }

        $findings = @(HealthTest-RecentWindowsScan 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match '^\[PASS\]'
        $findings[0].Message | Should -Match 'Last scan, 1 days ago'
        Should -Invoke Get-WindowsOriginalInstallDate -Exactly -Times 0
    }
}
