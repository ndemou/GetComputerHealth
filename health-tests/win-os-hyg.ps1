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
Description: Checks whether Microsoft Defender has performed a recent quick scan.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-DaysSinceLastVirusScan, Get-WindowsOriginalInstallDate.
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
        Write-Warning ("[PASS] Did windows defender perform a quick scan recently?`n$comment")
    } elseif ($days -lt $MAX_FAILURE_DAYS) {
        Write-Warning ("[WARNING] Did windows defender perform a quick scan recently?`n$comment")
    } else {
        Write-Warning ("[FAILURE] Did windows defender perform a quick scan recently?`n$comment")
    }
}


function HealthTest-SchanelBaseline__E{
<#
Description: Checks whether Schannel disables legacy protocols and keeps TLS 1.2 enabled.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: None.
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
    Write-Warning "[PASS] Schannel baseline OK (SSL3/TLS1.0/TLS1.1 disabled, TLS1.2 enabled)"
  } else {
    $why="Inbound services that rely on Schannel may negotiate legacy TLS/SSL protocols if they remain enabled. E.g. LDAP over TLS, WinRM, ADWS..."
    $comment = ("Detected mismatches:`n"+($bad | ForEach-Object { "  - {0}: Current={1}, Recommended={2}" -f $_.Protocol,$_.CurrentState,$should[$_.Protocol] } | Out-String) + "`nRegistry snapshot:`n"+$det+$why)
    Write-Warning "[WARNING] Schannel baseline not hardened`n$comment"
  }
}

function HealthTest-DefenderStatus__E {
<#
Description: Checks Microsoft Defender signature freshness and protection status.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-MpComputerStatus.
#>
    param([int]$WarnSigAgeDays=2,[int]$FailSigAgeDays=7)
    $s = Get-MpComputerStatus
    $ok = $true
    if ($s.AntispywareSignatureAge -ge $FailSigAgeDays -or $s.AntivirusSignatureAge -ge $FailSigAgeDays) {
      Write-Warning "[FAILURE] Defender signatures are too old`n$([math]::Max($s.AntivirusSignatureAge,$s.AntispywareSignatureAge)) days old"
      $ok = $false
    }
    elseif ($s.AntispywareSignatureAge -ge $WarnSigAgeDays -or $s.AntivirusSignatureAge -ge $WarnSigAgeDays) {
      Write-Warning "[WARNING] Defender signatures are rather old`nAV=$($s.AntivirusSignatureAge)d, AS=$($s.AntispywareSignatureAge)d"
      $ok = $false
    }
    if ($ok) {
      Write-Warning "[PASS] Defender signatures fresh (AV=$($s.AntivirusSignatureVersion))"} else {
    }
}

function HealthTest-FirewallEnabled__S {
<#
Description: Checks whether Windows Firewall profiles are enabled and the firewall service is available.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: High(Time)
Uses: Get-Service, Get-NetFirewallProfile.
#>

    Write-BasedOnTestResult "Is mpssvc (the firewall service) enabled?" -Test ((Get-Service -name mpssvc).status -eq 'Running')
    Get-NetFirewallProfile | ForEach-Object {
        Write-BasedOnTestResult "Is firewall enabled for the $($_.Name) profile?" -Test ($_.Enabled -eq 1) -comment "To enable firewall for *ALL* profiles run this:`nSet-NetFirewallProfile -Profile Domain,Private,Public -Enabled True"
    }
}


function HealthTest-Smb1Disabled{
<#
Description: Checks whether SMBv1 is disabled.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-WindowsOptionalFeature.
#>
  if ($RunWithoutElevation) {
    Write-Warning "[WARNING] this test requires elevation"
    return
  }

  $f=Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -ErrorAction SilentlyContinue
  $state=$f.State
  $disabled=($state -eq 'Disabled' -or -not $f -or $state -eq 'DisabledWithPayloadRemoved')
  if($disabled){ Write-Warning "[PASS] SMBv1 is disabled"} else { Write-Warning "[WARNING] SMBv1 is enabled`nState=$state" }
}

function HealthTest-WmiRepository__E{
<#
Description: Checks whether the WMI repository is consistent.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: None.
#>
  $out=& winmgmt /verifyrepository 2>&1
  $ok=($out -match 'consistent')
  if($ok){ Write-Warning "[PASS] WMI repository consistent"} else { Write-Warning ("[FAILURE] WMI repository inconsistent`n" + ($out -join ' ')) }
}


function HealthTest-VssWriters__S{
<#
Description: Checks whether all VSS writers report healthy stable states.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: None.
#>

  $out=& vssadmin list writers 2>&1
  $bad=($out | Select-String -Pattern 'State: \d+ \((?i:Retryable error|Waiting for completion|Failed)\)')
  if($bad){
    foreach($b in $bad){ Write-Warning "[FAILURE] VSS writer not healthy`n$($b.Line)" }
  } else {
    Write-Warning "[PASS] All VSS writers report stable states"}
}


function HealthTest-UnsignedDrivers {
<#
Description: Checks for installed PnP driver packages that appear unsigned.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-PnpPropertyDataValue, Resolve-InfPath, Get-PnpPropertiesCached.
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
    Write-Warning ("[WARNING] Could not initialize SetupAPI interop for driver-package signature verification: {0}" -f $_.Exception.Message)
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
    Write-Warning ("[WARNING] Could not enumerate PnP signed drivers: {0}" -f $_.Exception.Message)
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
      $synopsis = "[WARNING] Could not locate driver package INF to verify signature: {0}{1} ver [{2}]" -f $(if ($prov) { "$($prov), " } else { '' }), $deviceName, $ver
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
          $synopsis = "[WARNING] Driver package is signed, but the catalog publisher is not trusted: {0} (INF={1}, Source={2}, SetupAPI={3})" -f $deviceName, (Split-Path $candidate.Path -Leaf), $candidate.Source, $vr.ErrorHex
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
    $synopsis = "[FAILURE] Unsigned or unverified driver package detected: {0}{1} ver [{2}]" -f $(if ($prov) { "$($prov), " } else { '' }), $deviceName, $ver
    Write-Warning (New-WarningMessage -Synopsis $synopsis -Details $detail)
  }

  if (-not $bad -and -not $warn) {
    Write-Warning "[PASS] All examined PnP driver packages appear signed (whitelisted instances excluded)."
  }
}


function HealthTest-CrashDumpSignals__E {
<#
Description: Checks for recent minidumps that indicate recent system crashes.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Disk), Medium(Time)
Uses: None.
#>
    param([int]$Hours = 48)

    $pass = $true
    if ($Hours -lt 1) { $Hours = 1 }
    $cutoff = (Get-Date).AddHours(-$Hours)

    Get-ChildItem "$env:SystemRoot\Minidump" -Filter *.dmp -ErrorAction SilentlyContinue | ?{ $_.LastWriteTime -gt $cutoff } | %{
        Write-Warning "[FAILURE] Found $env:SystemRoot\Minidump\ file(s) within the last N hours`nN=$Hours hours. File: $env:SystemRoot\Minidump\$($_.name))"
        $pass = $false
    }

    if ($pass) {
        Write-Warning "[PASS] No recent minidumps"
    }
}

function HealthTest-SeriousRecentEventLogs__S {
<#
Description: Checks recent event logs for serious shutdown, bugcheck, disk, or application crash events.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: Get-WinEvent.
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
        $eventDateText = if ($EventRecord.TimeCreated) { ([datetime]$EventRecord.TimeCreated).ToString('yyyy-MM-dd') } else { 'unknown-date' }
        Write-Warning "[$Severity] $Synopsis`n$eventDateText | $($EventRecord.ProviderName) | Event ID $($EventRecord.Id)`n$msg"
    }

    function Get-FaultingApplicationName($EventRecord) {
        if ($null -eq $EventRecord -or [string]::IsNullOrWhiteSpace($EventRecord.Message)) { return "" }

        $match = [regex]::Match($EventRecord.Message, '(?im)^\s*Faulting application name:\s*([^,\r\n]+)')
        if ($match.Success) {
            return $match.Groups[1].Value.Trim()
        }

        return ""
    }

    # [FAILURE] Blue screen / bugcheck / unexpected shutdown
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

    # [WARNING] Disk errors
    $diskProviders = @('disk', 'Ntfs', 'stornvme', 'storahci', 'iaStorA', 'iaStorAVC', 'iaStorV')
    $diskEventIds = @(7, 51, 52, 55, 98, 129, 153, 157)
    Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $cutoff; Level = 2 } -ErrorAction SilentlyContinue |
        Where-Object { ($diskProviders -contains $_.ProviderName) -or ($diskEventIds -contains $_.Id) } |
        ForEach-Object {
            $totalFindings++
            Write-EventFinding -Severity 'warning' -Synopsis 'Detected serious disk error in System log' -EventRecord $_
        }

    # [NOTICE] Application crashes
    Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000; ProviderName = 'Application Error'; StartTime = $cutoff } -ErrorAction SilentlyContinue |
        ForEach-Object {
            $totalFindings++
            $appName = Get-FaultingApplicationName -EventRecord $_
            $synopsis = if ($appName) { "Detected application crash in Application log: $appName" } else { 'Detected application crash in Application log' }
            Write-EventFinding -Severity 'notice' -Synopsis $synopsis -EventRecord $_
        }

    if ($totalFindings -eq 0) {
        Write-Warning "[PASS] No serious shutdown, bugcheck, disk error, or application crash events found in the last $Hours hour(s)"
    }
}


function HealthTest-HotfixBaseline__E{
<#
Description: Checks whether all required hotfixes from the baseline are installed.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-HotFix.
#>
  [CmdletBinding()] param([string[]]$RequiredKBs)
  if(-not $RequiredKBs -or $RequiredKBs.Count -eq 0){ Write-Warning "[PASS] No hotfix baseline provided"; return }
  $have=(Get-HotFix | Select-Object -ExpandProperty HotFixID)
  $miss=@()
  foreach($kb in $RequiredKBs){
    if($have -notcontains $kb){ $miss += $kb; Write-Warning "[FAILURE] Missing required hotfix: $kb"}
  }
  if($miss.Count -eq 0){ Write-Warning "[PASS] All required hotfixes are installed"}
}

function HealthTest-BitLockerStatus__E {
<#
Description: Checks whether detected volumes are protected by BitLocker.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-Command, Get-BitLockerVolume.
#>
    if ($Global:GCHDQMTA.isHostVM) {
        Write-Warning "[info] Computer is a VM; skipping HealthTest-BitLockerStatus"
		return
	}
    if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        Write-Warning "[WARNING] BitLocker PowerShell cmdlets not available; skipping BitLocker status check"
		return
    }

    $pass = $true

    $vols = Get-BitLockerVolume -ErrorAction SilentlyContinue
    if (-not $vols) {
        Write-Warning "[WARNING] No BitLocker-capable volumes found"}
    $vols | Where-Object { $_.ProtectionStatus -ne 'On' } | %{
        Write-Warning "[WARNING] Volume not protected by BitLocker: $($_.MountPoint)"
        $pass = $false
    }
    if ($pass) {
        Write-Warning "[PASS] BitLocker protection is ON for all detected volumes"}
}


function HealthTest-NtlmHardening__E {
<#
Description: Checks whether NTLM hardening registry settings meet the security baseline.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: None.
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
    Write-Warning ("[WARNING] NTLM is not fully hardened (NoLMHash is not 1)`n$details")
  } elseif ($level -lt 5) {
    Write-Warning ("[WARNING] NTLM is not fully hardened (LmCompatibilityLevel<5)`n$details")
  } else {
    Write-Warning "[PASS] NTLM is fully hardened`n$details"
  }
}


function HealthTest-RdpHardening__E {
<#
Description: Checks whether RDP is hardened with NLA enabled and a TLS certificate bound.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Network)
Uses: Get-LiveSessionInfo, Get-WtsServerHandle, Get-WtsString.
#>
  $k = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'

  $bag  = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
  $nla  = if ($bag -and $bag.PSObject.Properties['UserAuthentication'])     { $bag.PSObject.Properties['UserAuthentication'].Value }     else { $null }
  $cert = if ($bag -and $bag.PSObject.Properties['SSLCertificateSHA1Hash']) { $bag.PSObject.Properties['SSLCertificateSHA1Hash'].Value } else { $null }

  $certBound = ($null -ne $cert) -and ($cert.Trim() -ne '')

  $isServer = $false
  try { $isServer = ((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).DomainRole -ge 2) } catch {}

  if ($nla -eq 1 -and $certBound) {
    Write-Warning "[PASS] RDP hardened: NLA enabled and a certificate is bound"
  } else {
    $sev = "Severity: Medium. Risk: Users may click through name-mismatch warnings; increases MITM risk on first-connect or via spoofing." + $(if($isServer){ " On a DC this is sensitive." } else { "" })
    $rdpState = "NLA=$nla; CertBound=$(if($certBound){$true}else{$false})"
    if ($isServer) {
      Write-Warning "[WARNING] RDP is not hardened (NLA and/or TLS certificate binding missing)`n$rdpState`n$sev"
    } else {
      Write-Warning "[NOTICE] RDP is not hardened (NLA and/or TLS certificate binding missing)`n$rdpState`n$sev"
    }
  }
}

function Get-LiveSessionInfo {
<#
.SYNOPSIS
Gets live/current Desktop Sessions details.

.OUTPUTS
Produces one psCustomObject for each matching session:
  ComputerName      : Computer that was queried.
  SessionId         : Session ID.
  State             : Current session state.
  SessionName       : Session name reported by the host.
  UserName          : Session user name, if available.
  Domain            : Session domain, if available.
  UserPrincipal     : Domain\user when both are known; otherwise user.
  ClientName        : Client computer name, if available.
  ClientAddress     : Client IP address, if available.
  Protocol          : Connection protocol description, if available.
  ClientBuild       : Client build number, if available.
  ClientDisplay     : Client display summary, if available.
  ClientDirectory   : Client install path, if available.
  LogonTime         : Session logon time, if available.
  ConnectTime       : Last connect time, if available.
  DisconnectTime    : Last disconnect time, if available.
  LastInputTime     : Last observed user input time, if available.
  SnapshotTime      : Time of the timing snapshot, if available.
  IdleTime          : Time since last input, if available.
  SessionAge        : Time since logon, if available.
  ConnectedDuration : Time since connect for connected sessions, if
                      available.
  DisconnectedTime  : Time since disconnect for disconnected sessions,
                      if available.

.DESCRIPTION
Queries the current session table of the target computer and returns
zero or more matching sessions.

Intended for live state:
who owns the session now, whether it is active or disconnected, where
the client came from, and how long it has been idle or disconnected.

If SessionId is omitted, all sessions are considered. If SessionId is
specified, only matching sessions are returned. Unknown session IDs
result in no output for those IDs.

A terminating error is raised if the target cannot be opened for
session queries or if session enumeration fails.

.PARAMETER ComputerName
Target computer to query.

Use a remote computer name to query that host. Values that refer to
the local computer are treated as a local query.

.PARAMETER SessionId
Limits results to the specified session IDs.

When set, only sessions whose ID is in this list are returned;
otherwise all sessions are returned.
#>
  [CmdletBinding()]
  param(
    [string]$ComputerName = $env:COMPUTERNAME,
    [int[]]$SessionId
  )

  if (-not ('Toula.WtsEx.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace Toula.WtsEx
{
    public enum WTS_CONNECTSTATE_CLASS
    {
        WTSActive,
        WTSConnected,
        WTSConnectQuery,
        WTSShadow,
        WTSDisconnected,
        WTSIdle,
        WTSListen,
        WTSReset,
        WTSDown,
        WTSInit
    }

    public enum WTS_INFO_CLASS
    {
        WTSInitialProgram,
        WTSApplicationName,
        WTSWorkingDirectory,
        WTSOEMId,
        WTSSessionId,
        WTSUserName,
        WTSWinStationName,
        WTSDomainName,
        WTSConnectState,
        WTSClientBuildNumber,
        WTSClientName,
        WTSClientDirectory,
        WTSClientProductId,
        WTSClientHardwareId,
        WTSClientAddress,
        WTSClientDisplay,
        WTSClientProtocolType,
        WTSIdleTime,
        WTSLogonTime,
        WTSIncomingBytes,
        WTSOutgoingBytes,
        WTSIncomingFrames,
        WTSOutgoingFrames,
        WTSClientInfo,
        WTSSessionInfo,
        WTSSessionInfoEx,
        WTSConfigInfo,
        WTSValidationInfo,
        WTSSessionAddressV4,
        WTSIsRemoteSession
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WTS_SESSION_INFO
    {
        public Int32 SessionID;
        public IntPtr pWinStationName;
        public WTS_CONNECTSTATE_CLASS State;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WTS_CLIENT_ADDRESS
    {
        public Int32 AddressFamily;

        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 20)]
        public byte[] Address;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WTS_CLIENT_DISPLAY
    {
        public Int32 HorizontalResolution;
        public Int32 VerticalResolution;
        public Int32 ColorDepth;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WTSINFOEX_LEVEL1_W
    {
        public UInt32 SessionId;
        public WTS_CONNECTSTATE_CLASS SessionState;
        public Int32 SessionFlags;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 33)]
        public string WinStationName;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 21)]
        public string UserName;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 18)]
        public string DomainName;

        public Int64 LogonTime;
        public Int64 ConnectTime;
        public Int64 DisconnectTime;
        public Int64 LastInputTime;
        public Int64 CurrentTime;
        public UInt32 IncomingBytes;
        public UInt32 OutgoingBytes;
        public UInt32 IncomingFrames;
        public UInt32 OutgoingFrames;
        public UInt32 IncomingCompressedBytes;
        public UInt32 OutgoingCompressedBytes;
    }

    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
    public struct WTSINFOEX_LEVEL_W
    {
        [FieldOffset(0)]
        public WTSINFOEX_LEVEL1_W WTSInfoExLevel1;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WTSINFOEXW
    {
        public UInt32 Level;
        public WTSINFOEX_LEVEL_W Data;
    }

    public static class NativeMethods
    {
        [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "WTSOpenServerW")]
        public static extern IntPtr WTSOpenServer(string pServerName);

        [DllImport("wtsapi32.dll", SetLastError = true)]
        public static extern void WTSCloseServer(IntPtr hServer);

        [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "WTSEnumerateSessionsW")]
        public static extern bool WTSEnumerateSessions(
            IntPtr hServer,
            int Reserved,
            int Version,
            out IntPtr ppSessionInfo,
            out int pCount
        );

        [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "WTSQuerySessionInformationW")]
        public static extern bool WTSQuerySessionInformation(
            IntPtr hServer,
            int sessionId,
            WTS_INFO_CLASS wtsInfoClass,
            out IntPtr ppBuffer,
            out int pBytesReturned
        );

        [DllImport("wtsapi32.dll")]
        public static extern void WTSFreeMemory(IntPtr pMemory);
    }
}
"@
  }

  function Get-WtsServerHandle {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or
        $Name -eq '.' -or
        $Name -eq 'localhost' -or
        $Name -ieq $env:COMPUTERNAME) {
      return [IntPtr]::Zero
    }
    $handle = [Toula.WtsEx.NativeMethods]::WTSOpenServer($Name)
    if ($handle -eq [IntPtr]::Zero) {
      throw "Failed to open WTS server handle for '$Name'."
    }
    return $handle
  }

  function Convert-PtrToStringUni {
    param([IntPtr]$Ptr)
    if ($Ptr -eq [IntPtr]::Zero) { return $null }
    [Runtime.InteropServices.Marshal]::PtrToStringUni($Ptr)
  }

  function Convert-WtsFileTimeToLocal {
    param([long]$Value)
    if ($Value -le 0) { return $null }
    try { [DateTime]::FromFileTimeUtc($Value).ToLocalTime() } catch { $null }
  }

  function Get-WtsString {
    param(
      [IntPtr]$Server,
      [int]$Id,
      [Toula.WtsEx.WTS_INFO_CLASS]$InfoClass
    )
    $buf = [IntPtr]::Zero
    $bytes = 0
    try {
      if (-not [Toula.WtsEx.NativeMethods]::WTSQuerySessionInformation($Server, $Id, $InfoClass, [ref]$buf, [ref]$bytes)) {
        return $null
      }
      if ($buf -eq [IntPtr]::Zero -or $bytes -le 1) {
        return $null
      }
      $s = [Runtime.InteropServices.Marshal]::PtrToStringUni($buf)
      if ([string]::IsNullOrWhiteSpace($s)) { return $null }
      $s
    }
    finally {
      if ($buf -ne [IntPtr]::Zero) {
        [Toula.WtsEx.NativeMethods]::WTSFreeMemory($buf)
      }
    }
  }

  function Get-WtsUInt16 {
    param(
      [IntPtr]$Server,
      [int]$Id,
      [Toula.WtsEx.WTS_INFO_CLASS]$InfoClass
    )
    $buf = [IntPtr]::Zero
    $bytes = 0
    try {
      if (-not [Toula.WtsEx.NativeMethods]::WTSQuerySessionInformation($Server, $Id, $InfoClass, [ref]$buf, [ref]$bytes)) {
        return $null
      }
      if ($buf -eq [IntPtr]::Zero -or $bytes -lt 2) {
        return $null
      }
      [Runtime.InteropServices.Marshal]::ReadInt16($buf)
    }
    finally {
      if ($buf -ne [IntPtr]::Zero) {
        [Toula.WtsEx.NativeMethods]::WTSFreeMemory($buf)
      }
    }
  }

  function Get-WtsUInt32 {
    param(
      [IntPtr]$Server,
      [int]$Id,
      [Toula.WtsEx.WTS_INFO_CLASS]$InfoClass
    )
    $buf = [IntPtr]::Zero
    $bytes = 0
    try {
      if (-not [Toula.WtsEx.NativeMethods]::WTSQuerySessionInformation($Server, $Id, $InfoClass, [ref]$buf, [ref]$bytes)) {
        return $null
      }
      if ($buf -eq [IntPtr]::Zero -or $bytes -lt 4) {
        return $null
      }
      [Runtime.InteropServices.Marshal]::ReadInt32($buf)
    }
    finally {
      if ($buf -ne [IntPtr]::Zero) {
        [Toula.WtsEx.NativeMethods]::WTSFreeMemory($buf)
      }
    }
  }

  function Get-WtsClientAddressText {
    param(
      [IntPtr]$Server,
      [int]$Id
    )
    $buf = [IntPtr]::Zero
    $bytes = 0
    try {
      if (-not [Toula.WtsEx.NativeMethods]::WTSQuerySessionInformation($Server, $Id, [Toula.WtsEx.WTS_INFO_CLASS]::WTSClientAddress, [ref]$buf, [ref]$bytes)) {
        return $null
      }
      if ($buf -eq [IntPtr]::Zero) {
        return $null
      }
      $addr = [Runtime.InteropServices.Marshal]::PtrToStructure($buf, [type][Toula.WtsEx.WTS_CLIENT_ADDRESS])
      if ($null -eq $addr.Address -or $addr.Address.Length -lt 6) {
        return $null
      }
      if ($addr.AddressFamily -eq 2) {
        return [string]::Join('.', @($addr.Address[2], $addr.Address[3], $addr.Address[4], $addr.Address[5]))
      }
      if ($addr.AddressFamily -eq 23 -and $addr.Address.Length -ge 18) {
        try { return ([Net.IPAddress]::new([byte[]]$addr.Address[2..17])).ToString() } catch { return $null }
      }
      $null
    }
    finally {
      if ($buf -ne [IntPtr]::Zero) {
        [Toula.WtsEx.NativeMethods]::WTSFreeMemory($buf)
      }
    }
  }

  function Get-WtsClientDisplayText {
    param(
      [IntPtr]$Server,
      [int]$Id
    )
    $buf = [IntPtr]::Zero
    $bytes = 0
    try {
      if (-not [Toula.WtsEx.NativeMethods]::WTSQuerySessionInformation($Server, $Id, [Toula.WtsEx.WTS_INFO_CLASS]::WTSClientDisplay, [ref]$buf, [ref]$bytes)) {
        return $null
      }
      if ($buf -eq [IntPtr]::Zero) {
        return $null
      }
      $display = [Runtime.InteropServices.Marshal]::PtrToStructure($buf, [type][Toula.WtsEx.WTS_CLIENT_DISPLAY])
      if ($display.HorizontalResolution -gt 0 -and $display.VerticalResolution -gt 0) {
        return "$($display.HorizontalResolution)x$($display.VerticalResolution)x$($display.ColorDepth)"
      }
      $null
    }
    finally {
      if ($buf -ne [IntPtr]::Zero) {
        [Toula.WtsEx.NativeMethods]::WTSFreeMemory($buf)
      }
    }
  }

  function Get-WtsSessionTiming {
    param(
      [IntPtr]$Server,
      [int]$Id
    )

    $buf = [IntPtr]::Zero
    $bytes = 0

    try {
      if (-not [Toula.WtsEx.NativeMethods]::WTSQuerySessionInformation(
        $Server,
        $Id,
        [Toula.WtsEx.WTS_INFO_CLASS]::WTSSessionInfoEx,
        [ref]$buf,
        [ref]$bytes
      )) {
        return $null
      }

      if ($buf -eq [IntPtr]::Zero) {
        return $null
      }

      $info = [Runtime.InteropServices.Marshal]::PtrToStructure($buf, [type][Toula.WtsEx.WTSINFOEXW])
      if ($info.Level -ne 1) {
        return $null
      }

      $x = $info.Data.WTSInfoExLevel1

      $logonTime = Convert-WtsFileTimeToLocal $x.LogonTime
      $connectTime = Convert-WtsFileTimeToLocal $x.ConnectTime
      $disconnectTime = Convert-WtsFileTimeToLocal $x.DisconnectTime
      $lastInputTime = Convert-WtsFileTimeToLocal $x.LastInputTime
      $snapshotTime = Convert-WtsFileTimeToLocal $x.CurrentTime

      $idleTime = $null
      if ($snapshotTime -and $lastInputTime -and $snapshotTime -ge $lastInputTime) {
        $idleTime = $snapshotTime - $lastInputTime
      }

      $sessionAge = $null
      if ($snapshotTime -and $logonTime -and $snapshotTime -ge $logonTime) {
        $sessionAge = $snapshotTime - $logonTime
      }

      $connectedDuration = $null
      if ($snapshotTime -and $connectTime -and $snapshotTime -ge $connectTime -and
          ($x.SessionState -eq [Toula.WtsEx.WTS_CONNECTSTATE_CLASS]::WTSActive -or
           $x.SessionState -eq [Toula.WtsEx.WTS_CONNECTSTATE_CLASS]::WTSConnected -or
           $x.SessionState -eq [Toula.WtsEx.WTS_CONNECTSTATE_CLASS]::WTSShadow)) {
        $connectedDuration = $snapshotTime - $connectTime
      }

      $disconnectedTime = $null
      if ($snapshotTime -and $disconnectTime -and $snapshotTime -ge $disconnectTime -and
          $x.SessionState -eq [Toula.WtsEx.WTS_CONNECTSTATE_CLASS]::WTSDisconnected) {
        $disconnectedTime = $snapshotTime - $disconnectTime
      }

      [pscustomobject]@{
        LogonTime         = $logonTime
        ConnectTime       = $connectTime
        DisconnectTime    = $disconnectTime
        LastInputTime     = $lastInputTime
        SnapshotTime      = $snapshotTime
        IdleTime          = $idleTime
        SessionAge        = $sessionAge
        ConnectedDuration = $connectedDuration
        DisconnectedTime  = $disconnectedTime
      }
    }
    finally {
      if ($buf -ne [IntPtr]::Zero) {
        [Toula.WtsEx.NativeMethods]::WTSFreeMemory($buf)
      }
    }
  }

  function Convert-WtsProtocol {
    param([Nullable[int]]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -eq 0) { return 'ConsoleOrUnknown' }
    if ($Value -eq 2) { return 'RDP' }
    "Other($Value)"
  }

  $server = Get-WtsServerHandle -Name $ComputerName
  $sessionsPtr = [IntPtr]::Zero
  $count = 0

  try {
    if (-not [Toula.WtsEx.NativeMethods]::WTSEnumerateSessions($server, 0, 1, [ref]$sessionsPtr, [ref]$count)) {
      throw "WTSEnumerateSessions failed for '$ComputerName'."
    }

    $structSize = [Runtime.InteropServices.Marshal]::SizeOf([type][Toula.WtsEx.WTS_SESSION_INFO])

    for ($i = 0; $i -lt $count; $i++) {
      $current = [IntPtr]($sessionsPtr.ToInt64() + ($i * $structSize))
      $session = [Runtime.InteropServices.Marshal]::PtrToStructure($current, [type][Toula.WtsEx.WTS_SESSION_INFO])

      if ($SessionId -and ($SessionId -notcontains $session.SessionID)) {
        continue
      }

      $sessionName = Convert-PtrToStringUni $session.pWinStationName
      if ([string]::IsNullOrWhiteSpace($sessionName)) { $sessionName = $null }

      $user = Get-WtsString -Server $server -Id $session.SessionID -InfoClass ([Toula.WtsEx.WTS_INFO_CLASS]::WTSUserName)
      $domain = Get-WtsString -Server $server -Id $session.SessionID -InfoClass ([Toula.WtsEx.WTS_INFO_CLASS]::WTSDomainName)
      $clientName = Get-WtsString -Server $server -Id $session.SessionID -InfoClass ([Toula.WtsEx.WTS_INFO_CLASS]::WTSClientName)
      $clientAddress = Get-WtsClientAddressText -Server $server -Id $session.SessionID
      $protocolRaw = Get-WtsUInt16 -Server $server -Id $session.SessionID -InfoClass ([Toula.WtsEx.WTS_INFO_CLASS]::WTSClientProtocolType)
      $clientBuild = Get-WtsUInt32 -Server $server -Id $session.SessionID -InfoClass ([Toula.WtsEx.WTS_INFO_CLASS]::WTSClientBuildNumber)
      $clientDirectory = Get-WtsString -Server $server -Id $session.SessionID -InfoClass ([Toula.WtsEx.WTS_INFO_CLASS]::WTSClientDirectory)
      $clientDisplay = Get-WtsClientDisplayText -Server $server -Id $session.SessionID
      $timing = Get-WtsSessionTiming -Server $server -Id $session.SessionID

      [pscustomobject]@{
        ComputerName      = $ComputerName
        SessionId         = $session.SessionID
        State             = [string]$session.State
        SessionName       = $sessionName
        UserName          = $user
        Domain            = $domain
        UserPrincipal     = if ($user) { if ($domain) { "$domain\$user" } else { $user } } else { $null }
        ClientName        = $clientName
        ClientAddress     = $clientAddress
        Protocol          = Convert-WtsProtocol -Value $protocolRaw
        ClientBuild       = $clientBuild
        ClientDisplay     = $clientDisplay
        ClientDirectory   = $clientDirectory
        LogonTime         = if ($timing) { $timing.LogonTime } else { $null }
        ConnectTime       = if ($timing) { $timing.ConnectTime } else { $null }
        DisconnectTime    = if ($timing) { $timing.DisconnectTime } else { $null }
        LastInputTime     = if ($timing) { $timing.LastInputTime } else { $null }
        SnapshotTime      = if ($timing) { $timing.SnapshotTime } else { $null }
        IdleTime          = if ($timing) { $timing.IdleTime } else { $null }
        SessionAge        = if ($timing) { $timing.SessionAge } else { $null }
        ConnectedDuration = if ($timing) { $timing.ConnectedDuration } else { $null }
        DisconnectedTime  = if ($timing) { $timing.DisconnectedTime } else { $null }
      }
    }
  }
  finally {
    if ($sessionsPtr -ne [IntPtr]::Zero) {
      [Toula.WtsEx.NativeMethods]::WTSFreeMemory($sessionsPtr)
    }
    if ($server -ne [IntPtr]::Zero) {
      [Toula.WtsEx.NativeMethods]::WTSCloseServer($server)
    }
  }
}

function HealthTest-StaleRdpSessions {
<#
Description: Checks for idle or disconnected RDP sessions older than the allowed threshold.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Get-LiveSessionInfo.
#>
    [CmdletBinding()]
    param(
        [TimeSpan]$Threshold = ([TimeSpan]::FromHours(8))
    )

    $issueFound = $false

    $sessions = @(Get-LiveSessionInfo)

    foreach ($session in $sessions) {
        if (-not $session) { continue }
        if ([string]::IsNullOrWhiteSpace($session.UserName)) { continue }

        $problemType = $null
        $problemAge = $null

        if ($session.State -eq 'WTSDisconnected' -and $session.DisconnectedTime -ge $Threshold) {
            $problemType = 'disconnected'
            $problemAge = $session.DisconnectedTime
        }
        elseif ($session.IdleTime -ge $Threshold) {
            $problemType = 'idle'
            $problemAge = $session.IdleTime
        }

        if (-not $problemType) { continue }

        $issueFound = $true

        $who = $session.UserPrincipal
        if ([string]::IsNullOrWhiteSpace($who)) { $who = $session.UserName }

        $issueSynopsis = "User $who has a $problemType session for more than $([int]$Threshold.TotalHours) hours"

        $detailLines = @()
        $detailLines += "State: $($session.State)"
        if ($session.SessionName)      { $detailLines += "SessionName: $($session.SessionName)" }
        if ($session.LogonTime)        { $detailLines += "LogonTime: $($session.LogonTime)" }
        if ($session.ConnectTime)      { $detailLines += "ConnectTime: $($session.ConnectTime)" }
        if ($session.DisconnectTime)   { $detailLines += "DisconnectTime: $($session.DisconnectTime)" }
        if ($session.LastInputTime)    { $detailLines += "LastInputTime: $($session.LastInputTime)" }
        if ($session.IdleTime)         { $detailLines += "IdleTime: $($session.IdleTime)" }
        if ($session.DisconnectedTime) { $detailLines += "DisconnectedTime: $($session.DisconnectedTime)" }
        if ($session.SessionAge)       { $detailLines += "SessionAge: $($session.SessionAge)" }
        if ($session.ClientName)       { $detailLines += "ClientName: $($session.ClientName)" }
        if ($session.ClientAddress)    { $detailLines += "ClientAddress: $($session.ClientAddress)" }
        if ($session.Protocol)         { $detailLines += "Protocol: $($session.Protocol)" }

        $details = $detailLines -join "`n"
        Write-Warning ("[NOTICE] $issueSynopsis" + $(if ($details) { "`n$details" } else { '' }))
    }

    if (-not $issueFound) {
        Write-Warning "[pass] No Desktop Sessions found idle or disconnected for more than $([int]$Threshold.TotalHours) hours"
    }
}

function HealthTest-NonDefaultShares__E {
<#
Description: Detects non-default SMB shares and notes when file and print sharing is unnecessarily enabled.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: get-service, Set-Service, Stop-Service.
#>
  # 0(Workstation standalone),  1(Workstation domain joined), 2(Server standalone), 3(Server joined), 4(DC non-FSMO), 5(DC with FSMO role)
  $domainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole
  $isHostDC = ($domainRole -in 4,5)

    $lanManServer_service = (get-service -Name "LanmanServer")
    $shares_beside_the_system_ones = Get-CimInstance -ClassName Win32_Share | Select-Object Name, Path | ?{$_.name -notlike '*$' -and $_.path -notlike 'C:\Windows\SYSVOL\sysvol*'}
    if ($shares_beside_the_system_ones) {
        $shares_beside_the_system_ones | %{Write-Warning "[WARNING] Found a share named '$($_.name)' that shares '$($_.Path)'"}
    } else {
        if ((Get-Service  -Name "LanmanServer").status -eq 'Stopped') {
            Write-Warning "[PASS] No shares except the defaults and LanMan service is stopped."} else {
            Write-Warning "[PASS] Found no shares except the default ones (like C$, ADMIN$)."; if (!$isHostDC -and ($lanManServer_service.status -ne 'stopped' -or $lanManServer_service.StartType -ne 'Disabled')) {
                if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 2) { # server
                    Write-Warning "[WARNING] File & print sharing is enabled. It's recomended to disable it unless you really need it`nRun this if you want to disable:`n   Set-Service -Name 'LanmanServer' -StartupType Disabled; Stop-Service -Name 'LanmanServer'"
                } else { # workstation
                    Write-Output ("File & print sharing is enabled on a workstation." + "`n" + "You may consider disabling it to reduce the attack surface")
                }
            }
        }
    }
}


function HealthTest-LocalAcntRequirePass__E {
<#
Description: Checks whether local accounts require passwords.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: None.
#>
    $ok = $true
    $no_req_pass_accounts=Get-CimInstance -Class Win32_UserAccount -Filter `
        "LocalAccount=True AND Disabled=False AND PasswordRequired=False"
    if ($no_req_pass_accounts) {
        $no_req_pass_accounts | %{
            try {$account_name = $_.name} catch {$account_name="(FAILED_TO_GET_NAME)"}
            $ok = $false
            $comment =  "Make sure the account password is set and then run this command:`n& cmd /c 'net user `"$($_.name)`" /passwordreq:yes'"
            Write-Warning "[FAILURE] This local account has the property PasswordRequired set to false: $account_name`n$comment"
        }
    }
    if ($ok) {Write-Warning "[PASS] All local accounts have PasswordRequired True"}
}


function HealthTest-RestrictAnonymous__E {
<#
Description: Checks whether anonymous access hardening settings meet the baseline.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: None.
#>
  $p  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
  $ra = (Get-ItemProperty $p -Name restrictanonymous      -ErrorAction SilentlyContinue).restrictanonymous
  $rs = (Get-ItemProperty $p -Name restrictanonymoussam   -ErrorAction SilentlyContinue).restrictanonymoussam
  $ea = (Get-ItemProperty $p -Name EveryoneIncludesAnonymous -ErrorAction SilentlyContinue).EveryoneIncludesAnonymous

  $pass = ($rs -eq 1 -and $ea -eq 0)
  $details="RestrictAnonymous=$ra; RestrictAnonymousSAM=$rs; EveryoneIncludesAnonymous=$ea"

  if($pass){
    Write-Warning "[PASS] Anonymous access hardening (baseline met)`n$details"
  } else {
    Write-Warning "[FAILURE] Anonymous access hardening not at baseline`n$details. Recommendation: Set RestrictAnonymousSAM=1 and EveryoneIncludesAnonymous=0 via GPO."
  }
}

function HealthTest-DefaultLocale__E {
<#
Description: Checks whether the system locale matches the expected legacy language baseline.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: None.
#>
    # see https://newbedev.com/how-can-i-manually-determine-the-codepage-and-locale-of-the-current-os
    $loc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' | Select-Object ACP,OEMCP
    $loc_acp = $loc.ACP; $loc_oemcp = $loc.OEMCP
    if($loc_acp -eq 1253 -and $loc_oemcp -eq 737){
      Write-Warning "[PASS] Host supports legacy Greek (ACP/OEMCP 1253/737)."
    }elseif($loc_acp -eq 1252 -and $loc_oemcp -eq 437){
      Write-Warning "[NOTICE] This host uses default English/ANSI (1252/437), so legacy Greek apps may fail."
    }else{
      Write-Warning "[WARNING] Unusual non-Unicode locale: $loc_acp / $loc_oemcp (ACP/OEMCP). Greek is 1253/737; Default english is 1252/437."
    }
}

function HealthTest-PendingReboot__E {
<#
Description: Checks for Windows pending-reboot indicators.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: None.
#>
    $pending = $false
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending = $true }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending = $true }
    $pfr = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
    if ($pfr -and $pfr.PendingFileRenameOperations) {write-debug "Found entries in HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations (if you are not sure what this means, you can safely ignore it)"}
    if ($pending) { Write-Warning "[NOTICE] Windows need a reboot to apply some changes"; return}
    Write-Warning "[PASS] No pending reboot indicators"
}

function HealthTest-SmbSigningRequired__E{
<#
Description: Checks whether the SMB server requires signing when the server service is running.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-Service, Get-SmbServerConfiguration.
#>
  if ((Get-PropValue -obj (Get-Service -Name LanmanServer) -name Status) -ne 'running') {
      Write-Warning "[PASS] Skipping HealthTest-SmbSigningRequired; LanmanServer service not running."
      return
  }

  $c=Get-SmbServerConfiguration
  if($c.RequireSecuritySignature){
    Write-Warning "[PASS] SMB signing required on the server"
  } else {
    Write-Warning "[WARNING] SMB signing is not required`nRequireSecuritySignature=$($c.RequireSecuritySignature); EnableSecuritySignature=$($c.EnableSecuritySignature)"
  }
}

function HealthTest-ShadowStorage__E {
<#
Description: Checks whether Volume Shadow Copy storage is configured and sized within the recommended range.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Disk), Medium(Time)
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


function HealthTest-DnsClientService__E{
<#
Description: Checks whether the DNS Client service is running.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: High(Network)
Uses: Get-Service.
#>
  $s=Get-Service Dnscache -ErrorAction Stop
  if($s.Status -eq 'Running'){ Write-Warning "[PASS] DNS Client service running" } else { Write-Warning "[FAILURE] DNS Client service is not running`nStatus=$($s.Status)" }
}


function HealthTest-LocalAdminsBaseline {
<#
Description: Checks for unexpected members in the local Administrators group.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: None.
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
            Write-Warning "[WARNING] Unexpected Local Administrator: $full"
            $pass = $false
        }
    }
    if ($pass) {
        Write-Warning "[PASS] No unexpected accounts in Local Administrators"}
}

function HealthTest-UnexpectedListeningPorts__S {
<#
Description: Compares listening TCP ports to the baseline and identifies unexpected listeners with process context.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Time), Medium(Network)
Uses: Get-NetTCPConnection, Get-Process, Resolve-ExecutablePath.
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
            Write-Warning "[NOTICE] Optional baseline port is listening: $p ($procDescr)"
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
                Write-Warning ("[WARNING] Unexpected listening port: $p (Process: $procDescr, Vendor: $vendor)`n$comment")
            } else {
                Write-Warning ("[NOTICE] Unexpected listening port: $p (Process: $procDescr, Vendor: $vendor)`n$comment")
            }
        } else {
            Write-Warning ("[FAILURE] Unexpected listening port: $p (Process: $procDescr, Vendor: $vendor)`n$comment")
        }
    }

    if (-not $bad) { Write-Warning "[PASS] Listening ports are within baseline"}
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
        $cleanName = $cleanName -replace '(?i)\bv\d+(?:\.\d+)*(?:[a-z]\d+)?\b', 'VER'
        $cleanName = $cleanName -replace '\b\d+(?:\.\d+)+\b', 'VER'
        $cleanName = $cleanName -replace '[\(\)\{\}\[\],]', ' '
        $cleanName = $cleanName -replace '\s-\s', ' '
        $cleanName = $cleanName -replace '\s+', ' '
        return $cleanName.Trim()
    }
}

function Test-IsMicrosoftInstalledSoftwareUpdate {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Name,

        [AllowNull()]
        [string]$Publisher
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }

    $publisherLooksMicrosoft = $false
    if (-not [string]::IsNullOrWhiteSpace($Publisher)) {
        $publisherLooksMicrosoft = $Publisher -match '(?i)\bmicrosoft(?:\s+corporation)?\b'
    }

    $nameLooksLikeMicrosoftUpdate = $Name -match '(?ix)
        \bKB\d{6,8}\b
        |
        \bSecurity\ Update\b
        |
        \bHotfix\b
        |
        \bCumulative\ Update\b
        |
        \bUpdate\ for\ Microsoft\b
        |
        \bGDR\s+\d+\s+for\s+SQL\s+Server\b
        |
        \bCU\d+\s+for\s+SQL\s+Server\b
    '

    if (-not $nameLooksLikeMicrosoftUpdate) { return $false }

    if ($publisherLooksMicrosoft) { return $true }

    return $Name -match '(?i)\b(SQL\s+Server|Microsoft)\b'
}

function Get-InstalledSoftwareFindingLevel {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Name,

        [AllowNull()]
        [string]$Publisher
    )

    if (Test-IsMicrosoftInstalledSoftwareUpdate -Name $Name -Publisher $Publisher) {
        return 'info'
    }

    $publisherLooksMicrosoft = $false
    if (-not [string]::IsNullOrWhiteSpace($Publisher)) {
        $publisherLooksMicrosoft = $Publisher -match '(?i)\bmicrosoft(?:\s+corporation)?\b'
    }

    if ($publisherLooksMicrosoft) {
        return 'notice'
    }

    return 'warning'
}

function HealthTest-InstalledSW__P {
<#
Description: Reports installed software not present in the baseline inventory.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-InstalledSW, Get-NormalizedSoftwareName, Get-InstalledSoftwareFindingLevel.
#>
    $seen = 0
    foreach ($sw in (Get-InstalledSW)) {
        $seen += 1
        $normalizedName = Get-NormalizedSoftwareName -Name $sw.Name
		if ($sw.Publisher -match 'CN=.*, ') {
    	    # Remove unneeded details from Publisher description. E.g.:
	        # "Microsoft Windows" instead of "CN=Microsoft Windows, O=Microsoft Corporation, L=..., S=..."
		    $publisher = $sw.Publisher -replace '^.*CN=([^,]+).*','$1'
		} else {
		    $publisher = $sw.Publisher
		}
        $details = "Full program name: $($sw.Name); Publisher: $publisher; Install Date: $($sw.InstallDate); Source: $($sw.Source); Scope: $($sw.Scope)"
        $level = Get-InstalledSoftwareFindingLevel -Name $sw.Name -Publisher $sw.Publisher
        Write-Warning "[$level] New installed software: $normalizedName`n$details"
    }

    if ($seen -eq 0) {
        Write-Warning "[PASS] No installed software entries discovered."
    }
}
