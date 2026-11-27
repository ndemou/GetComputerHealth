Describe 'HealthTest-Services stopped-service exceptions' {
    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        . (Join-Path $repoRoot 'health-tests\HealthTest-Services.ps1')
    }

    BeforeEach {
        $script:stoppedServices = @()
        Mock Get-CimInstance { $script:stoppedServices } -ParameterFilter {
            $ClassName -eq 'Win32_Service' -and $Filter -eq "StartMode='Auto' and State!='Running'"
        }
        Mock Get-ServiceVendors { @() }
    }

    It 'reports <ServiceName> as INFO with exit code <ExitCode>' -ForEach @(
        foreach ($serviceName in @(
            'edgeupdate', 'InventorySvc', 'MapsBroker', 'sppsvc', 'gupdate',
            'dmwappushservice', 'RemoteRegistry', 'StateRepository', 'gpsvc',
            'AppXSvc', 'TrustedInstaller', 'mapsbroker',
            'GoogleUpdaterInternalService123.0.1.2', 'GoogleUpdaterService123.0.1.2'
        )) {
            foreach ($serviceExitCode in @(0, 1077, 50, 1067, 987654)) {
                @{ ServiceName = $serviceName; ExitCode = $serviceExitCode }
            }
        }
    ) {
        $script:stoppedServices = @([pscustomobject]@{
            Name = $ServiceName
            DisplayName = 'Often stopped service'
            State = 'Stopped'
            StartMode = 'Auto'
            DelayedAutoStart = $true
            ExitCode = $ExitCode
        })

        $findings = @(HealthTest-Services 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match '^\[info\]'
        $findings[0].Message | Should -Match ([regex]::Escape("Service '$ServiceName'"))
        $findings[0].Message | Should -Match 'StartMode=Auto, DelayedAutoStart=True'
        $findings[0].Message | Should -Match ([regex]::Escape("ExitCode=$ExitCode("))
        $findings[0].Message | Should -Not -Match 'terminated normally|terminated normaly'
        Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter {
            $ClassName -eq 'Win32_Service' -and $Filter -eq "StartMode='Auto' and State!='Running'"
        }
        Should -Invoke Get-ServiceVendors -Times 1 -Exactly
    }

    It 'keeps <Level> for unlisted service <ServiceName> with exit code <ExitCode>' -ForEach @(
        @{ ServiceName = 'MSSQLSERVER'; ExitCode = 0; Level = 'NOTICE' }
        @{ ServiceName = 'MSSQLSERVER'; ExitCode = 1077; Level = 'NOTICE' }
        @{ ServiceName = 'MSSQLSERVER'; ExitCode = 50; Level = 'FAILURE' }
        @{ ServiceName = 'MSSQLSERVER'; ExitCode = 1067; Level = 'FAILURE' }
        @{ ServiceName = 'MSSQLSERVER'; ExitCode = 987654; Level = 'FAILURE' }
        @{ ServiceName = 'MapsBrokerExtra'; ExitCode = 50; Level = 'FAILURE' }
        @{ ServiceName = 'GoogleUpdaterService'; ExitCode = 50; Level = 'FAILURE' }
        @{ ServiceName = 'GoogleUpdaterService123.0Extra'; ExitCode = 50; Level = 'FAILURE' }
        @{ ServiceName = 'ExtraGoogleUpdaterInternalService123.0'; ExitCode = 50; Level = 'FAILURE' }
    ) {
        $script:stoppedServices = @([pscustomobject]@{
            Name = $ServiceName
            DisplayName = 'Unlisted service'
            State = 'Stopped'
            StartMode = 'Auto'
            DelayedAutoStart = $false
            ExitCode = $ExitCode
        })

        $findings = @(HealthTest-Services 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match "^\[$Level\]"
        $findings[0].Message | Should -Match ([regex]::Escape("Service '$ServiceName'"))
        $findings[0].Message | Should -Match ([regex]::Escape("ExitCode=$ExitCode("))
    }

    It 'still reports a broken payload for an excepted service' {
        $script:stoppedServices = @([pscustomobject]@{
            Name = 'MapsBroker'
            DisplayName = 'Downloaded Maps Manager'
            State = 'Stopped'
            StartMode = 'Auto'
            DelayedAutoStart = $true
            ExitCode = 50
        })
        Mock Get-ServiceVendors {
            [pscustomobject]@{ ServiceName = 'MapsBroker'; ExceptionsThrown = 'Missing payload' }
        }

        $findings = @(HealthTest-Services 3>&1)

        $findings | Should -HaveCount 2
        $findings[0].Message | Should -Match '^\[info\]'
        $findings[1].Message | Should -Match "^\[FAILURE\] Service 'MapsBroker' has a broken or unresolved executable/payload path\."
        $findings[1].Message | Should -Match 'Missing payload'
    }

    It 'still reports a payload inspection error' {
        Mock Get-ServiceVendors { throw 'Inspection failed' }

        $findings = @(HealthTest-Services 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Be '[FAILURE] Could not inspect service executable/payload paths: Inspection failed'
    }

    It 'reports PASS when there are no stopped auto-start services or broken payloads' {
        $findings = @(HealthTest-Services 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Be '[PASS] Services healthy: all auto-start services are running and service payload paths resolved.'
    }
}
