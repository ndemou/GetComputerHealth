Describe 'HealthTest-DhcpScopeUtilization' {
    BeforeAll {
        . "$PSScriptRoot\..\..\health-tests\HealthTest-DhcpScopeUtilization.ps1"
        function Get-DhcpServerv4ScopeStatistics { [CmdletBinding()] param() }
    }

    BeforeEach {
        Mock Get-Service { [pscustomobject]@{ Name = 'DHCPServer' } } -ParameterFilter { $Name -eq 'DHCPServer' }
        Mock Get-DhcpServerv4ScopeStatistics {
            for ($i = 0; $i -lt $script:utilization.Count; $i++) {
                [pscustomobject]@{ ScopeId = "192.0.$i.0"; PercentageInUse = $script:utilization[$i] }
            }
        }
    }

    It 'emits only the expected findings for <Case>' -ForEach @(
        @{ Case = '79%'; Used = @(79); Levels = @('PASS') }
        @{ Case = '80%'; Used = @(80); Levels = @('WARNING') }
        @{ Case = '89%'; Used = @(89); Levels = @('WARNING') }
        @{ Case = '90%'; Used = @(90); Levels = @('FAILURE') }
        @{ Case = '95%'; Used = @(95); Levels = @('FAILURE') }
        @{ Case = 'several healthy scopes'; Used = @(12, 79, 42); Levels = @('PASS') }
        @{ Case = 'mixed scopes'; Used = @(79, 80, 95); Levels = @('WARNING', 'FAILURE') }
        @{ Case = 'empty statistics'; Used = @(); Levels = @('WARNING') }
    ) {
        $script:utilization = $Used

        $findings = @(HealthTest-DhcpScopeUtilization 3>&1)
        $actualLevels = @($findings | ForEach-Object { $_.Message -replace '^\[([A-Z]+)\].*', '$1' })

        ($actualLevels -join ',') | Should -Be ($Levels -join ',')
    }
}
