<#
Standalone file for HealthTest-UnsignedDrivers.
Generated during the repo-wide health-test split.
#>
# HostRequirement: All

function HealthTest-UnsignedDrivers {
<#
Description: Checks for installed PnP driver packages that appear unsigned.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-PnpDeviceProperty, Get-AuthenticodeSignature.
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

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-UnsignedDrivers
}
