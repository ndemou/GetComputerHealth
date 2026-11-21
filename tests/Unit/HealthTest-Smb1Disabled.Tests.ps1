enum Smb1OptionalFeatureStateFixture {
    Disabled = 0
}

Describe 'HealthTest-Smb1Disabled' {
    BeforeAll {
        . "$PSScriptRoot\..\..\health-tests\HealthTest-Smb1Disabled.ps1"

        function Get-WindowsOptionalFeature {
            [CmdletBinding()]
            param([switch]$Online, [string]$FeatureName)
            $script:feature
            if ($script:queryError) {
                Write-Error $script:queryError
            }
        }
    }

    BeforeEach {
        $script:RunWithoutElevation = $false
        $script:feature = $null
        $script:queryError = $null
    }

    It 'classifies SMBv1 state <State> as <Level>' -ForEach @(
        @{ State = 'Disabled'; Level = 'PASS'; Message = 'SMBv1 is disabled' }
        @{ State = 'DisabledWithPayloadRemoved'; Level = 'PASS'; Message = 'SMBv1 is disabled' }
        @{ State = 'Enabled'; Level = 'WARNING'; Message = 'SMBv1 is enabled' }
        @{ State = 'DisablePending'; Level = 'WARNING'; Message = 'State=DisablePending' }
        @{ State = 'Unrecognized'; Level = 'WARNING'; Message = 'State=Unrecognized' }
    ) {
        $script:feature = [pscustomobject]@{ State = $State }

        $warnings = @(HealthTest-Smb1Disabled 3>&1)

        $warnings | Should -HaveCount 1
        $warnings[0].Message | Should -Match "^\[$Level\]"
        $warnings[0].Message | Should -Match ([regex]::Escape($Message))
    }

    It 'accepts the zero-valued Disabled enum returned by DISM' {
        $script:feature = [pscustomobject]@{ State = [Smb1OptionalFeatureStateFixture]::Disabled }

        $warnings = @(HealthTest-Smb1Disabled 3>&1)

        $warnings | Should -HaveCount 1
        $warnings[0].Message | Should -Be '[PASS] SMBv1 is disabled'
    }

    It 'warns for <Case>' -ForEach @(
        @{ Case = 'no feature'; Feature = $null }
        @{ Case = 'missing State'; Feature = [pscustomobject]@{ FeatureName = 'SMB1Protocol' } }
        @{ Case = 'null State'; Feature = [pscustomobject]@{ State = $null } }
        @{ Case = 'empty State'; Feature = [pscustomobject]@{ State = '' } }
    ) {
        $script:feature = $Feature

        $warnings = @(HealthTest-Smb1Disabled 3>&1)

        $warnings | Should -HaveCount 1
        $warnings[0].Message | Should -Be '[WARNING] SMBv1 feature state is unavailable'
    }

    It 'preserves the details of a terminating query error' {
        Mock Get-WindowsOptionalFeature { throw 'DISM failed' }

        $warnings = @(HealthTest-Smb1Disabled 3>&1)

        $warnings | Should -HaveCount 1
        $warnings[0].Message | Should -Be "[WARNING] Could not read SMBv1 feature state`nDISM failed"
    }

    It 'rejects partial results after a nonterminating query error' {
        $script:feature = [pscustomobject]@{ State = 'Disabled' }
        $script:queryError = 'Partial DISM result'

        $warnings = @(HealthTest-Smb1Disabled 3>&1)

        $warnings | Should -HaveCount 1
        $warnings[0].Message | Should -Be "[WARNING] Could not read SMBv1 feature state`nPartial DISM result"
    }

    It 'skips the optional feature query in a non-elevated run' {
        $script:RunWithoutElevation = $true
        Mock Get-WindowsOptionalFeature { throw 'Unexpected query' }

        $warnings = @(HealthTest-Smb1Disabled 3>&1)

        $warnings | Should -HaveCount 1
        $warnings[0].Message | Should -Match '^\[WARNING\].*requires elevation'
        Should -Invoke Get-WindowsOptionalFeature -Exactly -Times 0
    }
}
