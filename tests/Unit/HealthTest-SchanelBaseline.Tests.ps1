Describe 'HealthTest-SchanelBaseline' {
    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        . (Join-Path $repoRoot 'health-tests\HealthTest-SchanelBaseline.ps1')

        function New-TestTlsOperatingSystem {
            param(
                [string]$Caption = 'Microsoft Windows Server 2022 Standard',
                [string]$Version = '10.0.20348',
                [bool]$IsServer = $true,
                [int]$ServicePackMajorVersion = 0
            )

            $parsedVersion = [version]$Version
            return [pscustomobject]@{
                Caption = $Caption
                Version = $parsedVersion
                Build = $parsedVersion.Build
                IsServer = $IsServer
                ServicePackMajorVersion = $ServicePackMajorVersion
            }
        }

        function New-TestTlsRegistryValueInfo {
            param(
                [string]$Path,
                [string]$Name,
                [bool]$Exists = $false,
                [object]$Value = $null,
                [string]$Kind = $null
            )

            return [pscustomobject]@{
                Path = $Path
                Name = $Name
                Exists = $Exists
                Value = $Value
                Kind = $Kind
            }
        }
    }

    BeforeEach {
        $script:warnings = @()
        Mock Write-Warning { $script:warnings += $Message }
        Mock Get-TlsOperatingSystemInfo {
            New-TestTlsOperatingSystem
        }
        Mock Get-TlsRegistryValueInfo {
            New-TestTlsRegistryValueInfo -Path $Path -Name $Name
        }
    }

    It 'uses Windows Server 2025 defaults instead of warning about absent legacy protocol values' {
        Mock Get-TlsOperatingSystemInfo {
            New-TestTlsOperatingSystem -Caption 'Microsoft Windows Server 2025 Standard' -Version '10.0.26100'
        }

        HealthTest-SchanelBaseline

        $script:warnings | Should -HaveCount 1
        $script:warnings[0] | Should -Match '^\[PASS\] Schannel protocol posture matches the baseline'
    }

    It 'reports the four Client and Server legacy protocol exposures present by default on Windows Server 2022' {
        HealthTest-SchanelBaseline

        @($script:warnings | Where-Object { $_ -match '^\[NOTICE\]' }) | Should -HaveCount 4
        @($script:warnings | Where-Object { $_ -match '^\[WARNING\]' }) | Should -HaveCount 0

        $clientFinding = @(
            $script:warnings |
            Where-Object { $_ -match '^\[NOTICE\].*CLIENT.*TLS 1\.0' }
        )
        $clientFinding | Should -HaveCount 1
        ($clientFinding[0] -split "`n")[0] | Should -Be '[NOTICE] Local CLIENT applications that depend on SCHANNEL may use TLS 1.0.'
        $clientFinding[0] | Should -Match 'Although this is the Windows Server 2022 Standard default, we recommend hardening it'
        $clientFinding[0] | Should -Match 'unless TLS 1\.0 is genuinely required by a legacy application\.'
        $clientFinding[0] | Should -Match '(?m)^Related Registry path: HKLM:\\.*\\TLS 1\.0\\Client$'

        $serverFinding = @(
            $script:warnings |
            Where-Object { $_ -match '^\[NOTICE\].*SERVER.*TLS 1\.0' }
        )
        $serverFinding | Should -HaveCount 1
        ($serverFinding[0] -split "`n")[0] | Should -Be '[NOTICE] Local SERVER applications that depend on SCHANNEL may accept TLS 1.0 connections.'
        $serverFinding[0] | Should -Match '(?m)^Related Registry path: HKLM:\\.*\\TLS 1\.0\\Server$'
    }

    It 'uses NOTICE when explicit values merely restate an unhardened OS default' {
        Mock Get-TlsRegistryValueInfo {
            if ($Path -match '\\TLS 1\.0\\Client$' -and $Name -eq 'Enabled') {
                return New-TestTlsRegistryValueInfo -Path $Path -Name $Name -Exists $true -Value 1 -Kind 'DWord'
            }

            if ($Path -match '\\TLS 1\.0\\Client$' -and $Name -eq 'DisabledByDefault') {
                return New-TestTlsRegistryValueInfo -Path $Path -Name $Name -Exists $true -Value 0 -Kind 'DWord'
            }

            return New-TestTlsRegistryValueInfo -Path $Path -Name $Name
        }

        HealthTest-SchanelBaseline

        $finding = @($script:warnings | Where-Object { $_ -match '^\[NOTICE\].*CLIENT.*TLS 1\.0' })
        $finding | Should -HaveCount 1
        @($script:warnings | Where-Object { $_ -match "^\[WARNING\].*Protocol='TLS 1\.0'; Role='Client'" }) | Should -HaveCount 0
    }

    It 'uses NOTICE when a recommended modern protocol is disabled by the OS default' {
        Mock Get-TlsOperatingSystemInfo {
            New-TestTlsOperatingSystem -Caption 'Microsoft Windows Server 2008 R2 Standard' -Version '6.1.7601'
        }

        HealthTest-SchanelBaseline

        $finding = @($script:warnings | Where-Object { $_ -match '^\[NOTICE\].*CLIENT.*TLS 1\.2' })
        $finding | Should -HaveCount 1
        ($finding[0] -split "`n")[0] | Should -Be '[NOTICE] Local CLIENT applications that depend on SCHANNEL may not use TLS 1.2.'
        $finding[0] | Should -Match 'Although this is the Windows Server 2008 R2 Standard default, we recommend enabling TLS 1\.2'
        $finding[0] | Should -Match '(?m)^Related Registry path: HKLM:\\.*\\TLS 1\.2\\Client$'
    }

    It 'keeps an explicit non-default legacy protocol enablement at WARNING level' {
        Mock Get-TlsOperatingSystemInfo {
            New-TestTlsOperatingSystem -Caption 'Microsoft Windows Server 2025 Standard' -Version '10.0.26100'
        }
        Mock Get-TlsRegistryValueInfo {
            if ($Path -match '\\TLS 1\.0\\Client$' -and $Name -eq 'Enabled') {
                return New-TestTlsRegistryValueInfo -Path $Path -Name $Name -Exists $true -Value 1 -Kind 'DWord'
            }

            if ($Path -match '\\TLS 1\.0\\Client$' -and $Name -eq 'DisabledByDefault') {
                return New-TestTlsRegistryValueInfo -Path $Path -Name $Name -Exists $true -Value 0 -Kind 'DWord'
            }

            return New-TestTlsRegistryValueInfo -Path $Path -Name $Name
        }

        HealthTest-SchanelBaseline

        $finding = @($script:warnings | Where-Object { $_ -match "^\[WARNING\].*Protocol='TLS 1\.0'; Role='Client'" })
        $finding | Should -HaveCount 1
        $finding[0] | Should -Match 'Enabled: 1 \(registry type: DWord\)\.'
        @($script:warnings | Where-Object { $_ -match '^\[NOTICE\].*CLIENT.*TLS 1\.0' }) | Should -HaveCount 0
    }

    It 'accepts explicit legacy hardening and leaves mutable registry values out of finding titles' {
        Mock Get-TlsRegistryValueInfo {
            if ($Path -match '\\TLS 1\.[01]\\' -and $Name -eq 'Enabled') {
                return New-TestTlsRegistryValueInfo -Path $Path -Name $Name -Exists $true -Value 0 -Kind 'DWord'
            }

            if ($Path -match '\\TLS 1\.[01]\\' -and $Name -eq 'DisabledByDefault') {
                return New-TestTlsRegistryValueInfo -Path $Path -Name $Name -Exists $true -Value 1 -Kind 'DWord'
            }

            return New-TestTlsRegistryValueInfo -Path $Path -Name $Name
        }

        HealthTest-SchanelBaseline

        $script:warnings | Should -HaveCount 1
        $script:warnings[0] | Should -Match '^\[PASS\]'
    }

    It 'does not mistake DisabledByDefault alone for fully disabling an available legacy protocol' {
        $operatingSystem = New-TestTlsOperatingSystem
        Mock Get-TlsRegistryValueInfo {
            if ($Name -eq 'DisabledByDefault') {
                return New-TestTlsRegistryValueInfo -Path $Path -Name $Name -Exists $true -Value 1 -Kind 'DWord'
            }

            return New-TestTlsRegistryValueInfo -Path $Path -Name $Name
        }

        $result = Get-TlsProtocolConfiguration -Protocol 'TLS 1.0' -Role 'Client' -OperatingSystem $operatingSystem

        $result.CurrentState | Should -Be 'Available but disabled by default'
        $result.ExpectedState | Should -Be 'Disabled'
        $result.IsCompliant | Should -BeFalse
    }

    It 'reports an invalid registry type with the relevant path and raw value in comments' {
        Mock Get-TlsOperatingSystemInfo {
            New-TestTlsOperatingSystem -Caption 'Microsoft Windows Server 2025 Standard' -Version '10.0.26100'
        }
        Mock Get-TlsRegistryValueInfo {
            if ($Path -match '\\TLS 1\.2\\Server$' -and $Name -eq 'Enabled') {
                return New-TestTlsRegistryValueInfo -Path $Path -Name $Name -Exists $true -Value '1' -Kind 'String'
            }

            return New-TestTlsRegistryValueInfo -Path $Path -Name $Name
        }

        HealthTest-SchanelBaseline

        $finding = @($script:warnings | Where-Object { $_ -match "Protocol='TLS 1\.2'; Role='Server'" })
        $finding | Should -HaveCount 1
        ($finding[0] -split "`n")[0] | Should -Be "[WARNING] TLS protocol posture issue: Protocol='TLS 1.2'; Role='Server'"
        $finding[0] | Should -Match 'Enabled: 1 \(registry type: String\)\.'
        $finding[0] | Should -Match "Configuration issue: Enabled has registry type 'String' instead of DWord\."
        ($finding[0] -split "`n")[0] | Should -Not -Match 'Enabled|DWord|Registry'
    }

    It 'reports an attempt to enable TLS 1.3 on an unsupported Windows version' {
        Mock Get-TlsOperatingSystemInfo {
            New-TestTlsOperatingSystem -Caption 'Microsoft Windows Server 2019 Standard' -Version '10.0.17763'
        }
        Mock Get-TlsRegistryValueInfo {
            if ($Path -match '\\TLS 1\.3\\Server$' -and $Name -eq 'Enabled') {
                return New-TestTlsRegistryValueInfo -Path $Path -Name $Name -Exists $true -Value 1 -Kind 'DWord'
            }

            return New-TestTlsRegistryValueInfo -Path $Path -Name $Name
        }

        HealthTest-SchanelBaseline

        $finding = @($script:warnings | Where-Object { $_ -match "Protocol='TLS 1\.3'; Role='Server'" })
        $finding | Should -HaveCount 1
        $finding[0] | Should -Match 'does not support it'
        $finding[0] | Should -Match 'Remove the unsupported TLS 1\.3 enabling override'
    }

    It 'reports operating system detection failure instead of guessing absent registry defaults' {
        Mock Get-TlsOperatingSystemInfo { throw 'CIM unavailable' }

        HealthTest-SchanelBaseline

        $script:warnings | Should -HaveCount 1
        $script:warnings[0] | Should -Match '^\[FAILURE\] Schannel operating system detection failed'
        $script:warnings[0] | Should -Match 'CIM unavailable'
    }

    It 'reports a registry read failure for the affected protocol and role' {
        Mock Get-TlsOperatingSystemInfo {
            New-TestTlsOperatingSystem -Caption 'Microsoft Windows Server 2025 Standard' -Version '10.0.26100'
        }
        Mock Get-TlsRegistryValueInfo {
            if ($Path -match '\\TLS 1\.2\\Server$') {
                throw 'Access denied'
            }

            return New-TestTlsRegistryValueInfo -Path $Path -Name $Name
        }

        HealthTest-SchanelBaseline

        $finding = @($script:warnings | Where-Object { $_ -match "^\[FAILURE\] TLS protocol inspection failed: Protocol='TLS 1\.2'; Role='Server'" })
        $finding | Should -HaveCount 1
        $finding[0] | Should -Match 'Access denied'
        @($script:warnings | Where-Object { $_ -match '^\[PASS\]' }) | Should -HaveCount 0
    }
}
