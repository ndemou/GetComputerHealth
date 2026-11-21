# HostRequirement: All

function Get-WindowsOriginalInstallDate {
    [CmdletBinding()]
    param()

    $now = Get-Date
    $dates = @()
    $readErrors = @()
    $registryPaths = @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion')

    # Feature updates archive previous installation dates under Setup.
    try {
        $registryPaths += @(Get-ChildItem -Path 'HKLM:\SYSTEM\Setup' -ErrorAction Stop |
            Where-Object { $_.Name -like '*Source OS*' } |
            ForEach-Object { $_.PSPath })
    } catch {
        $readErrors += "Registry history: $($_.Exception.Message)"
    }

    foreach ($path in $registryPaths) {
        try {
            $value = Get-ItemProperty -Path $path -Name 'InstallDate' -ErrorAction Stop
            $seconds = 0L
            if ($value -and $value.PSObject.Properties['InstallDate'] -and
                [long]::TryParse([string]$value.InstallDate, [ref]$seconds) -and
                $seconds -gt 0 -and $seconds -le ([DateTimeOffset]$now).ToUnixTimeSeconds()) {
                $dates += [DateTimeOffset]::FromUnixTimeSeconds($seconds).LocalDateTime
            }
        } catch {
            $readErrors += "$($path): $($_.Exception.Message)"
        }
    }

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        if ($os -and $os.PSObject.Properties['InstallDate'] -and $os.InstallDate -is [datetime] -and
            $os.InstallDate.Year -gt 1970 -and $os.InstallDate -le $now) {
            $dates += $os.InstallDate
        }
    } catch {
        $readErrors += "Win32_OperatingSystem: $($_.Exception.Message)"
    }

    if ($dates.Count -eq 0) {
        return [pscustomobject]@{
            InstallDate = $null
            AgeDays = $null
            Confidence = 'Error - Date Not Found'
            Details = (@('No valid Windows installation date found in Registry or WMI.') + $readErrors) -join [Environment]::NewLine
        }
    }

    $installDate = $dates | Sort-Object | Select-Object -First 1
    return [pscustomobject]@{
        InstallDate = $installDate
        AgeDays = ($now - $installDate).Days
        Confidence = if ($dates.Count -gt 1) { 'Historical Analysis' } else { 'Current Feature Update (Fallback)' }
    }
}

function Get-DaysSinceLastVirusScan {
    [CmdletBinding()]
    param()

    try {
        $status = Get-MpComputerStatus -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ DaysSinceScan = $null; Details = "Get-MpComputerStatus: $($_.Exception.Message)" }
    }

    $now = Get-Date
    $times = foreach ($name in 'FullScanEndTime', 'QuickScanEndTime', 'FullScanStartTime', 'QuickScanStartTime') {
        if ($status -and $status.PSObject.Properties[$name]) {
            $time = $status.$name -as [datetime]
            if ($time -and $time.Year -gt 1970 -and $time -le $now) {
                $time
            }
        }
    }
    $last = $times | Sort-Object -Descending | Select-Object -First 1
    if ($last) {
        $age = [math]::Round(($now - $last).TotalDays, 1)
        return [pscustomobject]@{ DaysSinceScan = $age; Details = 'Source: Time' }
    }

    $ages = foreach ($name in 'FullScanAge', 'QuickScanAge') {
        $age = 0L
        if ($status -and $status.PSObject.Properties[$name] -and
            [long]::TryParse([string]$status.$name, [ref]$age) -and $age -ge 0 -and $age -lt 1MB) {
            $age
        }
    }
    if ($null -ne $ages) {
        return [pscustomobject]@{ DaysSinceScan = ($ages | Measure-Object -Minimum).Minimum; Details = 'Source: Age' }
    }

    return [pscustomobject]@{ DaysSinceScan = $null; Details = 'No valid Defender scan timestamps or ages.' }
}

function HealthTest-RecentWindowsScan {
<#
Description: Checks whether Microsoft Defender has performed a recent quick scan.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Tags: Essential
Uses: Get-DaysSinceLastVirusScan, Get-WindowsOriginalInstallDate.

Uses the Windows installation age as a grace period when Defender scan history
is unavailable. Warns after four days and reports a failure after eight.
#>
    $scan = Get-DaysSinceLastVirusScan
    if ($null -ne $scan.DaysSinceScan) {
        $days = [int]$scan.DaysSinceScan
        $title = 'Did windows defender perform a quick scan recently?'
        $details = "Last scan, $days days ago."
    } else {
        $install = Get-WindowsOriginalInstallDate
        if ($null -eq $install.InstallDate -or $null -eq $install.AgeDays) {
            Write-Warning "[WARNING] Could not determine Defender scan recency`n$($scan.Details)`n$($install.Details)"
            return
        }
        $days = $install.AgeDays
        $title = 'Defender scan history is unavailable'
        $details = "Windows installation age is $days days (installation-age fallback).`n$($scan.Details)"
    }

    $level = if ($days -lt 4) { 'PASS' } elseif ($days -lt 8) { 'WARNING' } else { 'FAILURE' }
    Write-Warning "[$level] $title`n$details"
}

if ($MyInvocation.InvocationName -ne '.') {
    HealthTest-RecentWindowsScan
}
