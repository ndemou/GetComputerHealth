Describe 'HTTPS certificate helpers for custom health tests' {
    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        . (Join-Path $repoRoot 'helpers-for-custom-ht.ps1')
    }

    BeforeEach {
        $script:warnings = @()
        Mock Write-Warning { $script:warnings += [string]$Message }
    }

    It 'loads both HTTPS certificate helper functions' {
        Get-Command Get-HttpsCertificateStatus -CommandType Function | Should -Not -BeNullOrEmpty
        Get-Command HealthTest-HttpsCertificate -CommandType Function | Should -Not -BeNullOrEmpty
    }

    It 'rejects a URL that is not an absolute HTTPS URL without connecting' {
        $result = Get-HttpsCertificateStatus -Url 'http://example.com/'

        $result.Status | Should -Be 'InvalidUrl'
        $result.IsValid | Should -BeFalse
        $result.Error | Should -Be 'Supply an absolute HTTPS URL.'
    }

    It 'rejects warning and failure thresholds in the wrong order' {
        Mock Get-HttpsCertificateStatus { throw 'The certificate helper should not be called.' }

        HealthTest-HttpsCertificate -Url 'https://example.com/' -WarnDays 10 -FailDays 20

        $script:warnings | Should -HaveCount 1
        $script:warnings[0] | Should -Match '^\[FAILURE\] HTTPS certificate test configuration issue'
        Assert-MockCalled Get-HttpsCertificateStatus -Times 0
    }

    It 'passes when every certificate is valid beyond the warning period' {
        Mock Get-HttpsCertificateStatus {
            [pscustomobject]@{
                Url = $Url
                Status = 'Valid'
                IsValid = $true
                ExpiresAt = [DateTimeOffset]::Now.AddDays(91)
                StatusDetails = @()
                Error = $null
            }
        }

        HealthTest-HttpsCertificate -Url 'https://one.example/', 'https://two.example/' -WarnDays 60 -FailDays 30

        $script:warnings | Should -HaveCount 1
        $script:warnings[0] | Should -Be '[PASS] All 2 HTTPS certificates are valid for more than 60 days'
        Assert-MockCalled Get-HttpsCertificateStatus -Times 2
    }

    It 'reports a failure when a valid certificate is inside the failure period' {
        Mock Get-HttpsCertificateStatus {
            [pscustomobject]@{
                Url = $Url
                Status = 'Valid'
                IsValid = $true
                ExpiresAt = [DateTimeOffset]::Now.AddDays(10)
                StatusDetails = @()
                Error = $null
            }
        }

        HealthTest-HttpsCertificate -Url 'https://example.com/' -WarnDays 60 -FailDays 30

        $script:warnings | Should -HaveCount 1
        $script:warnings[0] | Should -Match "^\[FAILURE\] HTTPS certificate will expire very soon: Url='https://example.com/'"
    }
}
