Describe 'HealthTest-ListTlsRegistryOverrides' {
    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        . (Join-Path $repoRoot 'health-tests\HealthTest-ListTlsRegistryOverrides.ps1')

        function New-TestTlsOverrideInfo {
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
        Mock Get-TlsRegistryValueInfo {
            New-TestTlsOverrideInfo -Path $Path -Name $Name
        }
        Mock Get-ExplicitTlsRegistryValues { @() }
    }

    It 'passes when no explicit settings are present' {
        HealthTest-ListTlsRegistryOverrides

        $script:warnings | Should -HaveCount 1
        $script:warnings[0] | Should -Be '[PASS] No explicit Schannel or Windows cryptography registry overrides were found'
    }

    It 'reports cipher-suite policy as a notice with stable path and name identity' {
        Mock Get-TlsRegistryValueInfo {
            if ($Name -eq 'Functions') {
                return New-TestTlsOverrideInfo -Path $Path -Name $Name -Exists $true -Value 'TLS_AES_256_GCM_SHA384,TLS_AES_128_GCM_SHA256' -Kind 'String'
            }

            return New-TestTlsOverrideInfo -Path $Path -Name $Name
        }

        HealthTest-ListTlsRegistryOverrides

        $script:warnings | Should -HaveCount 1
        $lines = @($script:warnings[0] -split "`n")
        $lines[0] | Should -Be "[NOTICE] TLS registry override: Path='HKLM:\SOFTWARE\Policies\Microsoft\Cryptography\Configuration\SSL\00010002'; Name='Functions'"
        $lines[0] | Should -Not -Match 'TLS_AES|String|Configured value'
        $script:warnings[0] | Should -Match 'Configured value: TLS_AES_256_GCM_SHA384,TLS_AES_128_GCM_SHA256\.'
        $script:warnings[0] | Should -Match 'custom cipher-suite priority'
    }

    It 'warns when a protocol override has the wrong registry type' {
        Mock Get-TlsRegistryValueInfo {
            if ($Path -match '\\TLS 1\.2\\Server$' -and $Name -eq 'Enabled') {
                return New-TestTlsOverrideInfo -Path $Path -Name $Name -Exists $true -Value 'yes' -Kind 'String'
            }

            return New-TestTlsOverrideInfo -Path $Path -Name $Name
        }

        HealthTest-ListTlsRegistryOverrides

        $script:warnings | Should -HaveCount 1
        $script:warnings[0] | Should -Match "^\[WARNING\] TLS registry override: Path='.*\\TLS 1\.2\\Server'; Name='Enabled'"
        $script:warnings[0] | Should -Match "Configuration issue: The protocol value uses registry type 'String'; expected DWord\."
    }

    It 'reports enabled FIPS mode as a compatibility and compliance notice' {
        Mock Get-TlsRegistryValueInfo {
            if ($Path -match '\\FipsAlgorithmPolicy$' -and $Name -eq 'Enabled') {
                return New-TestTlsOverrideInfo -Path $Path -Name $Name -Exists $true -Value 1 -Kind 'DWord'
            }

            return New-TestTlsOverrideInfo -Path $Path -Name $Name
        }

        HealthTest-ListTlsRegistryOverrides

        $script:warnings | Should -HaveCount 1
        $script:warnings[0] | Should -Match "^\[NOTICE\] TLS registry override: Path='.*\\FipsAlgorithmPolicy'; Name='Enabled'"
        $script:warnings[0] | Should -Match 'intentional compliance requirement'
        $script:warnings[0] | Should -Match 'Do not disable an intentional compliance setting'
    }

    It 'does not report the expected DWORD zero FIPS value' {
        Mock Get-TlsRegistryValueInfo {
            if ($Path -match '\\FipsAlgorithmPolicy$' -and $Name -eq 'Enabled') {
                return New-TestTlsOverrideInfo -Path $Path -Name $Name -Exists $true -Value 0 -Kind 'DWord'
            }

            return New-TestTlsOverrideInfo -Path $Path -Name $Name
        }

        HealthTest-ListTlsRegistryOverrides

        $script:warnings | Should -HaveCount 1
        $script:warnings[0] | Should -Match '^\[PASS\]'
    }

    It 'lists an explicit algorithm value without claiming that every such setting is insecure' {
        Mock Get-ExplicitTlsRegistryValues {
            if ($RootPath -match 'KeyExchangeAlgorithms$') {
                return @(
                    New-TestTlsOverrideInfo -Path "$RootPath\Diffie-Hellman" -Name 'ClientMinKeyBitLength' -Exists $true -Value 2048 -Kind 'DWord'
                )
            }

            return @()
        }

        HealthTest-ListTlsRegistryOverrides

        $script:warnings | Should -HaveCount 1
        $script:warnings[0] | Should -Match "^\[NOTICE\] TLS registry override: Path='.*\\KeyExchangeAlgorithms\\Diffie-Hellman'; Name='ClientMinKeyBitLength'"
        $script:warnings[0] | Should -Match 'Confirm the setting is documented for this Windows version'
        $script:warnings[0] | Should -Not -Match '(?i)insecure override'
    }

    It 'reports a registry inspection failure with stable location identity' {
        Mock Get-TlsRegistryValueInfo {
            if ($Name -eq 'Functions') {
                throw 'Policy key access denied'
            }

            return New-TestTlsOverrideInfo -Path $Path -Name $Name
        }

        HealthTest-ListTlsRegistryOverrides

        $script:warnings | Should -HaveCount 1
        $lines = @($script:warnings[0] -split "`n")
        $lines[0] | Should -Be "[WARNING] TLS registry inspection failed: Path='HKLM:\SOFTWARE\Policies\Microsoft\Cryptography\Configuration\SSL\00010002'; Name='Functions'"
        $script:warnings[0] | Should -Match 'Policy key access denied'
        @($script:warnings | Where-Object { $_ -match '^\[PASS\]' }) | Should -HaveCount 0
    }
}

Describe 'Get-ExplicitTlsRegistryValues' {
    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        . (Join-Path $repoRoot 'health-tests\helper-regarding-tls-registry.ps1')

        function New-TestRegistryKey {
            param(
                [string]$Name,
                [hashtable]$Values
            )

            $key = [pscustomobject]@{
                Name = $Name
                Values = $Values
            }
            $key | Add-Member -MemberType ScriptMethod -Name GetValueNames -Value {
                return @($this.Values.Keys)
            }
            $key | Add-Member -MemberType ScriptMethod -Name GetValue -Value {
                param($ValueName, $DefaultValue, $Options)
                return $this.Values[$ValueName]
            }
            $key | Add-Member -MemberType ScriptMethod -Name GetValueKind -Value {
                param($ValueName)
                return [Microsoft.Win32.RegistryValueKind]::DWord
            }

            return $key
        }
    }

    It 'returns ordinary objects from populated root and child registry keys' {
        $rootKey = New-TestRegistryKey -Name 'HKEY_LOCAL_MACHINE\SYSTEM\TestRoot' -Values @{
            RootValue = 1
        }
        $childKey = New-TestRegistryKey -Name 'HKEY_LOCAL_MACHINE\SYSTEM\TestRoot\Child' -Values @{
            ChildValue = 2
        }

        Mock Test-Path { $true }
        Mock Get-Item { $rootKey }
        Mock Get-ChildItem { @($childKey) }

        $results = @(Get-ExplicitTlsRegistryValues -RootPath 'HKLM:\SYSTEM\TestRoot')

        $results | Should -HaveCount 2
        $results[0].Path | Should -Be 'HKLM:\SYSTEM\TestRoot'
        $results[0].Name | Should -Be 'RootValue'
        $results[1].Path | Should -Be 'HKLM:\SYSTEM\TestRoot\Child'
        $results[1].Name | Should -Be 'ChildValue'
    }
}
