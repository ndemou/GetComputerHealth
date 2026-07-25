# HostRequirement: All

function HealthTest-ShadowStorage {
<#
Description: Checks whether Volume Shadow Copy storage is configured and sized within the recommended range.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Disk), Medium(Time)
Tags: Essential
Uses: None.
#>
  [CmdletBinding()]
  param(
    [string[]]$RequireOnVolumes = @(),
    [Nullable[double]]$MinRecommendedGB = $null,
    [Nullable[double]]$MaxRecommendedGB = $null
  )

  if ($RunWithoutElevation) {
    Write-Warning "[WARNING] this test requires elevation"
    return
  }

  $domainRole = (Get-CimInstance -ClassName Win32_ComputerSystem).DomainRole
  $isWorkstation = ($domainRole -in 0,1)
  $isServer = -not $isWorkstation

  $allVolumes = @(Get-CimInstance -ClassName Win32_Volume | Select-Object DeviceID, DriveLetter, DriveType)

  if ($isWorkstation) {
    if ($RequireOnVolumes.Count -eq 0) { $RequireOnVolumes = @('C:') }
    if ($null -eq $MinRecommendedGB) { $MinRecommendedGB = 5 }
    if ($null -eq $MaxRecommendedGB) { $MaxRecommendedGB = 25 }
  } elseif ($isServer) {
    if ($RequireOnVolumes.Count -eq 0) {
      $RequireOnVolumes = @(
        $allVolumes |
          Where-Object { $_.DriveType -eq 3 -and $_.DriveLetter } |
          ForEach-Object { $_.DriveLetter.TrimEnd('\') } |
          Sort-Object -Unique
      )
    }
  }

  $assoc = @(Get-CimInstance -ClassName Win32_ShadowStorage 2>$null)
  $vols = @($allVolumes)

  $present = @{}
  $statsByDrive = @{}

  foreach ($a in $assoc) {
    $drive = $null
    $devId = $null

    try {
      $volObj = $null

      if ($a.Volume -is [Microsoft.Management.Infrastructure.CimInstance]) {
        $volObj = $a.Volume
      } elseif ($a.Volume) {
        $volObj = Get-CimInstance -InputObject $a.Volume -ErrorAction Stop
      }

      if ($volObj) {
        $devId = [string]$volObj.DeviceID
        if ($volObj.DriveLetter) {
          $drive = [string]$volObj.DriveLetter
        }
      }
    } catch {
    }

    if (-not $devId -and $a.Volume) {
      $volRef = [string]$a.Volume
      if ($volRef -match 'DeviceID\s*=\s*"((?:[^"\\]|\\.)*)"') {
        $devId = $Matches[1] -replace '\\\\','\'
      }
    }

    if (-not $drive -and $devId) {
      $m = @($vols | Where-Object { $_.DeviceID -eq $devId } | Select-Object -First 1)
      if ($m.Count -gt 0 -and $m[0].DriveLetter) {
        $drive = [string]$m[0].DriveLetter
      }
    }

    if (-not $drive -and $devId -match '^[A-Z]:\\?$') {
      $drive = $devId.TrimEnd('\')
    }

    if (-not $drive -and $devId) {
      $drive = $devId.TrimEnd('\')
    }

    if (-not $drive) { continue }

    $k = $drive.TrimEnd('\')
    $present[$k] = $true

    if (-not $statsByDrive.ContainsKey($k)) {
      $statsByDrive[$k] = [pscustomobject]@{
        MaxSpaceBytes = [uint64]0
        AllocatedSpaceBytes = [uint64]0
        UsedSpaceBytes = [uint64]0
      }
    }

    if ($null -ne $a.MaxSpace -and [uint64]$a.MaxSpace -gt 0) {
      $statsByDrive[$k].MaxSpaceBytes += [uint64]$a.MaxSpace
    }
    if ($null -ne $a.AllocatedSpace -and [uint64]$a.AllocatedSpace -gt 0) {
      $statsByDrive[$k].AllocatedSpaceBytes += [uint64]$a.AllocatedSpace
    }
    if ($null -ne $a.UsedSpace -and [uint64]$a.UsedSpace -gt 0) {
      $statsByDrive[$k].UsedSpaceBytes += [uint64]$a.UsedSpace
    }
  }

  $rangeOutOfBounds = New-Object System.Collections.Generic.List[string]
  $rangeUnknown = New-Object System.Collections.Generic.List[string]
  $outOfRange = $false

  if ($null -ne $MinRecommendedGB -or $null -ne $MaxRecommendedGB) {
    $minRecommendedValue = if ($null -ne $MinRecommendedGB) { [double]$MinRecommendedGB } else { $null }
    $maxRecommendedValue = if ($null -ne $MaxRecommendedGB) { [double]$MaxRecommendedGB } else { $null }
    $targets = if ($RequireOnVolumes.Count -gt 0) {
      @($RequireOnVolumes | ForEach-Object { $_.TrimEnd('\') } | Sort-Object -Unique)
    } else {
      @($present.Keys | Sort-Object)
    }

    foreach ($k in $targets) {
      if (-not $statsByDrive.ContainsKey($k)) { continue }

      $s = $statsByDrive[$k]
      [uint64]$maxBytes = $s.MaxSpaceBytes
      if ($maxBytes -le 0 -and $s.AllocatedSpaceBytes -gt 0) {
        $maxBytes = $s.AllocatedSpaceBytes
      }

      if ($maxBytes -le 0) {
        $rangeUnknown.Add("$k size not available")
        continue
      }

      $sizeGB = [math]::Round(($maxBytes / 1GB), 2)

      if ($null -ne $minRecommendedValue -and $sizeGB -lt $minRecommendedValue) {
        $outOfRange = $true
        $rangeOutOfBounds.Add("$k=$sizeGB GB below min $minRecommendedValue GB")
      }

      if ($null -ne $maxRecommendedValue -and $sizeGB -gt $maxRecommendedValue) {
        $outOfRange = $true
        $rangeOutOfBounds.Add("$k=$sizeGB GB above max $maxRecommendedValue GB")
      }
    }
  }

  if ($RequireOnVolumes.Count -gt 0) {
    $missing = @()

    foreach ($v in $RequireOnVolumes) {
      $k = $v.TrimEnd('\')
      if (-not $present.ContainsKey($k)) {
        $missing += $k
        Write-Warning "[NOTICE] Shadow storage not configured on $k"
      }
    }

    if ($missing.Count -eq 0) {
      Write-Warning ("[PASS] Shadow storage on required volumes`nConfigured on: " + ((@($present.Keys) | Sort-Object) -join ', '))
    }
  } else {
    if ($present.Count -gt 0) {
      Write-Warning ("[PASS] Shadow storage configured`nOn: " + ((@($present.Keys) | Sort-Object) -join ', '))
    } else {
      Write-Warning "[NOTICE] Shadow storage (Volume Shadow Copies) is not enabled`nUsers won't see Previous Version for files/folders. (Note that this issue is UNRELATED to the VSS service that backup software use.)"
    }
  }

  if ($outOfRange -and $rangeOutOfBounds.Count -gt 0) {
    Write-Warning ("[NOTICE] Shadow storage size outside recommended range`n" + ($rangeOutOfBounds -join '; '))
  }

  if ($rangeUnknown.Count -gt 0) {
    Write-Warning ("[info] Shadow storage size could not be determined`n" + ($rangeUnknown -join '; '))
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-ShadowStorage
}
