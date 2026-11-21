Describe 'HealthTest-Storage' {
    BeforeAll {
        . "$PSScriptRoot\..\..\health-tests\HealthTest-Storage.ps1"
        function Get-PhysicalDisk { [CmdletBinding()] param() }
        function Get-StorageReliabilityCounter {
            [CmdletBinding()]
            param([Parameter(ValueFromPipeline)]$PhysicalDisk)
            process {}
        }
    }

    BeforeEach {
        Mock Get-PhysicalDisk {
            foreach ($name in $script:counterResults.Keys | Sort-Object) {
                [pscustomobject]@{
                    FriendlyName = $name
                    HealthStatus = if ($script:unhealthy) { 'Unhealthy' } else { 'Healthy' }
                    OperationalStatus = 'OK'
                }
            }
        }
        Mock Get-StorageReliabilityCounter {
            $counter = $script:counterResults[$PhysicalDisk.FriendlyName]
            if ($counter -is [Exception]) { throw $counter }
            $counter
        }
        $script:unhealthy = $false
    }

    It 'reports <Expected> for <Case>' -ForEach @(
        @{ Case = 'complete healthy data'; Data = [pscustomobject]@{ Temperature = 29; Wear = 2; ReadErrorsUncorrected = 0 }; Unhealthy = $false; Expected = 'PASS'; Detail = $null }
        @{ Case = 'optional wear counter unavailable'; Data = [pscustomobject]@{ Temperature = 29; Wear = $null; ReadErrorsUncorrected = 0 }; Unhealthy = $false; Expected = 'INFO,PASS'; Detail = $null }
        @{ Case = 'unhealthy disk'; Data = [pscustomobject]@{ Temperature = 29; Wear = 0; ReadErrorsUncorrected = 0 }; Unhealthy = $true; Expected = 'FAILURE'; Detail = $null }
        @{ Case = 'no counter object'; Data = $null; Unhealthy = $false; Expected = 'INFO'; Detail = $null }
        @{ Case = 'all counters null'; Data = [pscustomobject]@{ Temperature = $null; Wear = $null; ReadErrorsUncorrected = $null }; Unhealthy = $false; Expected = 'INFO'; Detail = $null }
        @{ Case = 'provider error'; Data = [InvalidOperationException]::new('Provider failed'); Unhealthy = $false; Expected = 'WARNING'; Detail = 'Provider failed' }
    ) {
        $script:counterResults = @{ DiskA = $Data }
        $script:unhealthy = $Unhealthy
        $findings = @(HealthTest-Storage 3>&1)
        $levels = @($findings.Message | ForEach-Object { $_ -replace '(?s)^\[([A-Z]+)\].*', '$1' })

        ($levels -join ',') | Should -Be $Expected
        if ($Detail) { $findings[0].Message | Should -Match $Detail }
    }

    It 'reports CIM_ERR_NOT_SUPPORTED as INFO regardless of the exception message' {
        $errorData = [Microsoft.Management.Infrastructure.CimInstance]::new('CIM_Error')
        $status = [Microsoft.Management.Infrastructure.CimProperty]::Create('CIMStatusCode', [uint32]7, 'UInt32', 'None')
        $errorData.CimInstanceProperties.Add($status)
        $script:counterResults = @{ DiskA = [Microsoft.Management.Infrastructure.CimException]::new($errorData) }

        $findings = @(HealthTest-Storage 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match '^\[INFO\] Reliability telemetry is unsupported'
    }

    It 'reports a later disk fault after an earlier disk query fails' {
        $script:counterResults = @{
            DiskA = [UnauthorizedAccessException]::new('Access denied')
            DiskB = [pscustomobject]@{ Temperature = 90; Wear = 0; ReadErrorsUncorrected = 0 }
        }

        $findings = @(HealthTest-Storage 3>&1)

        $findings | Should -HaveCount 2
        $findings[0].Message | Should -Match '^\[WARNING\].*DiskA'
        $findings[1].Message | Should -Match '^\[FAILURE\].*DiskB'
    }
}
