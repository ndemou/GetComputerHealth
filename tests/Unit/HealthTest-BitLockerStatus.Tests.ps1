Describe 'HealthTest-BitLockerStatus' {
    BeforeAll {
        . "$PSScriptRoot\..\..\health-tests\HealthTest-BitLockerStatus.ps1"

        function Get-BitLockerVolume {
            [CmdletBinding()]
            param()
            $script:volumes
            if ($script:queryError) {
                Write-Error $script:queryError
            }
        }
    }

    BeforeEach {
        $script:volumes = @()
        $script:queryError = $null
        Mock Test-IsVirtualMachine { $false }
    }

    It 'passes when all returned volumes are protected' {
        $script:volumes = @(
            [pscustomobject]@{ MountPoint = 'C:'; ProtectionStatus = 'On' }
            [pscustomobject]@{ MountPoint = 'D:'; ProtectionStatus = 'On' }
        )

        $warnings = @(HealthTest-BitLockerStatus 3>&1)

        $warnings | Should -HaveCount 1
        $warnings[0].Message | Should -Match '^\[PASS\]'
    }

    It 'reports the unprotected volume without passing the check' {
        $script:volumes = @(
            [pscustomobject]@{ MountPoint = 'C:'; ProtectionStatus = 'On' }
            [pscustomobject]@{ MountPoint = 'D:'; ProtectionStatus = 'Off' }
        )

        $warnings = @(HealthTest-BitLockerStatus 3>&1)

        $warnings | Should -HaveCount 1
        $warnings[0].Message | Should -Match '^\[WARNING\].*D:'
    }

    It 'warns when discovery succeeds without finding any volumes' {
        $warnings = @(HealthTest-BitLockerStatus 3>&1)

        $warnings | Should -HaveCount 1
        $warnings[0].Message | Should -Be '[WARNING] No BitLocker-capable volumes found'
    }

    It 'preserves the details of a terminating discovery error' {
        Mock Get-BitLockerVolume { throw 'Provider failed' }

        $warnings = @(HealthTest-BitLockerStatus 3>&1)

        $warnings | Should -HaveCount 1
        $warnings[0].Message | Should -Be "[WARNING] Could not read BitLocker status`nProvider failed"
    }

    It 'rejects partial results after a nonterminating discovery error' {
        $script:volumes = [pscustomobject]@{ MountPoint = 'C:'; ProtectionStatus = 'On' }
        $script:queryError = 'Partial discovery'

        $warnings = @(HealthTest-BitLockerStatus 3>&1)

        $warnings | Should -HaveCount 1
        $warnings[0].Message | Should -Be "[WARNING] Could not read BitLocker status`nPartial discovery"
    }

    It 'skips VMs without querying BitLocker' {
        Mock Test-IsVirtualMachine { $true }
        Mock Get-BitLockerVolume { throw 'Unexpected query' }

        $warnings = @(HealthTest-BitLockerStatus 3>&1)

        $warnings | Should -HaveCount 1
        $warnings[0].Message | Should -Match '^\[INFO\].*Computer is a VM'
        Should -Invoke Get-BitLockerVolume -Exactly -Times 0
    }

    It 'skips when the cmdlet is unavailable' {
        Mock Get-Command {} -ParameterFilter { $Name -eq 'Get-BitLockerVolume' }
        Mock Get-BitLockerVolume { throw 'Unexpected query' }

        $warnings = @(HealthTest-BitLockerStatus 3>&1)

        $warnings | Should -HaveCount 1
        $warnings[0].Message | Should -Match '^\[WARNING\].*cmdlets not available'
        Should -Invoke Get-BitLockerVolume -Exactly -Times 0
    }
}
