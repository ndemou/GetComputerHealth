# HostRequirement: All

if (-not (Get-Command -Name 'Get-PropValue' -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'helpers-for-healthtests.ps1')
}

function HealthTest-NtfsDirtyBit {
<#
Description: Checks whether any NTFS volumes have the dirty bit set.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Disk)
Tags: Essential
Uses: Get-CimInstance (Win32_Volume).
#>
    try {
        $volumes = @(Get-CimInstance -ClassName Win32_Volume -Property FileSystem, DriveLetter, DeviceID, Name, DirtyBitSet -ErrorAction Stop |
            Where-Object { (Get-PropValue $_ 'FileSystem') -eq 'NTFS' })
    } catch {
        Write-Warning "[WARNING] Could not enumerate NTFS volumes`n$($_.Exception.Message)"
        return
    }
    if ($volumes.Count -eq 0) {
        Write-Warning '[WARNING] No NTFS volumes were available for dirty bit inspection'
        return
    }

    $dirty = @()
    $incomplete = @()
    foreach ($volume in $volumes) {
        $identity = Get-PropValue $volume 'DriveLetter'
        if (-not $identity) { $identity = Get-PropValue $volume 'DeviceID' }
        if (-not $identity) { $identity = Get-PropValue $volume 'Name' }
        if (-not $identity) {
            $identity = '<unidentified volume>'
            $incomplete += $identity
        }

        $status = Get-PropValue $volume 'DirtyBitSet'
        if ($status -isnot [bool]) {
            $incomplete += $identity
        } elseif ($status) {
            $dirty += $identity
        }
    }

    if ($dirty.Count -gt 0) {
        $volumeNames = ($dirty | Sort-Object -Unique) -join ', '
        Write-Warning "[WARNING] NTFS dirty bit set on: $volumeNames"
    }
    if ($incomplete.Count -gt 0) {
        $volumeNames = ($incomplete | Sort-Object -Unique) -join ', '
        Write-Warning "[WARNING] NTFS dirty bit inspection is incomplete`nUnavailable volume identity or status: $volumeNames"
    } elseif ($dirty.Count -eq 0) {
        Write-Warning '[PASS] No NTFS dirty volumes'
    }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-NtfsDirtyBit
}
