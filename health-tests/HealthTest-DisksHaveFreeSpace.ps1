# HostRequirement: All

function Test-DiskHasFreeSpace {
    param(
        [Parameter(Mandatory)][string]$PathOrDrive,
        [double]$WarnPct = 10,
        [double]$ErrorPct = 5
    )

    $root = $null
    if ($PathOrDrive -match '^[A-Za-z]:\\?$') {
        $root = $PathOrDrive.Substring(0, 2) + '\'
    } else {
        $resolved = Resolve-Path -LiteralPath $PathOrDrive -ErrorAction Stop
        $root = [System.IO.Path]::GetPathRoot($resolved.Path)
    }

    $di = [System.IO.DriveInfo]::new($root)
    if (-not $di.IsReady) { return }

    $total = $di.TotalSize
    $free = $di.AvailableFreeSpace
    if ($total -le 0 -or $free -lt 0 -or $free -gt $total) { return }

    $pctFree = [math]::Round(($free / $total) * 100, 2)
    if ($pctFree -lt $ErrorPct) {
        $level = 'Error'
    } elseif ($pctFree -lt $WarnPct) {
        $level = 'Warning'
    } else {
        $level = 'OK'
    }

    [pscustomobject]@{
        Drive        = $di.Name
        DriveType    = $di.DriveType.ToString()
        FreeGB       = [math]::Round($free / 1GB, 2)
        TotalGB      = [math]::Round($total / 1GB, 2)
        PercentFree  = $pctFree
        Level        = $level
    }
}

function HealthTest-DisksHaveFreeSpace {
<#
Description: Checks whether local disks have sufficient free space.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Disk)
Tags: Essential
Uses: Test-DiskHasFreeSpace.
#>
    param([object[]]$Drives = [System.IO.DriveInfo]::GetDrives())

    foreach ($d in $Drives) {
        if (-not $d.IsReady) { continue }
        $t = $d.DriveType.ToString()
        if (@('Fixed','Removable','Network') -notcontains $t) { continue }
        try {
            $result = Test-DiskHasFreeSpace -PathOrDrive $d.Name
        } catch {
            Write-Warning "[WARNING] Could not determine disk free space`nDrive: $($d.Name)`n$($_.Exception.Message)"
            continue
        }

        $level = if ($result -and $result.PSObject.Properties['Level']) { $result.Level }
        switch ([string]$level) {
            'Error'   { Write-Warning "[FAILURE] Disk is critically low on free space`n$result" }
            'Warning' { Write-Warning "[WARNING] Disk is low on free space`n$result" }
            'OK'      { Write-Warning "[PASS] Disk has enough free space`n$result" }
            default   { Write-Warning "[WARNING] Could not determine disk free space`nDrive: $($d.Name)" }
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-DisksHaveFreeSpace
}
