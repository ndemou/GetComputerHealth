Describe 'HealthTest-DcDnsRegistration' {
    BeforeAll {
        $script:directory = (Resolve-Path "$PSScriptRoot\..\..\health-tests").Path
        . "$script:directory\HealthTest-DcDnsRegistration.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            "$PSScriptRoot\..\..\Get-ComputerHealth.ps1", [ref]$null, [ref]$null)
        foreach ($name in 'Get-BuiltInHealthTestHostRequirement', 'Test-BuiltInHealthTestHostRequirement', 'Get-BuiltInHealthTestScriptsToImport') {
            $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
    }

    BeforeEach {
        Mock Resolve-DnsName {
            if ($Type -eq 'A') {
                [pscustomobject]@{ IPAddress = '192.0.2.1' }
            } else {
                [pscustomobject]@{ NameTarget = "$env:COMPUTERNAME.$env:USERDNSDOMAIN"; Port = 389 }
            }
        }
    }

    It 'selects the check for DC=<Dc>, DNS server=<Dns>' -ForEach @(
        @{ Dc = $false; Dns = $true }
        @{ Dc = $true; Dns = $false }
        @{ Dc = $true; Dns = $true }
    ) {
        $selected = Get-BuiltInHealthTestScriptsToImport -HealthTestsPath $script:directory -HostIsServer $true -HostIsDomainController $Dc -HostIsDnsServer $Dns

        ('HealthTest-DcDnsRegistration.ps1' -in $selected.Name) | Should -Be $Dc
    }

    It 'skips a directly invoked check on a member server' {
        Mock Get-CimInstance { [pscustomobject]@{ DomainRole = 3 } }
        $findings = @(HealthTest-DcDnsRegistration 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match '^\[INFO\]'
        Should -Invoke Resolve-DnsName -Exactly -Times 0
    }

    It 'warns when the role cannot be read' {
        Mock Get-CimInstance { throw 'CIM unavailable' }
        $findings = @(HealthTest-DcDnsRegistration 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match '^\[WARNING\]'
        $findings[0].Message | Should -Match 'CIM unavailable'
        Should -Invoke Resolve-DnsName -Exactly -Times 0
    }

    It 'checks the DNS records on a DC when the Kerberos record is <Case>' -ForEach @(
        @{ Case = 'present'; Expected = '\[PASS\] All tested DNS records' }
        @{ Case = 'missing'; Expected = '\[NOTICE\] DNS record KerberosDcSrv .*missing' }
    ) {
        $previous = $env:USERDNSDOMAIN
        try {
            $env:USERDNSDOMAIN = 'example.test'
            Mock Get-CimInstance { [pscustomobject]@{ DomainRole = 5 } }
            if ($Case -eq 'missing') {
                Mock Resolve-DnsName {} -ParameterFilter { $Name -like '_kerberos*' }
            }
            $findings = @(HealthTest-DcDnsRegistration 3>&1)

            ($findings.Message -join ' ') | Should -Match $Expected
            Should -Invoke Resolve-DnsName -Exactly -Times 3
            if ($Case -eq 'missing') { ($findings.Message -join ' ') | Should -Not -Match '\[PASS\]' }
        } finally {
            $env:USERDNSDOMAIN = $previous
        }
    }
}
