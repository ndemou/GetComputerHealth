Describe 'Veeam backup helpers for custom health tests' {
    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        . (Join-Path $repoRoot 'helpers-for-custom-ht.ps1')
    }

    BeforeEach {
        Mock Write-Warning
    }

    It 'loads the VM and configuration backup helper functions' {
        Get-Command Start-HealthTestVeeamRecentBackupsExist -CommandType Function |
            Should -Not -BeNullOrEmpty

        Get-Command Start-HealthTestVeeamRecentConfigBackupsExist -CommandType Function |
            Should -Not -BeNullOrEmpty
    }

    It 'passes when a recent Veeam configuration backup exists' {
        Mock Get-RecentFilesConditional { @([pscustomobject]@{}) }

        Start-HealthTestVeeamRecentConfigBackupsExist -RootPath 'C:\VeeamConfig' -MaxAgeHours 48

        Assert-MockCalled Get-RecentFilesConditional -Times 1 -ParameterFilter {
            $Path -eq 'C:\VeeamConfig' -and
            $Pattern -eq '*.BCO' -and
            $MinBytes -eq 25000 -and
            $MaxAgeHours -eq 48
        }

        Assert-MockCalled Write-Warning -Times 1 -ParameterFilter {
            $Message -eq (
                '[PASS] Found recent Configuration Backup in ' +
                'C:\VeeamConfig'
            )
        }
    }

    It 'fails when no recent Veeam configuration backup exists' {
        Mock Get-RecentFilesConditional { $null }

        Start-HealthTestVeeamRecentConfigBackupsExist -RootPath 'C:\VeeamConfig'

        Assert-MockCalled Write-Warning -Times 1 -ParameterFilter {
            $Message -eq (
                '[FAILURE] No recent Configuration Backup in ' +
                'C:\VeeamConfig'
            )
        }
    }
}
