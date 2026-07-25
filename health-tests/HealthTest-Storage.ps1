# HostRequirement: All

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
    param([int]$MaxTemperatureC = 70,[int]$MaxPercentUsed = 95)


    $allHealthy = $true
    $disks = Get-PhysicalDisk -ErrorAction SilentlyContinue
    if (-not $disks) { Write-Warning "[FAILURE] No disks visible via Get-PhysicalDisk"; return }

    foreach ($d in $disks) {
        # 1) Explicit predictive failure
        $predFail = $false
        if ($d.PSObject.Properties.Name -contains 'OperationalStatus') {
            $os = $d.OperationalStatus
            if ($os -is [array]) { foreach($s in $os){ if ($s -eq 'Predictive Failure') { $predFail=$true; break } } }
            else { if ($os -eq 'Predictive Failure') { $predFail=$true } }
        }
        if ($predFail) {
            Write-Warning ("[FAILURE] OperationalStatus=Predictive Failure for disk '{0}'" -f $d.FriendlyName)
            $allHealthy = $false
        }

        # 2) HealthStatus
        if ($d.PSObject.Properties.Name -contains 'HealthStatus') {
            if ($d.HealthStatus -ne 'Healthy') {
                Write-Warning ("[FAILURE] HealthStatus={0} for disk '{1}'" -f $d.HealthStatus,$d.FriendlyName)
                $allHealthy = $false
            }
        }

        # 3) Reliability counters (temp, errors, wear)
        try {
            $c = $d | Get-StorageReliabilityCounter -ErrorAction Stop
            if ($c) {
                if ($c.PSObject.Properties.Name -contains 'Temperature') {
                    if ([double]$c.Temperature -gt $MaxTemperatureC) {
                        Write-Warning ("[FAILURE] Temperature({0}) exceeds max for disk '{1}'" -f $c.Temperature,$d.FriendlyName)
                        $allHealthy = $false
                    }
                }

                $uncorr = 0
                foreach ($p in 'ReadErrorsUncorrected','WriteErrorsUncorrected','MediaErrors','UncorrectableErrors') {
                    if ($c.PSObject.Properties.Name -contains $p) { $uncorr += [int64]$c.$p }
                }
                if ($uncorr -gt 0) {
                    Write-Warning ("[FAILURE] Uncorrectable error counter not zero for disk '{0}'" -f $d.FriendlyName)
                    $allHealthy = $false
                }

                $percentUsed = $null; $propName='(UNKNOWN)'
                foreach ($name in 'PercentageUsed','PercentUsed','Wear','WearPercentage','LifeRemaining','PercentLifeRemaining','LifeLeftPercent') {
                    if ($c.PSObject.Properties.Name -contains $name) {
                        $val = [double]$c.$name
                        if ($name -in 'LifeRemaining','PercentLifeRemaining','LifeLeftPercent') { $percentUsed = 100 - $val } else { $percentUsed = $val }
                        $propName = $name; break
                    }
                }
                if ($percentUsed -ne $null -and $percentUsed -ge $MaxPercentUsed) {
                    Write-Warning ("[FAILURE] {0} >= {1} for disk '{2}'" -f $propName,$MaxPercentUsed,$d.FriendlyName)
                    $allHealthy = $false
                }
            }
        } catch { }
    }

    if ($allHealthy) { Write-Warning "[PASS] HealthTest-Storage passed for all disks" }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-Storage
}
