Describe 'HealthTest-DisksHaveFreeSpace' {
    BeforeAll {
        . "$PSScriptRoot\..\..\health-tests\HealthTest-DisksHaveFreeSpace.ps1"
        $script:drive = [pscustomobject]@{ Name = 'X:\'; DriveType = 'Fixed'; IsReady = $true }
    }

    It 'reports <Expected> for <Case>' -ForEach @(
        @{ Case = 'healthy'; Result = [pscustomobject]@{ Level = 'OK' }; Expected = 'PASS'; Detail = $null }
        @{ Case = 'low free space'; Result = [pscustomobject]@{ Level = 'Warning' }; Expected = 'WARNING'; Detail = $null }
        @{ Case = 'critical free space'; Result = [pscustomobject]@{ Level = 'Error' }; Expected = 'FAILURE'; Detail = $null }
        @{ Case = 'null result'; Result = $null; Expected = 'WARNING'; Detail = 'Drive: X:\' }
        @{ Case = 'unexpected level'; Result = [pscustomobject]@{ Level = 'Unknown' }; Expected = 'WARNING'; Detail = 'Drive: X:\' }
    ) {
        $script:driveResult = $Result
        Mock Test-DiskHasFreeSpace { $script:driveResult }

        $findings = @(HealthTest-DisksHaveFreeSpace -Drives $script:drive 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match "^\[$Expected\]"
        if ($Detail) { $findings[0].Message | Should -Match ([regex]::Escape($Detail)) }
    }

    It 'preserves a read error and continues to the next ready drive' {
        Mock Test-DiskHasFreeSpace { throw 'Volume became unavailable' } -ParameterFilter { $PathOrDrive -eq 'X:\' }
        Mock Test-DiskHasFreeSpace { [pscustomobject]@{ Level = 'OK'; Drive = 'Y:\' } } -ParameterFilter { $PathOrDrive -eq 'Y:\' }
        $second = [pscustomobject]@{ Name = 'Y:\'; DriveType = 'Removable'; IsReady = $true }
        $notReady = [pscustomobject]@{ Name = 'Z:\'; DriveType = 'Network'; IsReady = $false }

        $findings = @(HealthTest-DisksHaveFreeSpace -Drives @($script:drive, $second, $notReady) 3>&1)

        $findings | Should -HaveCount 2
        $findings[0].Message | Should -Match '^\[WARNING\]'
        $findings[0].Message | Should -Match 'Volume became unavailable'
        $findings[1].Message | Should -Match '^\[PASS\]'
        Should -Invoke Test-DiskHasFreeSpace -Exactly -Times 2
    }
}
