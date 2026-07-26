Describe 'HealthTest-CertExpiry' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'health-tests\HealthTest-CertExpiry.ps1')

        function New-TestCertificate {
            param(
                [string]$Subject,
                [string]$Issuer = 'CN=Test Issuer',
                [string]$SerialNumber = '01',
                [datetime]$NotBefore = (Get-Date).AddYears(-1),
                [datetime]$NotAfter = (Get-Date).AddYears(1),
                [bool]$HasPrivateKey = $true,
                [string]$FriendlyName = 'Test certificate',
                [array]$EnhancedKeyUsageList = @()
            )

            [pscustomobject]@{
                Subject = $Subject
                Issuer = $Issuer
                SerialNumber = $SerialNumber
                NotBefore = $NotBefore
                NotAfter = $NotAfter
                HasPrivateKey = $HasPrivateKey
                FriendlyName = $FriendlyName
                EnhancedKeyUsageList = $EnhancedKeyUsageList
            }
        }
    }

    BeforeEach {
        $script:warnings = @()
        Mock Write-Warning { $script:warnings += $Message }
    }

    It 'reports expiring certificates at their intended levels instead of passing' {
        Mock Get-ChildItem {
            @(
                New-TestCertificate -Subject 'CN=Expired' -SerialNumber '10' -NotAfter (Get-Date).AddDays(-10)
                New-TestCertificate -Subject 'CN=Expiring' -SerialNumber '20' -NotAfter (Get-Date).AddDays(45)
            )
        }

        HealthTest-CertExpiry

        @($script:warnings | Where-Object { $_ -match '(?s)^\[FAILURE\] Certificate validity issue:.*CN=Expired' }).Count | Should -Be 1
        @($script:warnings | Where-Object { $_ -match '(?s)^\[WARNING\] Certificate will expire soon:.*CN=Expiring' }).Count | Should -Be 1
        @($script:warnings | Where-Object { $_ -match '^\[PASS\]' }).Count | Should -Be 0
    }

    It 'uses stable certificate properties in the finding title and puts changing details in comments' {
        $eku = [pscustomobject]@{ FriendlyName = 'Server Authentication'; Value = '1.3.6.1.5.5.7.3.1' }
        $expiration = (Get-Date).AddDays(10)
        Mock Get-ChildItem {
            @(
                New-TestCertificate -Subject "CN=Server's Certificate" -Issuer 'CN=Issuer A' -SerialNumber 'ABC123' -NotAfter $expiration -HasPrivateKey $true -FriendlyName 'Web TLS' -EnhancedKeyUsageList @($eku)
            )
        }

        HealthTest-CertExpiry

        $script:warnings | Should -HaveCount 1
        $lines = @($script:warnings[0] -split "`n")
        $lines[0] | Should -Be "[FAILURE] Certificate will expire very soon: Store='LocalMachine\My'; Subject='CN=Server''s Certificate'; Issuer='CN=Issuer A'; SerialNumber='ABC123'"
        $lines[0] | Should -Not -Match 'NotAfter|Thumbprint|202[0-9]|\d+ days'
        $script:warnings[0] | Should -Match '(?m)^Status: Expires in \d+ days\.$'
        $script:warnings[0] | Should -Match "(?m)^Validity: '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' through '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' \(local time\)\.$"
        $script:warnings[0] | Should -Match "(?m)^Friendly name: 'Web TLS'\.$"
        $script:warnings[0] | Should -Match '(?m)^Has private key: Yes\.$'
        $script:warnings[0] | Should -Match 'Enhanced key usages: Server Authentication \(1\.3\.6\.1\.5\.5\.7\.3\.1\)\.'
        $script:warnings[0] | Should -Match '(?m)^Binding check: Not performed because the Windows certificate store has no universal reverse lookup'
        $script:warnings[0] | Should -Match '(?m)^Recommended action:'
    }

    It 'gives certificates with the same subject but different serial numbers different finding titles' {
        Mock Get-ChildItem {
            @(
                New-TestCertificate -Subject 'CN=Shared' -SerialNumber '100' -NotAfter (Get-Date).AddDays(-5)
                New-TestCertificate -Subject 'CN=Shared' -SerialNumber '200' -NotAfter (Get-Date).AddDays(-6)
            )
        }

        HealthTest-CertExpiry

        $findingTitles = @($script:warnings | ForEach-Object { ($_ -split "`n")[0] })
        $findingTitles | Should -HaveCount 2
        $findingTitles[0] | Should -Not -Be $findingTitles[1]
        $findingTitles[0] | Should -Match "SerialNumber='100'"
        $findingTitles[1] | Should -Match "SerialNumber='200'"
    }

    It 'shows a newer valid same-subject certificate as a candidate rather than a proven replacement' {
        Mock Get-ChildItem {
            @(
                New-TestCertificate -Subject 'CN=Shared' -Issuer 'CN=Old Issuer' -SerialNumber 'OLD' -NotAfter (Get-Date).AddDays(-5)
                New-TestCertificate -Subject 'CN=Shared' -Issuer 'CN=New Issuer' -SerialNumber 'NEW' -NotBefore (Get-Date).AddDays(-1) -NotAfter (Get-Date).AddYears(1)
            )
        }

        HealthTest-CertExpiry

        $finding = @($script:warnings | Where-Object { $_ -match "SerialNumber='OLD'" })[0]
        $finding | Should -Match "Newer valid same-subject candidate: Subject='CN=Shared'; Issuer='CN=New Issuer'; SerialNumber='NEW'"
        $finding | Should -Match 'Confirm that required bindings moved before treating it as a replacement\.'
    }

    It 'suppresses an expired Azure CRP certificate when a newer valid same-subject candidate exists' {
        Mock Get-ChildItem {
            @(
                New-TestCertificate -Subject 'DC=Windows Azure CRP Certificate Generator' -SerialNumber 'OLD' -NotAfter (Get-Date).AddDays(-100)
                New-TestCertificate -Subject 'DC=Windows Azure CRP Certificate Generator' -SerialNumber 'NEW' -NotBefore (Get-Date).AddDays(-1) -NotAfter (Get-Date).AddYears(1)
            )
        }

        HealthTest-CertExpiry

        @($script:warnings | Where-Object { $_ -match '^\[(FAILURE|WARNING)\]' }).Count | Should -Be 0
        @($script:warnings | Where-Object { $_ -match '^\[info\] Superseded Azure CRP certificate expiry findings suppressed' }).Count | Should -Be 1
        @($script:warnings | Where-Object { $_ -match '^\[PASS\]' }).Count | Should -Be 1
        ($script:warnings -join "`n") | Should -Match "SerialNumber='OLD'.*CandidateSerialNumber='NEW'"
    }

    It 'reports an expired Azure CRP certificate when no valid candidate exists' {
        Mock Get-ChildItem {
            @(
                New-TestCertificate -Subject 'DC=Windows Azure CRP Certificate Generator' -SerialNumber 'OLD' -NotAfter (Get-Date).AddDays(-100)
            )
        }

        HealthTest-CertExpiry

        @($script:warnings | Where-Object { $_ -match '^\[NOTICE\] Certificate validity issue:' }).Count | Should -Be 1
        ($script:warnings -join "`n") | Should -Match 'Check Azure VM Agent and extension health\.'
    }

    It 'adds Azure Backup-specific guidance without hiding the finding' {
        Mock Get-ChildItem {
            @(
                New-TestCertificate -Subject 'CN=Microsoft Azure Backup Encryption Certificate' -SerialNumber 'BACKUP' -NotAfter (Get-Date).AddDays(-100)
            )
        }

        HealthTest-CertExpiry

        @($script:warnings | Where-Object { $_ -match '^\[NOTICE\] Certificate validity issue:' }).Count | Should -Be 1
        ($script:warnings -join "`n") | Should -Match 'Confirm recent Azure Backup jobs and required restore or encryption configuration\.'
    }

    It 'passes when all certificates are outside the warning window' {
        Mock Get-ChildItem {
            @(
                New-TestCertificate -Subject 'CN=Healthy' -SerialNumber '30' -NotAfter (Get-Date).AddDays(90)
            )
        }

        HealthTest-CertExpiry

        $script:warnings | Should -HaveCount 1
        $script:warnings[0] | Should -Match '^\[PASS\]'
    }

    It 'reports a store inspection failure instead of treating it as an empty store' {
        Mock Get-ChildItem { throw 'Certificate provider unavailable' }

        HealthTest-CertExpiry

        $script:warnings | Should -HaveCount 1
        $script:warnings[0] | Should -Match "^\[FAILURE\] Certificate store inspection failed: Store='LocalMachine\\My'"
        $script:warnings[0] | Should -Match 'Certificate provider unavailable'
    }
}
