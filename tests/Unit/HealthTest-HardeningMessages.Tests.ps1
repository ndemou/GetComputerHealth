Describe 'Hardening health-test messages' {
    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

        . (Join-Path $repoRoot 'health-tests\helpers-for-healthtests.ps1')
        . (Join-Path $repoRoot 'health-tests\HealthTest-LdapSigningChannelBinding.ps1')
        . (Join-Path $repoRoot 'health-tests\HealthTest-NtlmHardening.ps1')
        . (Join-Path $repoRoot 'health-tests\HealthTest-RdpHardening.ps1')
        . (Join-Path $repoRoot 'health-tests\HealthTest-RestrictAnonymous.ps1')
        . (Join-Path $repoRoot 'health-tests\HealthTest-ShareReasonableness.ps1')
        . (Join-Path $repoRoot 'health-tests\HealthTest-SmbSigningRequired.ps1')
        . (Join-Path $repoRoot 'health-tests\HealthTest-Smb1Disabled.ps1')
        . (Join-Path $repoRoot 'health-tests\HealthTest-FirewallEnabled.ps1')
    }

    BeforeEach {
        $script:warnings = @()
        Mock Write-Warning { $script:warnings += $Message }
    }

    It 'identifies domain membership from the computer domain role' {
        Mock Get-CimInstance {
            [pscustomobject]@{ DomainRole = 3 }
        }

        Test-IsDomainJoinedComputer | Should -BeTrue

        Mock Get-CimInstance {
            [pscustomobject]@{ DomainRole = 2 }
        }

        Test-IsDomainJoinedComputer | Should -BeFalse
    }

    It 'shows LDAP hardening policy paths in a domain-controller finding' {
        Mock Get-ItemProperty {
            [pscustomobject]@{
                LDAPServerIntegrity = 0
                LdapEnforceChannelBinding = 0
            }
        }

        HealthTest-LdapSigningChannelBinding

        $script:warnings | Should -HaveCount 1
        $script:warnings[0] | Should -Match '^\[NOTICE\] LDAP hardening:'
        $script:warnings[0] | Should -Match 'Domain controller: LDAP server signing requirements'
        $script:warnings[0] | Should -Match 'Domain controller: LDAP server channel binding token requirements'
        $script:warnings[0] | Should -Not -Match 'Related registry path'
    }

    It 'shows NTLM domain policy instead of the registry path on a domain member' {
        Mock Test-IsDomainJoinedComputer { $true }
        Mock Get-ItemProperty {
            [pscustomobject]@{
                LmCompatibilityLevel = 3
                NoLMHash = 1
            }
        }

        HealthTest-NtlmHardening

        $script:warnings | Should -HaveCount 1
        $script:warnings[0] | Should -Match '^\[WARNING\] NTLM hardening:'
        $script:warnings[0] | Should -Match 'Related domain policy path:.*Network security: LAN Manager authentication level'
        $script:warnings[0] | Should -Not -Match 'Related registry path'
    }

    It 'shows the NTLM registry path on a workgroup computer' {
        Mock Test-IsDomainJoinedComputer { $false }
        Mock Get-ItemProperty {
            [pscustomobject]@{
                LmCompatibilityLevel = 5
                NoLMHash = 0
            }
        }

        HealthTest-NtlmHardening

        $script:warnings | Should -HaveCount 1
        $script:warnings[0] | Should -Match '^\[WARNING\] NTLM is not fully hardened \(NoLMHash is not 1\)'
        $script:warnings[0] | Should -Match "Related registry path: 'HKLM:\\.*\\NoLMHash'"
        $script:warnings[0] | Should -Not -Match 'Related domain policy path'
    }

    It 'shows the applicable RDP domain policies for both missing protections' {
        Mock Get-ItemProperty {
            [pscustomobject]@{
                UserAuthentication = 0
                SSLCertificateSHA1Hash = ''
            }
        }
        Mock Get-CimInstance {
            [pscustomobject]@{ DomainRole = 3 }
        }

        HealthTest-RdpHardening

        $script:warnings | Should -HaveCount 1
        $script:warnings[0] | Should -Match '^\[WARNING\] RDP is not hardened \(NLA and/or TLS certificate binding missing\)'
        $script:warnings[0] | Should -Match 'Require user authentication for remote connections by using Network Level Authentication'
        $script:warnings[0] | Should -Match 'Server authentication certificate template'
        $script:warnings[0] | Should -Not -Match 'Related registry path'
    }

    It 'shows anonymous-access domain policies instead of registry paths' {
        Mock Test-IsDomainJoinedComputer { $true }
        Mock Get-ItemProperty {
            if ($Name -eq 'restrictanonymous') {
                return [pscustomobject]@{ restrictanonymous = 0 }
            }
            if ($Name -eq 'restrictanonymoussam') {
                return [pscustomobject]@{ restrictanonymoussam = 0 }
            }
            return [pscustomobject]@{ EveryoneIncludesAnonymous = 1 }
        }

        HealthTest-RestrictAnonymous

        $script:warnings | Should -HaveCount 1
        $script:warnings[0] | Should -Match '^\[FAILURE\] Anonymous access hardening not at baseline'
        $script:warnings[0] | Should -Match 'Network access: Do not allow anonymous enumeration of SAM accounts'
        $script:warnings[0] | Should -Match 'Network access: Let Everyone permissions apply to anonymous users'
        $script:warnings[0] | Should -Not -Match 'Related registry path'
    }

    It 'shows domain policies for anonymous SMB shares and named pipes' {
        Mock Get-CimInstance {
            if ($ClassName -eq 'Win32_OperatingSystem') {
                return [pscustomobject]@{ ProductType = 3 }
            }
            return [pscustomobject]@{ DomainRole = 3 }
        }
        Mock Get-Service {
            [pscustomobject]@{ Status = 'Running' }
        }
        Mock Get-SmbShare { @() }
        Mock Get-ItemProperty {
            [pscustomobject]@{
                NullSessionShares = @('LegacyShare')
                NullSessionPipes = @('LegacyPipe')
            }
        }
        Mock Test-IsRdsLicensingServer { $false }

        HealthTest-ShareReasonableness

        $shareFinding = @($script:warnings | Where-Object { $_ -match '^\[FAILURE\] Null session shares configured:' })
        $pipeFinding = @($script:warnings | Where-Object { $_ -match '^\[NOTICE\] Null session pipes ' })
        $shareFinding | Should -HaveCount 1
        $pipeFinding | Should -HaveCount 1
        $shareFinding[0] | Should -Match 'Network access: Shares that can be accessed anonymously'
        $pipeFinding[0] | Should -Match 'Network access: Named Pipes that can be accessed anonymously'
        ($shareFinding + $pipeFinding) -join "`n" | Should -Not -Match 'Related registry path'
    }

    It 'shows SMB signing domain policy and an SMBv1 feature-removal recommendation' {
        Mock Get-Service {
            [pscustomobject]@{ Status = 'Running' }
        }
        Mock Get-SmbServerConfiguration {
            [pscustomobject]@{
                RequireSecuritySignature = $false
                EnableSecuritySignature = $true
            }
        }
        Mock Test-IsDomainJoinedComputer { $true }

        HealthTest-SmbSigningRequired

        $script:warnings[0] | Should -Match '^\[WARNING\] SMB hardening: server signing is not required'
        $script:warnings[0] | Should -Match 'Microsoft network server: Digitally sign communications \(always\)'
        $script:warnings[0] | Should -Not -Match 'Related registry path'

        $script:warnings = @()
        $script:RunWithoutElevation = $false
        Mock Get-WindowsOptionalFeature {
            [pscustomobject]@{ State = 'Enabled' }
        }

        HealthTest-Smb1Disabled

        $script:warnings | Should -HaveCount 1
        $script:warnings[0] | Should -Match '^\[WARNING\] SMBv1 is enabled'
        $script:warnings[0] | Should -Match "Windows optional feature 'SMB1Protocol'"
    }

    It 'shows the firewall domain policy for a disabled profile' {
        Mock Test-IsDomainJoinedComputer { $true }
        Mock Get-Service {
            [pscustomobject]@{ Status = 'Stopped' }
        }
        Mock Get-NetFirewallProfile {
            [pscustomobject]@{
                Name = 'Domain'
                Enabled = 0
            }
        }

        HealthTest-FirewallEnabled

        $serviceFinding = @($script:warnings | Where-Object { $_ -match 'Windows Firewall service is not running' })
        $profileFinding = @($script:warnings | Where-Object { $_ -match 'Windows Firewall is disabled for the Domain profile' })
        $serviceFinding | Should -HaveCount 1
        $profileFinding | Should -HaveCount 1
        $serviceFinding[0] | Should -Match '^\[FAILURE\] Windows Firewall service is not running'
        $profileFinding[0] | Should -Match '^\[FAILURE\] Windows Firewall is disabled for the Domain profile'
        $profileFinding[0] | Should -Match 'Related domain policy path:.*Windows Defender Firewall with Advanced Security'
        $profileFinding[0] | Should -Match 'Windows Defender Firewall Properties.*Domain Profile'
        $profileFinding[0] | Should -Not -Match 'Recommended local command'
    }
}
