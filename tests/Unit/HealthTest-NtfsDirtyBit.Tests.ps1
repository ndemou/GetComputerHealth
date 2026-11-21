Describe 'HealthTest-NtfsDirtyBit' {
    BeforeAll {
        . "$PSScriptRoot\..\..\health-tests\HealthTest-NtfsDirtyBit.ps1"
    }

    BeforeEach {
        Mock Get-CimInstance { $script:volumes }
    }

    It 'uses only explicit Boolean status for NTFS volumes' {
        $script:volumes = @(
            [pscustomobject]@{ FileSystem = 'NTFS'; DriveLetter = 'C:'; DirtyBitSet = $false }
            [pscustomobject]@{ FileSystem = 'FAT32'; DriveLetter = 'D:'; DirtyBitSet = $true }
        )

        $findings = @(HealthTest-NtfsDirtyBit 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Be '[PASS] No NTFS dirty volumes'
    }

    It 'reports a dirty mounted volume without a drive letter alongside unreadable volumes' {
        $script:volumes = @(
            [pscustomobject]@{ FileSystem = 'NTFS'; DriveLetter = 'C:'; DirtyBitSet = $false }
            [pscustomobject]@{ FileSystem = 'NTFS'; DeviceID = '\\?\Volume{abc}\'; DirtyBitSet = $true }
            [pscustomobject]@{ FileSystem = 'NTFS'; DriveLetter = 'D:'; DirtyBitSet = $null }
            [pscustomobject]@{ FileSystem = 'NTFS'; DriveLetter = 'E:' }
            [pscustomobject]@{ FileSystem = 'NTFS'; DriveLetter = 'F:'; DirtyBitSet = 'false' }
        )

        $findings = @(HealthTest-NtfsDirtyBit 3>&1)

        $findings | Should -HaveCount 2
        $findings[0].Message | Should -Be '[WARNING] NTFS dirty bit set on: \\?\Volume{abc}\'
        $findings[1].Message | Should -Match 'D:, E:, F:'
    }

    It 'warns when discovery returns <Case>' -ForEach @(
        @{ Case = 'nothing'; Volumes = @() }
        @{ Case = 'unusable rows'; Volumes = @([pscustomobject]@{ DeviceID = 'Unknown' }) }
        @{ Case = 'no NTFS volumes'; Volumes = @([pscustomobject]@{ FileSystem = 'FAT32' }) }
    ) {
        $script:volumes = $Volumes

        $findings = @(HealthTest-NtfsDirtyBit 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match '^\[WARNING\] No NTFS volumes'
    }

    It 'reports a discovery failure with its details' {
        Mock Get-CimInstance { throw 'Volume provider unavailable' }

        $findings = @(HealthTest-NtfsDirtyBit 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match '^\[WARNING\] Could not enumerate'
        $findings[0].Message | Should -Match 'Volume provider unavailable'
    }
}
