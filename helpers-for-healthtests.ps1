function Test-IsVirtualMachine {
  # returns $true if it guesses the computer is VM
  [CmdletBinding()]
  [OutputType([bool])]
  param()

  $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
  $csp = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction SilentlyContinue

  $manufacturer = if ($cs -and $null -ne $cs.PSObject.Properties['Manufacturer']) { $cs.Manufacturer }
  $vendor = if ($csp -and $null -ne $csp.PSObject.Properties['Vendor']) { $csp.Vendor }
  $model = if ($cs -and $null -ne $cs.PSObject.Properties['Model']) { $cs.Model }
  $productName = if ($csp -and $null -ne $csp.PSObject.Properties['Name']) { $csp.Name }

  $man = ($manufacturer, $vendor | Where-Object { $_ }) -join ' '
  $mod = ($model, $productName | Where-Object { $_ }) -join ' '
  $txt = "$man $mod"

  if (-not $txt) { return $false }

  $patterns = @{
    'Hyper-V'    = 'Microsoft Corporation Virtual Machine'
    'VMware'     = 'VMware'
    'VirtualBox' = 'VirtualBox'
    'Xen'        = 'Xen HVM domU'
    'KVM'        = 'KVM QEMU'
    'Azure'      = 'Microsoft Corporation Virtual Machine'
    'EC2'        = 'EC2'
    'GCP'        = 'Google Compute Engine'
  }

  foreach ($k in $patterns.Keys) {
    foreach ($needle in $patterns[$k].Split(' ')) {
      if ($txt -like "*$needle*") {
        return $true
      }
    }
  }

  if ($txt -like '*Virtual Machine*' -or $txt -like '*VirtualBox*' -or $txt -like '*VMware*') {
    return $true
  }

  return $false
}

function Test-IsLaptopOrMobile {
  # returns $true if it guesses the computer is laptop/mobile
  [CmdletBinding()]
  [OutputType([bool])]
  param()

  $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
  $enc = Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue
  $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue

  $chassisTypes = @()
  if ($enc -and $enc.ChassisTypes) { $chassisTypes = @($enc.ChassisTypes) }

  $mobileChassis = 8, 9, 10, 11, 12, 14, 18, 30, 31, 32
  $desktopChassis = 3, 4, 5, 6, 7, 13, 15, 24, 34

  $hasMobileType = @($chassisTypes | Where-Object { $mobileChassis -contains $_ }).Count -gt 0
  $hasDesktopType = @($chassisTypes | Where-Object { $desktopChassis -contains $_ }).Count -gt 0

  $pcSystemType = $null
  if ($cs -and (Get-Member -InputObject $cs -Name PCSystemType -MemberType *Property -ErrorAction SilentlyContinue)) {
    $pcSystemType = $cs.PCSystemType
  }

  $hasBattery = $null -ne $bat

  $isMobile = $false
  if ($hasMobileType -or $pcSystemType -eq 2 -or ($hasBattery -and -not $hasDesktopType)) {
    $isMobile = $true
  }

  return $isMobile
}
