# HostRequirement: All

if (-not (Get-Command -Name 'Get-PropValue' -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'helpers-for-healthtests.ps1')
}

function HealthTest-Storage {
<#
Description: Checks physical disks for predictive failure, unhealthy status, temperature, and reliability warnings.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Time), Medium(Disk)
Uses: Get-PhysicalDisk, Get-StorageReliabilityCounter.
#>
    [CmdletBinding()]
    param([int]$MaxTemperatureC = 70, [int]$MaxPercentUsed = 95)

    try {
        $disks = @(Get-PhysicalDisk -ErrorAction Stop)
    } catch {
        Write-Warning "[WARNING] Could not enumerate physical disks`n$($_.Exception.Message)"
        return
    }
    if (-not $disks) {
        Write-Warning '[FAILURE] No disks visible via Get-PhysicalDisk'
        return
    }

    $allHealthy = $true
    $inspectionComplete = $true
    foreach ($disk in $disks) {
        $diskName = $disk.FriendlyName
        $operationalStatus = Get-PropValue $disk 'OperationalStatus'
        $healthStatus = Get-PropValue $disk 'HealthStatus'

        if ('Predictive Failure' -in $operationalStatus) {
            Write-Warning "[FAILURE] OperationalStatus=Predictive Failure for disk '$diskName'"
            $allHealthy = $false
        }
        if ($healthStatus -and $healthStatus -notin 'Healthy', 'Unknown') {
            Write-Warning "[FAILURE] HealthStatus=$healthStatus for disk '$diskName'"
            $allHealthy = $false
        }
        if (-not $operationalStatus -or -not $healthStatus -or $healthStatus -eq 'Unknown') {
            Write-Warning "[WARNING] Basic disk status is incomplete for disk '$diskName'"
            $inspectionComplete = $false
        }

        try {
            $counters = $disk | Get-StorageReliabilityCounter -ErrorAction Stop
        } catch {
            $inspectionComplete = $false
            $details = "$($_.FullyQualifiedErrorId): $($_.Exception.Message)"
            $exception = $_.Exception
            if ($exception -is [Microsoft.Management.Infrastructure.CimException] -and
                ($exception.NativeErrorCode -eq [Microsoft.Management.Infrastructure.NativeErrorCode]::NotSupported -or
                    $exception.StatusCode -eq 7)) {
                Write-Warning "[INFO] Reliability telemetry is unsupported for disk '$diskName'`nHealthStatus=$healthStatus; OperationalStatus=$operationalStatus.`n$details"
            } else {
                Write-Warning "[WARNING] Could not read reliability telemetry for disk '$diskName'`nHealthStatus=$healthStatus; OperationalStatus=$operationalStatus.`n$details"
            }
            continue
        }

        $temperature = Get-PropValue $counters 'Temperature'
        $errorCounts = @(foreach ($name in 'ReadErrorsUncorrected', 'WriteErrorsUncorrected', 'MediaErrors', 'UncorrectableErrors') {
            Get-PropValue $counters $name
        }) | Where-Object { $null -ne $_ }
        $percentUsed = $null
        foreach ($name in 'PercentageUsed', 'PercentUsed', 'Wear', 'WearPercentage', 'LifeRemaining', 'PercentLifeRemaining', 'LifeLeftPercent') {
            $value = Get-PropValue $counters $name
            if ($null -eq $value) { continue }
            $wearProperty = $name
            $percentUsed = if ($name -in 'LifeRemaining', 'PercentLifeRemaining', 'LifeLeftPercent') {
                100 - [double]$value
            } else {
                [double]$value
            }
            break
        }

        if ($null -ne $temperature -and $temperature -gt $MaxTemperatureC) {
            Write-Warning "[FAILURE] Disk temperature exceeds $MaxTemperatureC C: '$diskName'`nCurrent temperature: $temperature C."
            $allHealthy = $false
        }
        if ($errorCounts | Where-Object { $_ -gt 0 }) {
            Write-Warning "[FAILURE] Uncorrectable error counter not zero for disk '$diskName'"
            $allHealthy = $false
        }
        if ($null -ne $percentUsed -and $percentUsed -ge $MaxPercentUsed) {
            Write-Warning "[FAILURE] $wearProperty >= $MaxPercentUsed for disk '$diskName'"
            $allHealthy = $false
        }

        $unavailable = @()
        if ($null -eq $temperature) { $unavailable += 'temperature' }
        if ($null -eq $errorCounts) { $unavailable += 'uncorrectable errors' }
        if ($null -eq $percentUsed) { $unavailable += 'wear' }
        if ($unavailable.Count -eq 3) {
            $inspectionComplete = $false
            Write-Warning "[INFO] No usable reliability counters for disk '$diskName'`nBasic status: HealthStatus=$healthStatus; OperationalStatus=$operationalStatus."
        } elseif ($unavailable.Count -gt 0) {
            Write-Warning "[INFO] Some reliability measurements are unavailable for disk '$diskName'`n$($unavailable -join ', ')"
        }
    }

    if ($allHealthy -and $inspectionComplete) {
        Write-Warning "[PASS] HealthTest-Storage passed for all disks`nBasic disk status and available reliability counters were checked."
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    HealthTest-Storage
}
