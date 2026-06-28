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

function Compress-HealthDiagnosticOutputLines {
  <#
  .SYNOPSIS
  Shortens noisy diagnostic output before adding it to health-test comments.

  .DESCRIPTION
  Use this when a health test includes command output that can repeat the same
  sentence many times, such as dcdiag event-log detail. The function removes
  blank lines, splits long sentence-like runs into separate lines, removes
  duplicate lines while preserving first-seen order, caps the line count, and
  truncates very long results.

  .EXAMPLE
  $summary = Compress-HealthDiagnosticOutputLines -Lines @($dcdiagLines) -join "`n"

  .EXAMPLE
  $summary = Compress-HealthDiagnosticOutputLines -Lines $lines -MaximumLines 20 -MaximumCharacters 1000
  #>
  [CmdletBinding()]
  param(
    [AllowEmptyCollection()][string[]]$Lines = @(),
    [int]$MaximumLines = 50,
    [int]$MaximumCharacters = 2000
  )

  $collectedLines = New-Object 'System.Collections.Generic.List[string]'
  foreach ($line in @($Lines)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    $lineText = ([string]$line).TrimEnd()
    $candidateLines = @($lineText -replace '(([a-z]{2,30})(;|[.][)]?)) +', "`$1`n" -split "`n")
    foreach ($candidateLine in $candidateLines) {
      if ([string]::IsNullOrWhiteSpace($candidateLine)) { continue }
      [void]$collectedLines.Add(([string]$candidateLine).Trim())
    }
  }

  $uniqueLines = New-Object 'System.Collections.Generic.List[string]'
  $seenLines = @{}
  foreach ($collectedLine in $collectedLines) {
    if ($seenLines.ContainsKey($collectedLine)) { continue }

    $seenLines[$collectedLine] = $true
    [void]$uniqueLines.Add($collectedLine)
    if ($MaximumLines -gt 0 -and $uniqueLines.Count -ge $MaximumLines) { break }
  }

  $resultLines = @($uniqueLines)
  $resultText = $resultLines -join "`n"
  if ($MaximumCharacters -gt 0 -and $resultText.Length -gt $MaximumCharacters) {
    return @($resultText.Substring(0, $MaximumCharacters - 3) + '...')
  }

  return $resultLines
}
