Describe 'HealthTest-Nic' {
    BeforeAll {
        . "$PSScriptRoot\..\..\health-tests\HealthTest-Nic.ps1"
    }

    BeforeEach {
        Mock Get-NetAdapter { $script:adapters }
        Mock Get-NetAdapterStatistics {
            switch ($script:stats[$Name]) {
                'healthy'     { [pscustomobject]@{ ReceivedUnicastPackets = 100000 } }
                'packetErrors' { [pscustomobject]@{ ReceivedUnicastPackets = 100000; ReceivedPacketErrors = 1200 } }
                'lowTraffic'  { [pscustomobject]@{ ReceivedUnicastPackets = 500; ReceivedPacketErrors = 1200 } }
                'error'       { throw 'Provider unavailable' }
            }
        }
    }

    It 'reports <Expected> for <Case>' -ForEach @(
        @{ Case = 'healthy counters'; Stats = @{ First = 'healthy' }; Disconnected = $false; Expected = 'PASS'; Detail = $null }
        @{ Case = 'empty statistics'; Stats = @{ First = 'empty' }; Disconnected = $false; Expected = 'WARNING'; Detail = 'Missing network interface statistics' }
        @{ Case = 'query error'; Stats = @{ First = 'error' }; Disconnected = $false; Expected = 'WARNING'; Detail = 'Provider unavailable' }
        @{ Case = 'one failed query and one healthy query'; Stats = @{ First = 'error'; Second = 'healthy' }; Disconnected = $false; Expected = 'WARNING'; Detail = $null }
        @{ Case = 'all queries fail'; Stats = @{ First = 'error'; Second = 'error' }; Disconnected = $false; Expected = 'WARNING,WARNING'; Detail = $null }
        @{ Case = 'a later adapter has packet errors'; Stats = @{ First = 'error'; Second = 'packetErrors' }; Disconnected = $false; Expected = 'WARNING,WARNING'; Detail = 'plenty of errors \(Second\)' }
        @{ Case = 'low traffic'; Stats = @{ First = 'lowTraffic' }; Disconnected = $false; Expected = 'PASS'; Detail = 'skipped due to low traffic' }
        @{ Case = 'disconnected media'; Stats = @{ First = 'healthy' }; Disconnected = $true; Expected = 'WARNING'; Detail = 'Disconnected network interface' }
    ) {
        $script:stats = $Stats
        $script:adapters = foreach ($name in ($Stats.Keys | Sort-Object)) {
            [pscustomobject]@{
                Name = $name
                Status = 'Up'
                MediaConnectionState = if ($Disconnected) { 'Disconnected' } else { 'Connected' }
            }
        }

        $output = @(HealthTest-Nic 3>&1)
        $levels = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } |
            ForEach-Object { $_.Message -replace '(?s)^\[([A-Z]+)\].*', '$1' })

        ($levels -join ',') | Should -Be $Expected
        if ($Detail) { ($output -join ' ') | Should -Match $Detail }
        Should -Invoke Get-NetAdapterStatistics -Times $Stats.Count -Exactly
    }
}
