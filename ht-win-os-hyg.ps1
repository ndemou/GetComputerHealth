<#
Windows OS Hygiene
#>


Function Get-WindowsOriginalInstallDate {
    <#
    .SYNOPSIS
        Robustly determines the Windows Installation date.
    .DESCRIPTION
        Aggregates dates from Registry History (for original install),
        Current Registry, and WMI. Returns the oldest valid date found.
        If history is missing, it gracefully falls back to the latest
        feature update date.
    #>
    [CmdletBinding()]
    param()

    process {
        # List to hold all potential dates found
        $candidateDates = New-Object System.Collections.Generic.List[DateTime]

        # Unix Epoch for converting Registry timestamps
        $unixEpoch = (Get-Date -Date "01/01/1970").ToLocalTime()

        # --- LAYER 1: The "Source OS" History (The Real Original Date) ---
        # Windows archives old install dates here during feature updates.
        try {
            $setupKey = "HKLM:\SYSTEM\Setup"
            if (Test-Path $setupKey) {
                # Find keys like "Source OS (Updated on...)"
                $sourceKeys = Get-ChildItem -Path $setupKey -ErrorAction SilentlyContinue |
                              Where-Object { $_.Name -like "*Source OS*" }

                foreach ($key in $sourceKeys) {
                    $prop = Get-ItemProperty -Path $key.PSPath -Name "InstallDate" -ErrorAction SilentlyContinue
                    if ($prop -and $prop.InstallDate -is [Int32] -or $prop.InstallDate -is [Int64]) {
                        # Add to candidates
                        $candidateDates.Add($unixEpoch.AddSeconds($prop.InstallDate))
                    }
                }
            }
        }
        catch {
            Write-Verbose "Could not access Registry History: $_"
        }

        # --- LAYER 2: The Current Registry (The Feature Update Date) ---
        # Usually represents the last major update (e.g., 22H2).
        try {
            $currentPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
            $currentProp = Get-ItemProperty -Path $currentPath -Name "InstallDate" -ErrorAction SilentlyContinue

            if ($currentProp -and $currentProp.InstallDate) {
                $candidateDates.Add($unixEpoch.AddSeconds($currentProp.InstallDate))
            }
        }
        catch {
            Write-Verbose "Could not access Current Registry: $_"
        }

        # --- LAYER 3: WMI Fallback (The Safety Net) ---
        # If Registry is totally unreadable, WMI usually works.
        # This usually matches Layer 2, but serves as a backup.
        try {
            $wmiOS = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
            if ($wmiOS -and $wmiOS.InstallDate) {
                $candidateDates.Add($wmiOS.InstallDate)
            }
        }
        catch {
            Write-Verbose "Could not access WMI: $_"
        }

        # --- FINAL DECISION ---
        # 1. Remove duplicates and Sort
        # 2. Pick the FIRST one (The Oldest)

        if ($candidateDates.Count -gt 0) {
            $finalDate = ($candidateDates | Sort-Object)[0]

            # Determine confidence level for the output
            $methodUsed = if ($candidateDates.Count -gt 1) { "Historical Analysis" } else { "Current Feature Update (Fallback)" }

            return [PSCustomObject]@{
                InstallDate = $finalDate
                Confidence  = $methodUsed
                AgeDays     = (New-TimeSpan -Start $finalDate -End (Get-Date)).Days
            }
        }
        else {
            # Absolute worst case: return current time (should theoretically never happen on a working OS)
            Write-Warning "Critical Failure: No install date found in Registry or WMI."
            return [PSCustomObject]@{
                InstallDate = (Get-Date)
                Confidence  = "Error - Date Not Found"
                AgeDays     = 0
            }
        }
    }
}

function Get-DaysSinceLastVirusScan {
  [CmdletBinding()] param([int]$Days=3)
  try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch {
    return [pscustomobject]@{DaysSinceScan=$null;Details="Get-MpComputerStatus failed with error $_.Exception.Message"}
  }

  $ts = @()
  foreach($p in 'FullScanEndTime','QuickScanEndTime','FullScanStartTime','QuickScanStartTime'){
    $v = $mp.$p
    if ($v) { try { $ts += [datetime]$v } catch {} }
  }
  $last = $null
  if ($ts.Count -gt 0) { $last = ($ts | Sort-Object -Descending)[0] }

  if ($last) {
    $ageDays = ((Get-Date) - $last).TotalDays
    $ok = ($ageDays -le $Days)
    return [pscustomobject]@{DaysSinceScan=[math]::Round($ageDays,1);Details='Source: Time'}
  }

  $ages = @()
  foreach($ap in 'FullScanAge','QuickScanAge'){
    $av = $mp.$ap
    if ($null -ne $av) { $ages += [int64]$av }
  }
  if ($ages.Count -gt 0) {
    $minAge = ($ages | Measure-Object -Minimum).Minimum
    $ok = ($minAge -le $Days)
    return [pscustomobject]@{DaysSinceScan=$minAge;Details='Source: Age'}
  }

  return [pscustomobject]@{DaysSinceScan=$null;Details='No scan timestamps or ages'}
}

function HealthTest-RecentWindowsScan__E {
<#
.SYNOPSIS
Checks Recent Windows Scan

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: None.
FalsePositives: None.
#>
    $MAX_WARN_DAYS = 4
    $MAX_FAILURE_DAYS = 8

    $installationAge = $null
    $o = Get-DaysSinceLastVirusScan

    if ($null -ne $o.DaysSinceScan -and $o.DaysSinceScan -lt 1024*1024) {
        $days = [int]$o.DaysSinceScan
        $installationAge = "n/a"
    } else {
        try {
            $installationAge = (Get-WindowsOriginalInstallDate).agedays
            $days = [int]$installationAge
        } catch {
            $installationAge = "UNKNOWN"
            $days = 99999
        }
    }

    $comment = "Last scan, $days days ago. Windows installation age is $installationAge days."

    if ($days -lt $MAX_WARN_DAYS) {
        Write-Warning ("[pass] Did windows defender perform a quick scan recently?`n$comment")
    } elseif ($days -lt $MAX_FAILURE_DAYS) {
        Write-Warning ("[warning] Did windows defender perform a quick scan recently?`n$comment")
    } else {
        Write-Warning ("[failure] Did windows defender perform a quick scan recently?`n$comment")
    }
}


function HealthTest-SchanelBaseline__E{
<#
.SYNOPSIS
Checks Schanel Baseline

.DESCRIPTION
AppliesTo: Server
Scope: Computer
Category: Audit / Compliance / Informational
Impact: Medium(Time)
Uses: Get-ItemProperty.
FalsePositives: Possible on legacy systems where older protocols are intentionally required.
Checks the effective Schannel server-side protocol baseline for SSL 3.0, TLS 1.0, TLS 1.1, and TLS 1.2.
#>
  $base='HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols'
  function Get-EffState($proto,$role){
    $key=(Join-Path (Join-Path $base $proto) $role)
    $enabled=$null; $disabledByDefault=$null; $src='OS default'; $state='Enabled'
    if(Test-Path $key){
      try{
        $p=Get-ItemProperty -Path $key -ErrorAction Stop
        if($p.PSObject.Properties.Name -contains 'Enabled'){ $enabled=[uint32]$p.Enabled }
        if($p.PSObject.Properties.Name -contains 'DisabledByDefault'){ $disabledByDefault=[uint32]$p.DisabledByDefault }
      }catch{}
    }
    if($enabled -ne $null){
      if($enabled -eq 0){ $state='Disabled'; $src='Enabled=0' } else { $state='Enabled'; $src='Enabled=1/FFFF' }
    } else {
      if($disabledByDefault -ne $null -and $disabledByDefault -eq 1){ $state='Disabled'; $src='DisabledByDefault=1' } else { $state='Enabled'; $src='OS default' }
    }
    [pscustomobject]@{ Protocol=$proto; Role=$role; CurrentState=$state; Source=$src; EnabledRaw=$enabled; DisabledByDefaultRaw=$disabledByDefault; Key=$key }
  }

  $items=@()
  $items += Get-EffState 'SSL 3.0' 'Server'
  $items += Get-EffState 'TLS 1.0' 'Server'
  $items += Get-EffState 'TLS 1.1' 'Server'
  $items += Get-EffState 'TLS 1.2' 'Server'

  $should=@{
    'SSL 3.0'='Disabled'
    'TLS 1.0'='Disabled'
    'TLS 1.1'='Disabled'
    'TLS 1.2'='Enabled'
  }

  $bad=@()
  foreach($it in $items){
    $want=$should[$it.Protocol]
    if($it.CurrentState -ne $want){ $bad += $it }
  }

  $det=""
  foreach($it in $items){
    $e=$it.EnabledRaw; if($null -eq $e){ $e='<absent>' }
    $d=$it.DisabledByDefaultRaw; if($null -eq $d){ $d='<absent>' }
    $det += "    {0}\Server: Current={1}; Source={2}; Enabled={3}; DisabledByDefault={4}`n" -f $it.Protocol,$it.CurrentState,$it.Source,$e,$d
  }

  if($bad.Count -eq 0){
    Write-Warning "[pass] Schannel baseline OK (SSL3/TLS1.0/TLS1.1 disabled, TLS1.2 enabled)"
  } else {
    $why="Inbound services that rely on Schannel may negotiate legacy TLS/SSL protocols if they remain enabled. E.g. LDAP over TLS, WinRM, ADWS..."
    $comment = ("Detected mismatches:`n"+($bad | ForEach-Object { "  - {0}: Current={1}, Recommended={2}" -f $_.Protocol,$_.CurrentState,$should[$_.Protocol] } | Out-String) + "`nRegistry snapshot:`n"+$det+$why)
    Write-Warning "[warning] Schannel baseline not hardened`n$comment"
  }
}

function HealthTest-DefenderStatus__E {
<#
.SYNOPSIS
Checks Defender Status

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-MpComputerStatus.
FalsePositives: None.
#>
    param([int]$WarnSigAgeDays=2,[int]$FailSigAgeDays=7)
    $s = Get-MpComputerStatus
    $ok = $true
    if ($s.AntispywareSignatureAge -ge $FailSigAgeDays -or $s.AntivirusSignatureAge -ge $FailSigAgeDays) {
      Write-Warning "[failure] Defender signatures are too old`n$([math]::Max($s.AntivirusSignatureAge,$s.AntispywareSignatureAge)) days old"
      $ok = $false
    }
    elseif ($s.AntispywareSignatureAge -ge $WarnSigAgeDays -or $s.AntivirusSignatureAge -ge $WarnSigAgeDays) {
      Write-Warning "[warning] Defender signatures are rather old`nAV=$($s.AntivirusSignatureAge)d, AS=$($s.AntispywareSignatureAge)d"
      $ok = $false
    }
    if ($ok) {
      Write-Warning "[pass] Defender signatures fresh (AV=$($s.AntivirusSignatureVersion))"} else {
    }
}

function HealthTest-FirewallEnabled__S {
<#
.SYNOPSIS
Checks Firewall Enabled

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time), High(Time)
Uses: Write-BasedOnTestResult, Get-NetFirewallProfile.
FalsePositives: None.
#>

    Write-BasedOnTestResult "Is mpssvc (the firewall service) enabled?" -Test ((Get-Service -name mpssvc).status -eq 'Running')
    Get-NetFirewallProfile | ForEach-Object {
        Write-BasedOnTestResult "Is firewall enabled for the $($_.Name) profile?" -Test ($_.Enabled -eq 1) -comment "To enable firewall for *ALL* profiles run this:`nSet-NetFirewallProfile -Profile Domain,Private,Public -Enabled True"
    }
}


function HealthTest-Smb1Disabled{
<#
.SYNOPSIS
Checks Smb 1 Disabled

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-WindowsOptionalFeature.
FalsePositives: None.
#>
  $f=Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -ErrorAction SilentlyContinue
  $state=$f.State
  $disabled=($state -eq 'Disabled' -or -not $f -or $state -eq 'DisabledWithPayloadRemoved')
  if($disabled){ Write-Warning "[pass] SMBv1 is disabled"} else { Write-Warning "[warning] SMBv1 is enabled`nState=$state" }
}

function HealthTest-WmiRepository__E{
<#
.SYNOPSIS
Checks Wmi Repository

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: None.
FalsePositives: None.
#>
  $out=& winmgmt /verifyrepository 2>&1
  $ok=($out -match 'consistent')
  if($ok){ Write-Warning "[pass] WMI repository consistent"} else { Write-Warning ("[failure] WMI repository inconsistent`n" + ($out -join ' ')) }
}


function HealthTest-VssWriters__S{
<#
.SYNOPSIS
Checks Vss Writers

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time), High(Time)
Uses: Select-String.
FalsePositives: None.
#>

  $out=& vssadmin list writers 2>&1
  $bad=($out | Select-String -Pattern 'State: \d+ \((?i:Retryable error|Waiting for completion|Failed)\)')
  if($bad){
    foreach($b in $bad){ Write-Warning "[failure] VSS writer not healthy`n$($b.Line)" }
  } else {
    Write-Warning "[pass] All VSS writers report stable states"}
}


function HealthTest-UnsignedDrivers {
<#
.SYNOPSIS
Reports unsigned drivers if any; ignores Bluetooth Enumeration devices (DeviceID like "BTHENUM\*")

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-CimInstance Win32_PnPSignedDriver, SetupVerifyInfFile, Get-PnpDeviceProperty.
FalsePositives: Low.
#>
  [CmdletBinding()]
  param([string[]]$WhitelistDeviceIdRegex = @('^BTHENUM\\'))

  function New-WarningMessage {
    param(
      [string]$Synopsis,
      [string]$Details
    )
    if ([string]::IsNullOrWhiteSpace($Details)) { return $Synopsis }
    return ($Synopsis + "`n" + $Details)
  }

  function Ensure-SetupApiInterop {
    if ('Toula.HealthTestUnsignedDrivers.SetupApiNative' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace Toula.HealthTestUnsignedDrivers
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SP_INF_SIGNER_INFO_V1
    {
        public UInt32 cbSize;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string CatalogFile;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string DigitalSigner;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string DigitalSignerVersion;
    }

    public static class SetupApiNative
    {
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "SetupVerifyInfFileW")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetupVerifyInfFile(
            string InfName,
            IntPtr AltPlatformInfo,
            ref SP_INF_SIGNER_INFO_V1 InfSignerInfo
        );
    }
}
"@ -ErrorAction Stop
  }

  function Convert-ToBooleanSafe {
    param([object]$Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    try { return [System.Convert]::ToBoolean($Value) } catch {}
    return ([string]$Value -match '^(?i:true|1|yes)$')
  }

  function Get-PnpPropertyDataValue {
    param(
      [object[]]$Properties,
      [string]$KeyName
    )
    try {
      ($Properties | Where-Object { $_.KeyName -eq $KeyName } | Select-Object -First 1).Data
    } catch {
      $null
    }
  }

  function Resolve-InfPath {
    param([string]$InfNameOrPath)

    if ([string]::IsNullOrWhiteSpace($InfNameOrPath)) { return $null }

    $candidate = [Environment]::ExpandEnvironmentVariables($InfNameOrPath.Trim().Trim('"'))

    if ([System.IO.Path]::IsPathRooted($candidate)) {
      if (Test-Path -LiteralPath $candidate) {
        return (Resolve-Path -LiteralPath $candidate -ErrorAction SilentlyContinue | Select-Object -First 1).Path
      }
      return $null
    }

    $underInf = Join-Path (Join-Path $env:SystemRoot 'INF') $candidate
    if (Test-Path -LiteralPath $underInf) {
      return (Resolve-Path -LiteralPath $underInf -ErrorAction SilentlyContinue | Select-Object -First 1).Path
    }

    $null
  }

  function Get-PnpPropertiesCached {
    param([string]$InstanceId)

    if (-not $canUsePnpProperties) { return $null }
    if ([string]::IsNullOrWhiteSpace($InstanceId)) { return $null }

    if (-not $pnpPropertyCache.ContainsKey($InstanceId)) {
      try {
        $pnpPropertyCache[$InstanceId] = @(Get-PnpDeviceProperty -InstanceId $InstanceId -ErrorAction Stop)
      } catch {
        $pnpPropertyCache[$InstanceId] = $null
      }
    }

    $pnpPropertyCache[$InstanceId]
  }

  function Get-DriverInfCandidates {
    param([object]$Driver)

    $candidates = New-Object System.Collections.ArrayList
    $seen = @{}

    function Add-Candidate {
      param(
        [string]$Path,
        [string]$Source
      )

      if ([string]::IsNullOrWhiteSpace($Path)) { return }
      if ($seen.ContainsKey($Path)) { return }

      $seen[$Path] = $true
      [void]$candidates.Add([pscustomobject]@{
        Path   = $Path
        Source = $Source
      })
    }

    if ($Driver.PSObject.Properties.Name -contains 'InfName') {
      $resolved = Resolve-InfPath ([string]$Driver.InfName)
      if ($resolved) {
        Add-Candidate -Path $resolved -Source 'Win32_PnPSignedDriver.InfName'
      }
    }

    $deviceId = ''
    if ($Driver.PSObject.Properties.Name -contains 'DeviceID' -and $Driver.DeviceID) {
      $deviceId = [string]$Driver.DeviceID
    }

    if ($deviceId) {
      $props = Get-PnpPropertiesCached $deviceId
      if ($props) {
        $currentInf = Resolve-InfPath ([string](Get-PnpPropertyDataValue -Properties $props -KeyName 'DEVPKEY_Device_DriverInfPath'))
        if ($currentInf) {
          Add-Candidate -Path $currentInf -Source 'DEVPKEY_Device_DriverInfPath'
        }

        if ($candidates.Count -eq 0) {
          $parentId = [string](Get-PnpPropertyDataValue -Properties $props -KeyName 'DEVPKEY_Device_Parent')
          if ($parentId) {
            $parentProps = Get-PnpPropertiesCached $parentId
            if ($parentProps) {
              $parentInf = Resolve-InfPath ([string](Get-PnpPropertyDataValue -Properties $parentProps -KeyName 'DEVPKEY_Device_DriverInfPath'))
              if ($parentInf) {
                Add-Candidate -Path $parentInf -Source 'Parent.DEVPKEY_Device_DriverInfPath'
              }
            }
          }
        }
      }
    }

    $candidates
  }

  function Invoke-SetupVerifyInfFileCached {
    param([string]$InfPath)

    if ([string]::IsNullOrWhiteSpace($InfPath)) {
      return [pscustomobject]@{
        State                = 'NoInf'
        IsPackageSigned      = $false
        IsTrusted            = $false
        ErrorCodeSigned      = 0
        ErrorCodeUnsigned    = [uint32]0
        ErrorHex             = '0x00000000'
        ErrorText            = 'No INF path'
        CatalogFile          = ''
        DigitalSigner        = ''
        DigitalSignerVersion = ''
        InfPath              = $null
      }
    }

    if ($verifyCache.ContainsKey($InfPath)) {
      return $verifyCache[$InfPath]
    }

    $info = New-Object 'Toula.HealthTestUnsignedDrivers.SP_INF_SIGNER_INFO_V1'
    $info.cbSize = [uint32][Runtime.InteropServices.Marshal]::SizeOf([type]'Toula.HealthTestUnsignedDrivers.SP_INF_SIGNER_INFO_V1')

    $ok = [Toula.HealthTestUnsignedDrivers.SetupApiNative]::SetupVerifyInfFile($InfPath, [IntPtr]::Zero, [ref]$info)

    $errSigned = if ($ok) {
      0
    } else {
      [int][Runtime.InteropServices.Marshal]::GetLastWin32Error()
    }

    $errUnsigned64 = ([int64]$errSigned) -band 0xffffffffL
    $errUnsigned = [uint32]$errUnsigned64
    $errHex = '0x{0:X8}' -f $errUnsigned

    $state = 'NotSignedOrVerificationFailed'
    $isPackageSigned = $false
    $isTrusted = $false

    switch ($errHex) {
      '0x00000000' {
        if ($ok) {
          $state = 'Signed'
          $isPackageSigned = $true
          $isTrusted = $true
        }
      }
      '0x800F0241' {
        $state = 'AuthenticodeTrustedPublisher'
        $isPackageSigned = $true
        $isTrusted = $true
      }
      '0x800F0242' {
        $state = 'AuthenticodeTrustNotEstablished'
        $isPackageSigned = $true
        $isTrusted = $true
      }
      '0x800F0243' {
        $state = 'AuthenticodePublisherNotTrusted'
        $isPackageSigned = $true
        $isTrusted = $false
      }
    }

    $errorText = ''
    if ($errSigned -eq 0) {
      $errorText = 'Success'
    } else {
      try {
        $errorText = (New-Object System.ComponentModel.Win32Exception($errSigned)).Message
      } catch {
        $errorText = ''
      }
    }

    $result = [pscustomobject]@{
      State                = $state
      IsPackageSigned      = $isPackageSigned
      IsTrusted            = $isTrusted
      ErrorCodeSigned      = $errSigned
      ErrorCodeUnsigned    = $errUnsigned
      ErrorHex             = $errHex
      ErrorText            = $errorText
      CatalogFile          = [string]$info.CatalogFile
      DigitalSigner        = [string]$info.DigitalSigner
      DigitalSignerVersion = [string]$info.DigitalSignerVersion
      InfPath              = $InfPath
    }

    $verifyCache[$InfPath] = $result
    $result
  }

  function Get-DriverDisplayName {
    param([object]$Driver)
    if ($Driver.DeviceName) { return [string]$Driver.DeviceName }
    if ($Driver.Description) { return [string]$Driver.Description }
    if ($Driver.Name) { return [string]$Driver.Name }
    '<unknown device>'
  }

  function Get-DriverCompactDetails {
    param(
      [object]$Driver,
      [object]$Verification,
      [object]$Candidate
    )

    $parts = New-Object System.Collections.ArrayList

    foreach ($n in 'DeviceID','Manufacturer','DriverProviderName','DriverVersion','InfName','Signer','Location','ClassGuid') {
      $v = $Driver.$n
      if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) {
        [void]$parts.Add(('{0}={1}' -f $n, [string]$v))
      }
    }

    if ($Candidate -and $Candidate.Path) {
      [void]$parts.Add(('VerifiedInf={0}' -f $Candidate.Path))
    }

    if ($Verification) {
      if ($Verification.CatalogFile) {
        [void]$parts.Add(('CatalogFile={0}' -f $Verification.CatalogFile))
      }
      if ($Verification.DigitalSigner) {
        [void]$parts.Add(('DigitalSigner={0}' -f $Verification.DigitalSigner))
      }
      if ($Verification.ErrorHex) {
        [void]$parts.Add(('SetupApi={0}' -f $Verification.ErrorHex))
      }
      if ($Verification.ErrorText) {
        [void]$parts.Add(('SetupApiText={0}' -f $Verification.ErrorText))
      }
    }

    $parts -join '; '
  }

  try {
    Ensure-SetupApiInterop
  } catch {
    Write-Warning ("[warning] Could not initialize SetupAPI interop for driver-package signature verification: {0}" -f $_.Exception.Message)
    return
  }

  $canUsePnpProperties = $null -ne (Get-Command Get-PnpDeviceProperty -ErrorAction SilentlyContinue)
  $pnpPropertyCache = @{}
  $verifyCache = @{}

  $drivers = @()
  try {
    $drivers = @(
      Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_.DeviceName) }
    )
  } catch {
    Write-Warning ("[warning] Could not enumerate PnP signed drivers: {0}" -f $_.Exception.Message)
    return
  }

  $bad = $false
  $warn = $false

  foreach ($d in $drivers) {
    $deviceName = Get-DriverDisplayName $d
    $deviceId = if ($d.DeviceID) { [string]$d.DeviceID } else { '' }

    $isWhitelisted = $false
    foreach ($rx in $WhitelistDeviceIdRegex) {
      if ($deviceId -match $rx) {
        $isWhitelisted = $true
        break
      }
    }
    if ($isWhitelisted) {
      Write-Verbose ("Unsigned-looking device instance excluded by whitelist: {0} ({1})" -f $deviceName, $deviceId)
      continue
    }

    $isSigned = $false
    if ($d.PSObject.Properties.Name -contains 'IsSigned') {
      $isSigned = Convert-ToBooleanSafe $d.IsSigned
    }
    if ($isSigned) { continue }

    $candidates = @(Get-DriverInfCandidates $d)

    if ($candidates.Count -eq 0) {
      $warn = $true
      $ver = if ($d.DriverVersion) { [string]$d.DriverVersion } else { '' }
      $prov = if ($d.DriverProviderName) { [string]$d.DriverProviderName } elseif ($d.Manufacturer) { [string]$d.Manufacturer } else { '' }
      $detail = Get-DriverCompactDetails -Driver $d -Verification $null -Candidate $null
      $synopsis = "[warning] Could not locate driver package INF to verify signature: {0}{1} ver [{2}]" -f $(if ($prov) { "$($prov), " } else { '' }), $deviceName, $ver
      Write-Warning (New-WarningMessage -Synopsis $synopsis -Details $detail)
      continue
    }

    $accepted = $false
    $bestVerification = $null
    $bestCandidate = $null

    foreach ($candidate in $candidates) {
      $vr = Invoke-SetupVerifyInfFileCached $candidate.Path

      if ($null -eq $bestVerification) {
        $bestVerification = $vr
        $bestCandidate = $candidate
      }

      switch ($vr.State) {
        'Signed' {
          Write-Verbose ("Win32 reports unsigned but SetupAPI verified the driver package as signed: {0} (INF={1}, Source={2}, Signer={3})" -f $deviceName, (Split-Path $candidate.Path -Leaf), $candidate.Source, $vr.DigitalSigner)
          $accepted = $true
          break
        }
        'AuthenticodeTrustedPublisher' {
          Write-Verbose ("Driver package has a valid Authenticode signature from a trusted publisher: {0} (INF={1}, Source={2}, Signer={3}, SetupAPI={4})" -f $deviceName, (Split-Path $candidate.Path -Leaf), $candidate.Source, $vr.DigitalSigner, $vr.ErrorHex)
          $accepted = $true
          break
        }
        'AuthenticodeTrustNotEstablished' {
          Write-Verbose ("Driver package has a valid Authenticode signature, but publisher trust is not automatically established on this machine: {0} (INF={1}, Source={2}, Signer={3}, SetupAPI={4})" -f $deviceName, (Split-Path $candidate.Path -Leaf), $candidate.Source, $vr.DigitalSigner, $vr.ErrorHex)
          $accepted = $true
          break
        }
        'AuthenticodePublisherNotTrusted' {
          $warn = $true
          $detail = Get-DriverCompactDetails -Driver $d -Verification $vr -Candidate $candidate
          $synopsis = "[warning] Driver package is signed, but the catalog publisher is not trusted: {0} (INF={1}, Source={2}, SetupAPI={3})" -f $deviceName, (Split-Path $candidate.Path -Leaf), $candidate.Source, $vr.ErrorHex
          Write-Warning (New-WarningMessage -Synopsis $synopsis -Details $detail)
          $accepted = $true
          break
        }
      }
    }

    if ($accepted) { continue }

    $bad = $true
    $ver = if ($d.DriverVersion) { [string]$d.DriverVersion } else { '' }
    $prov = if ($d.DriverProviderName) { [string]$d.DriverProviderName } elseif ($d.Manufacturer) { [string]$d.Manufacturer } else { '' }
    $detail = Get-DriverCompactDetails -Driver $d -Verification $bestVerification -Candidate $bestCandidate
    $synopsis = "[failure] Unsigned or unverified driver package detected: {0}{1} ver [{2}]" -f $(if ($prov) { "$($prov), " } else { '' }), $deviceName, $ver
    Write-Warning (New-WarningMessage -Synopsis $synopsis -Details $detail)
  }

  if (-not $bad -and -not $warn) {
    Write-Warning "[pass] All examined PnP driver packages appear signed (whitelisted instances excluded)."
  }
}


function HealthTest-CrashDumpSignals__E {
<#
.SYNOPSIS
Checks Crash Dump Signals

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: None.
FalsePositives: None.
#>
    param([int]$Hours = 48)

    $pass = $true
    if ($Hours -lt 1) { $Hours = 1 }
    $cutoff = (Get-Date).AddHours(-$Hours)

    Get-ChildItem "$env:SystemRoot\Minidump" -Filter *.dmp -ErrorAction SilentlyContinue | ?{ $_.LastWriteTime -gt $cutoff } | %{
        Write-Warning "[failure] Found $env:SystemRoot\Minidump\ file(s) within the last N hours`nN=$Hours hours. File: $env:SystemRoot\Minidump\$($_.name))"
        $pass = $false
    }

    if ($pass) {
        Write-Warning "[pass] No recent minidumps"
    }
}

function HealthTest-SeriousRecentEventLogs__S {
<#
.SYNOPSIS
Checks Serious Recent Event Logs

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network), High(Time)
Uses: Get-WinEvent.
FalsePositives: None.
#>
    [CmdletBinding()]
    param([int]$Hours = 24)


    if ($Hours -lt 1) { $Hours = 1 }
    $cutoff = (Get-Date).AddHours(-$Hours)
    $totalFindings = 0

    function Get-FirstLine([string]$Text) {
        if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
        return (($Text -split "`r?`n")[0]).Trim()
    }

    function Write-EventFinding([string]$Severity, [string]$Synopsis, $EventRecord) {
        $msg = Get-FirstLine -Text $EventRecord.Message
        Write-Warning "[$Severity] $Synopsis`n$($EventRecord.TimeCreated) | $($EventRecord.ProviderName) | Event ID $($EventRecord.Id)`n$msg"
    }

    function Get-FaultingApplicationName($EventRecord) {
        if ($null -eq $EventRecord -or [string]::IsNullOrWhiteSpace($EventRecord.Message)) { return "" }

        $match = [regex]::Match($EventRecord.Message, '(?im)^\s*Faulting application name:\s*([^,\r\n]+)')
        if ($match.Success) {
            return $match.Groups[1].Value.Trim()
        }

        return ""
    }

    # [failure] Blue screen / bugcheck / unexpected shutdown
    $failureFilters = @(
        @{ LogName = 'System'; Id = 41;   ProviderName = 'Microsoft-Windows-Kernel-Power';          StartTime = $cutoff },
        @{ LogName = 'System'; Id = 6008; ProviderName = 'EventLog';                                 StartTime = $cutoff },
        @{ LogName = 'System'; Id = 1001; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; StartTime = $cutoff }
    )
    foreach ($filter in $failureFilters) {
        Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue | ForEach-Object {
            $totalFindings++
            $synopsis = if ($_.Id -eq 1001) { 'Detected blue screen / bugcheck event in System log' } else { 'Detected unexpected system shutdown event in System log' }
            Write-EventFinding -Severity 'failure' -Synopsis $synopsis -EventRecord $_
        }
    }

    # [warning] Disk errors
    $diskProviders = @('disk', 'Ntfs', 'stornvme', 'storahci', 'iaStorA', 'iaStorAVC', 'iaStorV')
    $diskEventIds = @(7, 51, 52, 55, 98, 129, 153, 157)
    Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $cutoff; Level = 2 } -ErrorAction SilentlyContinue |
        Where-Object { ($diskProviders -contains $_.ProviderName) -or ($diskEventIds -contains $_.Id) } |
        ForEach-Object {
            $totalFindings++
            Write-EventFinding -Severity 'warning' -Synopsis 'Detected serious disk error in System log' -EventRecord $_
        }

    # [notice] Application crashes
    Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000; ProviderName = 'Application Error'; StartTime = $cutoff } -ErrorAction SilentlyContinue |
        ForEach-Object {
            $totalFindings++
            $appName = Get-FaultingApplicationName -EventRecord $_
            $synopsis = if ($appName) { "Detected application crash in Application log: $appName" } else { 'Detected application crash in Application log' }
            Write-EventFinding -Severity 'notice' -Synopsis $synopsis -EventRecord $_
        }

    if ($totalFindings -eq 0) {
        Write-Warning "[pass] No serious shutdown, bugcheck, disk error, or application crash events found in the last $Hours hour(s)"
    }
}


function HealthTest-HotfixBaseline__E{
<#
.SYNOPSIS
Checks Hotfix Baseline

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Audit / Compliance / Informational
Impact: Medium(Network)
Uses: Get-HotFix.
FalsePositives: None.
#>
  [CmdletBinding()] param([string[]]$RequiredKBs)
  if(-not $RequiredKBs -or $RequiredKBs.Count -eq 0){ Write-Warning "[pass] No hotfix baseline provided"; return }
  $have=(Get-HotFix | Select-Object -ExpandProperty HotFixID)
  $miss=@()
  foreach($kb in $RequiredKBs){
    if($have -notcontains $kb){ $miss += $kb; Write-Warning "[failure] Missing required hotfix: $kb"}
  }
  if($miss.Count -eq 0){ Write-Warning "[pass] All required hotfixes are installed"}
}

function HealthTest-BitLockerStatus__E {
<#
.SYNOPSIS
Checks Bit Locker Status

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-BitLockerVolume.
FalsePositives: None.
#>
    if ($Global:GCHDQMTA.isHostVM) {
        Write-Warning "[info] Computer is a VM; skipping HealthTest-BitLockerStatus"
		return
	}
    if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        Write-Warning "[warning] BitLocker PowerShell cmdlets not available; skipping BitLocker status check"
		return
    }

    $pass = $true

    $vols = Get-BitLockerVolume -ErrorAction SilentlyContinue
    if (-not $vols) {
        Write-Warning "[warning] No BitLocker-capable volumes found"}
    $vols | Where-Object { $_.ProtectionStatus -ne 'On' } | %{
        Write-Warning "[warning] Volume not protected by BitLocker: $($_.MountPoint)"
        $pass = $false
    }
    if ($pass) {
        Write-Warning "[pass] BitLocker protection is ON for all detected volumes"}
}


function HealthTest-NtlmHardening__E {
<#
.SYNOPSIS
Checks Ntlm Hardening

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-ItemProperty.
FalsePositives: None.
#>
  $lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'

  $bag   = Get-ItemProperty -Path $lsa -ErrorAction SilentlyContinue
  $lmVal = if ($bag -and $bag.PSObject.Properties['LmCompatibilityLevel']) { $bag.PSObject.Properties['LmCompatibilityLevel'].Value } else { $null }
  $noLM  = if ($bag -and $bag.PSObject.Properties['NoLMHash'])           { $bag.PSObject.Properties['NoLMHash'].Value }           else { $null }

  $interpreted = $true
  if ($null -ne $lmVal) { $level = [int]$lmVal; $interpreted = $false } else { $level = 3 }
  $suffix  = if ($interpreted) { ' (default)' } else { '' }
  $details = "LmCompatibilityLevel=$level$suffix; NoLMHash=$noLM"

  if ($noLM -ne 1) {
    Write-Warning ("[warning] NTLM is not fully hardened (NoLMHash is not 1)`n$details")
  } elseif ($level -lt 5) {
    Write-Warning ("[warning] NTLM is not fully hardened (LmCompatibilityLevel<5)`n$details")
  } else {
    Write-Warning "[pass] NTLM is fully hardened`n$details"
  }
}


function HealthTest-RdpHardening__E {
<#
.SYNOPSIS
Checks Rdp Hardening

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-ItemProperty.
FalsePositives: None.
#>
  $k = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'

  $bag  = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
  $nla  = if ($bag -and $bag.PSObject.Properties['UserAuthentication'])     { $bag.PSObject.Properties['UserAuthentication'].Value }     else { $null }
  $cert = if ($bag -and $bag.PSObject.Properties['SSLCertificateSHA1Hash']) { $bag.PSObject.Properties['SSLCertificateSHA1Hash'].Value } else { $null }

  $certBound = ($null -ne $cert) -and ($cert.Trim() -ne '')

  $isServer = $false
  try { $isServer = ((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).DomainRole -ge 2) } catch {}

  if ($nla -eq 1 -and $certBound) {
    Write-Warning "[pass] RDP hardened: NLA enabled and a certificate is bound"
  } else {
    $sev = "Severity: Medium. Risk: Users may click through name-mismatch warnings; increases MITM risk on first-connect or via spoofing." + $(if($isServer){ " On a DC this is sensitive." } else { "" })
    $rdpState = "NLA=$nla; CertBound=$(if($certBound){$true}else{$false})"
    if ($isServer) {
      Write-Warning "[warning] RDP is not hardened (NLA and/or TLS certificate binding missing)`n$rdpState`n$sev"
    } else {
      Write-Warning "[notice] RDP is not hardened (NLA and/or TLS certificate binding missing)`n$rdpState`n$sev"
    }
  }
}

function HealthTest-NonDefaultShares__E {
<#
.SYNOPSIS
Checks Non Default Shares

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Set-Service, Stop-Service.
FalsePositives: None.
#>
  # 0(Workstation standalone),  1(Workstation domain joined), 2(Server standalone), 3(Server joined), 4(DC non-FSMO), 5(DC with FSMO role)
  $domainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole
  $isHostDC = ($domainRole -in 4,5)

    $lanManServer_service = (get-service -Name "LanmanServer")
    $shares_beside_the_system_ones = Get-CimInstance -ClassName Win32_Share | Select-Object Name, Path | ?{$_.name -notlike '*$' -and $_.path -notlike 'C:\Windows\SYSVOL\sysvol*'}
    if ($shares_beside_the_system_ones) {
        $shares_beside_the_system_ones | %{Write-Warning "[warning] Found a share named '$($_.name)' that shares '$($_.Path)'"}
    } else {
        if ((Get-Service  -Name "LanmanServer").status -eq 'Stopped') {
            Write-Warning "[pass] No shares except the defaults and LanMan service is stopped."} else {
            Write-Warning "[pass] Found no shares except the default ones (like C$, ADMIN$)."; if (!$isHostDC -and ($lanManServer_service.status -ne 'stopped' -or $lanManServer_service.StartType -ne 'Disabled')) {
                if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 2) { # server
                    Write-Warning "[warning] File & print sharing is enabled. It's recomended to disable it unless you really need it`nRun this if you want to disable:`n   Set-Service -Name 'LanmanServer' -StartupType Disabled; Stop-Service -Name 'LanmanServer'"
                } else { # workstation
                    Write-Output ("File & print sharing is enabled on a workstation." + "`n" + "You may consider disabling it to reduce the attack surface")
                }
            }
        }
    }
}


function HealthTest-LocalAcntRequirePass__E {
<#
.SYNOPSIS
Checks Local Acnt Require Pass

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-CimInstance.
FalsePositives: None.
#>
    $ok = $true
    $no_req_pass_accounts=Get-CimInstance -Class Win32_UserAccount -Filter `
        "LocalAccount=True AND Disabled=False AND PasswordRequired=False"
    if ($no_req_pass_accounts) {
        $no_req_pass_accounts | %{
            try {$account_name = $_.name} catch {$account_name="(FAILED_TO_GET_NAME)"}
            $ok = $false
            $comment =  "Make sure the account password is set and then run this command:`n& cmd /c 'net user `"$($_.name)`" /passwordreq:yes'"
            Write-Warning "[failure] This local account has the property PasswordRequired set to false: $account_name`n$comment"
        }
    }
    if ($ok) {Write-Warning "[pass] All local accounts have PasswordRequired True"}
}


function HealthTest-RestrictAnonymous__E {
<#
.SYNOPSIS
Checks Restrict Anonymous

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-ItemProperty.
FalsePositives: None.
#>
  $p  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
  $ra = (Get-ItemProperty $p -Name restrictanonymous      -ErrorAction SilentlyContinue).restrictanonymous
  $rs = (Get-ItemProperty $p -Name restrictanonymoussam   -ErrorAction SilentlyContinue).restrictanonymoussam
  $ea = (Get-ItemProperty $p -Name EveryoneIncludesAnonymous -ErrorAction SilentlyContinue).EveryoneIncludesAnonymous

  $pass = ($rs -eq 1 -and $ea -eq 0)
  $details="RestrictAnonymous=$ra; RestrictAnonymousSAM=$rs; EveryoneIncludesAnonymous=$ea"

  if($pass){
    Write-Warning "[pass] Anonymous access hardening (baseline met)`n$details"
  } else {
    Write-Warning "[failure] Anonymous access hardening not at baseline`n$details. Recommendation: Set RestrictAnonymousSAM=1 and EveryoneIncludesAnonymous=0 via GPO."
  }
}

function HealthTest-DefaultLocale__E {
<#
.SYNOPSIS
Checks Default Locale

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Audit / Compliance / Informational
Impact: Medium(Time)
Uses: Get-ItemProperty.
FalsePositives: None.
#>
    # see https://newbedev.com/how-can-i-manually-determine-the-codepage-and-locale-of-the-current-os
    $loc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' | Select-Object ACP,OEMCP
    $loc_acp = $loc.ACP; $loc_oemcp = $loc.OEMCP
    if($loc_acp -eq 1253 -and $loc_oemcp -eq 737){
      Write-Warning "[pass] Host supports legacy Greek (ACP/OEMCP 1253/737)."
    }elseif($loc_acp -eq 1252 -and $loc_oemcp -eq 437){
      Write-Warning "[notice] This host uses default English/ANSI (1252/437), so legacy Greek apps may fail."
    }else{
      Write-Warning "[warning] Unusual non-Unicode locale: $loc_acp / $loc_oemcp (ACP/OEMCP). Greek is 1253/737; Default english is 1252/437."
    }
}

function HealthTest-PendingReboot__E {
<#
.SYNOPSIS
Checks Pending Reboot

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Write-Debug.
FalsePositives: None.
#>
    $pending = $false
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending = $true }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending = $true }
    $pfr = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
    if ($pfr -and $pfr.PendingFileRenameOperations) {write-debug "Found entries in HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations (if you are not sure what this means, you can safely ignore it)"}
    if ($pending) { Write-Warning "[notice] Windows need a reboot to apply some changes"; return}
    Write-Warning "[pass] No pending reboot indicators"
}

function HealthTest-SmbSigningRequired__E{
<#
.SYNOPSIS
Checks Smb Signing Required

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-SmbServerConfiguration.
FalsePositives: None.
#>
  if ((Get-PropValue -obj (Get-Service -Name LanmanServer) -name Status) -ne 'running') {
      Write-Warning "[pass] Skipping HealthTest-SmbSigningRequired; LanmanServer service not running."
      return
  }

  $c=Get-SmbServerConfiguration
  if($c.RequireSecuritySignature){
    Write-Warning "[pass] SMB signing required on the server"
  } else {
    Write-Warning "[warning] SMB signing is not required`nRequireSecuritySignature=$($c.RequireSecuritySignature); EnableSecuritySignature=$($c.EnableSecuritySignature)"
  }
}

function HealthTest-ShadowStorage__E {
<#
.SYNOPSIS
Checks if Shadow Storage is enabled on internal drives (for servers) or on C: (for workstations)

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Low
Uses: Get-CimInstance.
FalsePositives: None.
#>
  [CmdletBinding()]
  param(
    [string[]]$RequireOnVolumes = @(),
    [Nullable[double]]$MinRecommendedGB = $null,
    [Nullable[double]]$MaxRecommendedGB = $null
  )

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

      if ($null -ne $MinRecommendedGB -and $sizeGB -lt $MinRecommendedGB.Value) {
        $outOfRange = $true
        $rangeOutOfBounds.Add("$k=$sizeGB GB below min $($MinRecommendedGB.Value) GB")
      }

      if ($null -ne $MaxRecommendedGB -and $sizeGB -gt $MaxRecommendedGB.Value) {
        $outOfRange = $true
        $rangeOutOfBounds.Add("$k=$sizeGB GB above max $($MaxRecommendedGB.Value) GB")
      }
    }
  }

  if ($RequireOnVolumes.Count -gt 0) {
    $missing = @()

    foreach ($v in $RequireOnVolumes) {
      $k = $v.TrimEnd('\')
      if (-not $present.ContainsKey($k)) {
        $missing += $k
        Write-Warning "[notice] Shadow storage not configured on $k"
      }
    }

    if ($missing.Count -eq 0) {
      Write-Warning ("[pass] Shadow storage on required volumes`nConfigured on: " + ((@($present.Keys) | Sort-Object) -join ', '))
    }
  } else {
    if ($present.Count -gt 0) {
      Write-Warning ("[pass] Shadow storage configured`nOn: " + ((@($present.Keys) | Sort-Object) -join ', '))
    } else {
      Write-Warning "[notice] Shadow storage (Volume Shadow Copies) is not enabled`nUsers won't see Previous Version for files/folders. (Note that this issue is UNRELATED to the VSS service that backup software use.)"
    }
  }

  if ($outOfRange -and $rangeOutOfBounds.Count -gt 0) {
    Write-Warning ("[notice] Shadow storage size outside recommended range`n" + ($rangeOutOfBounds -join '; '))
  }

  if ($rangeUnknown.Count -gt 0) {
    Write-Warning ("[info] Shadow storage size could not be determined`n" + ($rangeUnknown -join '; '))
  }
}


function HealthTest-DnsClientService__E{
<#
.SYNOPSIS
Checks Dns Client Service

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Low
Uses: Get-Service.
FalsePositives: None.
#>
  $s=Get-Service Dnscache -ErrorAction Stop
  if($s.Status -eq 'Running'){ Write-Warning "[pass] DNS Client service running" } else { Write-Warning "[failure] DNS Client service is not running`nStatus=$($s.Status)" }
}


function HealthTest-LocalAdminsBaseline {
<#
.SYNOPSIS
Checks Local Admins Baseline

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Audit / Compliance / Informational
Impact: Medium(Time)
Uses: None.
FalsePositives: None.
#>
    param(
        [string[]]$Allowed = @(
            'BUILTIN\Administrators',
            'NT AUTHORITY\SYSTEM',
            'Domain Admins',
            'Enterprise Admins'
        )
    )

    $pass = $true

    $grp = [ADSI]"WinNT://$env:COMPUTERNAME/Administrators,group"
    $members = @(@($grp.psbase.Invoke('Members')) | ForEach-Object { [ADSI]$_ })
    $unexpected = @()

    foreach ($m in $members) {
        $name = $m.InvokeGet('Name')
        $path = [string]$m.Path

        $dom  = ''
        $acct = $name

        if ($path -match '^WinNT://([^/]+)/([^/,]+)(?:,.*)?$') {
            $dom  = $Matches[1]
            $acct = $Matches[2]
        }

        $full = if ($dom) { "$dom\$acct" } else { $acct }

        $isAllowed = $false
        # 1) Built-in Administrator: SID ends with -500
        try {
            $sidBytes = $m.InvokeGet('ObjectSid')
            if ($sidBytes) {
                $sid = New-Object System.Security.Principal.SecurityIdentifier($sidBytes, 0)
                if ($sid.Value -match '-500$') {
                    $isAllowed = $true
                }
            }
        } catch {
            # If SID lookup fails we just fall back to name-based checks
        }
        # 2) Name-based allow list (if not already allowed by SID)
        if (-not $isAllowed) {
            foreach ($a in $Allowed) {
                if ($full -ieq $a -or $full -like "*\$a") {
                    $isAllowed = $true
                    break
                }
            }
        }

        if (-not $isAllowed) {
            Write-Warning "[warning] Unexpected Local Administrator: $full"
            $pass = $false
        }
    }
    if ($pass) {
        Write-Warning "[pass] No unexpected accounts in Local Administrators"}
}

function HealthTest-UnexpectedListeningPorts__S {
<#
.SYNOPSIS
Checks Unexpected Listening Ports

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time), High(Time)
Uses: Get-NetTCPConnection.
FalsePositives: None.
#>
    [CmdletBinding()] param(
        [int[]]$AllowedPorts = @(53, 88, 123, 135, 139, 389, 445, 464, 636, 3268, 3269, 5722, 5985, 5986, 9389),
        [int[]]$OptionalNoticePorts = @(3389, 47001, 593),
        [int]$DynamicStart = 49152,
        [int]$DynamicEnd = 65535
    )

# From a brand new Lenovo:
#    FAILURE:[01d04124] Unexpected listening port: 7680 (Process: svchost)
#    FAILURE:[3d641d0f] Unexpected listening port: 5040 (Process: svchost)
#
#   From Intel ATM:
#       FAILURE:[5fbea54a] Unexpected listening port: 623 (Process: LMS)
#       FAILURE:[58582cc2] Unexpected listening port: 16992 (Process: LMS)

    $domainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole
    $isHostServer = ($domainRole  -in 3,4,5)

    # 1. Get all listening connections
    $AllListening = Get-NetTCPConnection -State Listen

    # 2. Filter out connections where the LocalAddress is *only* the localhost loopback (127.0.0.1 or ::1)
    $ExternalListening = $AllListening | Where-Object {
        $_.LocalAddress -ne '127.0.0.1' -and $_.LocalAddress -ne '::1'
    }

    # 3. Group the connections by port number. This ensures each port is checked only once.
    # This replaces the old method of selecting only the port number, so we retain the process ID.
    $listeningPortGroups = $ExternalListening | Group-Object -Property LocalPort

    $bad = $false
    # 4. Loop through each group of connections (one group per unique port).
    foreach ($portGroup in $listeningPortGroups) {
        $comment = ""
        $p = [int]$portGroup.Name # The port number is the 'Name' of the group

        if ($p -ge $DynamicStart -and $p -le $DynamicEnd) { continue } # ignore ephemeral
        if ($AllowedPorts -contains $p) { continue }

        # For optional and unexpected ports, we'll find the process name.
        # Get the Process ID from the first connection object in the group.
        $procID = $portGroup.Group[0].OwningProcess
        # Use the ID to get the process name. ErrorAction handles cases where the process might have just ended.
        $vendor="(failed to find)"
        if ($procID -eq 4) {
            $procDescr="Process=SYSTEM(PID=4)"
            $vendor="Microsoft Windows" # PID 4 is Microsoft Windows system process
        } else {
            $proc = (Get-Process -Id $procID -ErrorAction SilentlyContinue)
            if (-not $proc) {
                $procDescr = "PID $procID not found"
                $comment = "The process that was listening terminated before we had the chance to query it. That's unusual."
            } else {
                if ($proc.path) {$procPath=Resolve-ExecutablePath $proc.path} else {$procPath=Resolve-ExecutablePath $proc.ProcessName}
                try {$vendor=Get-ExeVendor $procPath} catch {}
                $procDescr="$($proc.ProcessName)"
                $comment = "Vendor: '$vendor'; Process Path: '$procPath'"
            }
        }

        if ($OptionalNoticePorts -contains $p) {
            # Added process name to the notice message for extra context.
            Write-Warning "[notice] Optional baseline port is listening: $p ($procDescr)"
            continue
        }

        $bad = $true

        if ($vendor.PSObject.Properties.Name -contains 'Vendor') {
            $vendorDescr=$vendor.Vendor
        } else {
            $vendorDescr=$vendor
        }

        # Display the unexpected port along with the listening process name.
        # If vendor is like "Microsoft Windows*" then level becomes "WARNING" for servers and "NOTICE" for workstations
        if ($vendorDescr -like "Microsoft Windows*") {
            if($isHostServer){
                Write-Warning ("[warning] Unexpected listening port: $p (Process: $procDescr, Vendor: $vendor)`n$comment")
            } else {
                Write-Warning ("[notice] Unexpected listening port: $p (Process: $procDescr, Vendor: $vendor)`n$comment")
            }
        } else {
            Write-Warning ("[failure] Unexpected listening port: $p (Process: $procDescr, Vendor: $vendor)`n$comment")
        }
    }

    if (-not $bad) { Write-Warning "[pass] Listening ports are within baseline"}
}

function Get-InstalledSW {
    [CmdletBinding()]
    param ()

    $installedSoftware = [System.Collections.Generic.List[PSCustomObject]]::new()
    $registryTargets = @(
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry64; Scope = 'Machine'; Arch = '64-bit' },
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry32; Scope = 'Machine'; Arch = '32-bit' },
        @{ Hive = [Microsoft.Win32.RegistryHive]::CurrentUser;  View = [Microsoft.Win32.RegistryView]::Default;    Scope = 'User';    Arch = 'Native' }
    )
    $baseKeyPath = "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"

    foreach ($target in $registryTargets) {
        try {
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($target.Hive, $target.View)
            $uninstallKey = $baseKey.OpenSubKey($baseKeyPath)
            if ($uninstallKey) {
                foreach ($subKeyName in $uninstallKey.GetSubKeyNames()) {
                    $appKey = $uninstallKey.OpenSubKey($subKeyName)
                    if (-not $appKey) { continue }
                    $displayName = $appKey.GetValue("DisplayName") -as [string]
                    if ([string]::IsNullOrWhiteSpace($displayName)) { $appKey.Close(); continue }
                    $rawDate = $appKey.GetValue("InstallDate") -as [string]
                    $parsedDate = $null
                    if ($rawDate -match '^\d{8}$') {
                        try { $parsedDate = [datetime]::ParseExact($rawDate, 'yyyyMMdd', $null) } catch { }
                    }
                    $installedSoftware.Add([PSCustomObject]@{
                        Name            = $displayName.Trim()
                        Version         = $appKey.GetValue("DisplayVersion") -as [string]
                        Publisher       = $appKey.GetValue("Publisher") -as [string]
                        InstallDate     = $parsedDate
                        Source          = "Registry"
                        Scope           = $target.Scope
                        Architecture    = $target.Arch
                        RegistryKeyName = $subKeyName
                    })
                    $appKey.Close()
                }
                $uninstallKey.Close()
            }
            $baseKey.Close()
        } catch {
            Write-Verbose "Failed to read registry target $($target.Hive) ($($target.Arch)): $_"
        }
    }

    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        try {
            $appxPackages = Get-AppxPackage -ErrorAction Stop
            foreach ($app in $appxPackages) {
                $installedSoftware.Add([PSCustomObject]@{
                    Name            = $app.Name
                    Version         = $app.Version
                    Publisher       = $app.Publisher
                    InstallDate     = $null
                    Source          = "Appx"
                    Scope           = "User"
                    Architecture    = $app.Architecture.ToString()
                    RegistryKeyName = $null
                })
            }
        } catch {
            Write-Verbose "Failed to query Appx packages: $_"
        }
    }

    $installedSoftware
}

function Get-NormalizedSoftwareName {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$Name
    )
    process {
        $cleanName = $Name
        $cleanName = $cleanName -replace '(?i)\b(version|release|preview|edition)\b', ' '
        $cleanName = $cleanName -replace '(?i)\b(x64|x86|amd64|64-?bit|32-?bit)\b', ' '
        $cleanName = $cleanName -replace '\b(20\d{2}[-./]?\d{2}[-./]?\d{2}|\d{2}[-./]\d{2}[-./]20\d{2})\b', 'DATE'
        $cleanName = $cleanName -replace '\b(\d+)\.\d+(\.\d+)*\b', '$1.VER'
        $cleanName = $cleanName -replace '[\(\)\{\}\[\],]', ' '
        $cleanName = $cleanName -replace '\s-\s', ' '
        $cleanName = $cleanName -replace '\s+', ' '
        return $cleanName.Trim()
    }
}

function HealthTest-InstalledSW__P {
<#
.SYNOPSIS
Checks installed software baseline drift.

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-AppxPackage.
FalsePositives: New software can be expected in some environments.
#>
    $seen = 0
    foreach ($sw in (Get-InstalledSW)) {
        $seen += 1
        $normalizedName = Get-NormalizedSoftwareName -Name $sw.Name
        $details = "Full program name: $($sw.Name); Publisher: $($sw.Publisher); Install Date: $($sw.InstallDate); Source: $($sw.Source); Scope: $($sw.Scope)"
        Write-Warning "[notice] New installed software: $normalizedName`n$details"
    }

    if ($seen -eq 0) {
        Write-Warning "[pass] No installed software entries discovered."
    }
}
