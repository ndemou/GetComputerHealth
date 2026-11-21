Describe 'HealthTest-IisBindings' {
    BeforeAll {
        . "$PSScriptRoot\..\..\health-tests\HealthTest-IisBindings.ps1"
        function Get-WindowsFeature { [CmdletBinding()] param($Name) }
        function Get-Website { [CmdletBinding()] param() }
        function Get-WebBinding { [CmdletBinding()] param($Name) }
    }

    BeforeEach {
        Mock Get-WindowsFeature { [pscustomobject]@{ Installed = $true } }
        Mock Get-Website {
            [pscustomobject]@{ Name = 'First' }
            if ($script:multiSite) { [pscustomobject]@{ Name = 'Second' } }
        }
        Mock Get-WebBinding {}
        Mock Get-WebBinding { $script:binding } -ParameterFilter { $Name -eq 'First' }
    }

    It 'reports <Level> for HTTP <Binding> across <Sites> site(s)' -ForEach @(
        @{ Binding = '*:80:'; Sites = 2; Level = 'NOTICE' }
        @{ Binding = '*:80:'; Sites = 1; Level = 'PASS' }
        @{ Binding = '192.0.2.10:80:'; Sites = 2; Level = 'PASS' }
        @{ Binding = '192.0.2.10:80:example.test'; Sites = 2; Level = 'PASS' }
        @{ Binding = '*:80:example.test'; Sites = 2; Level = 'PASS' }
        @{ Binding = '0.0.0.0:80:'; Sites = 2; Level = 'NOTICE' }
        @{ Binding = '[2001:db8::15]:80:'; Sites = 2; Level = 'PASS' }
        @{ Binding = '[::]:80:'; Sites = 2; Level = 'NOTICE' }
        @{ Binding = ':::80:'; Sites = 2; Level = 'NOTICE' }
        @{ Binding = '*:8080:'; Sites = 2; Level = 'PASS' }
        @{ Binding = 'malformed'; Sites = 2; Level = 'WARNING' }
        @{ Binding = 'not-an-ip:80:'; Sites = 2; Level = 'WARNING' }
    ) {
        $script:multiSite = $Sites -gt 1
        $script:binding = [pscustomobject]@{ protocol = 'http'; bindingInformation = $Binding }

        $findings = @(HealthTest-IisBindings 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match "^\[$Level\]"
    }

    It 'retains the HTTPS certificate warning independently of the HTTP check' {
        $script:multiSite = $false
        $script:binding = [pscustomobject]@{
            protocol = 'https'
            bindingInformation = '*:443:example.test'
            certificateHash = $null
        }

        $findings = @(HealthTest-IisBindings 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match '^\[WARNING\].*no certificate assigned'
    }
}
