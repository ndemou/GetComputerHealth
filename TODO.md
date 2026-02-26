# TODO

## HealthTest-SysvolContentConsistency
The function HealthTest-SysvolContentConsistency calculates the size and file count of the entire `\\SYSVOL\...\Policies` tree across **all** Domain Controllers over the network. In a production environment with branch offices or many GPOs, this is dangerous. It generates massive WAN traffic. Since Health Tests are already running on every single DC you could in theory compute the hashes localy on each DC (and compute real hashes instead of the pseudo sigs that this function computes) and then exchange and compare them. This will be super fast even over WAN.


## Look at these Gemini suggestions

### 1. Minor Logical Errors (`Test-NetConnectionFast` & `TimeSync`)

**The Fix: Enforce IPv4 and Registry-Based Time Checks**

**A. `Test-NetConnectionFast` (DNS ordering bug)**
The original code fetches all IP addresses and arbitrarily picks the first one or filters clumsily. If a host has IPv6 but the network doesn't route it, the test fails even if IPv4 works.

**Modified Logic:**

```powershell
    # Inside Test-NetConnectionFast process block:
    try {
        # Force IPv4 resolution to match your "IPv4 only is acceptable" requirement
        $ips = [System.Net.Dns]::GetHostAddresses($ComputerName) |
               Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
               Select-Object -ExpandProperty IPAddressToString -First 1

        if ($ips) { $remoteAddr = $ips }
        else {
            # Fallback if no IPv4 found
            $remoteAddr = [System.Net.Dns]::GetHostAddresses($ComputerName) | Select -First 1 -Expand IPAddressToString
        }
    } catch {}

```

**B. `HealthTest-TimeSyncPolicy` (Localization bug)**
The check `$currentTimeSource -eq 'Local CMOS Clock'` fails on non-English Windows (e.g., "Lokale CMOS-Uhr").

**Suggestion:** Instead of parsing the localized text output of `w32tm /query /source`, check the **Registry** configuration, which is language-neutral.

**Modified Logic:**

```powershell
    # Replace the text comparison with a check on the configuration type
    $w32Param = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
    $isNt5Ds  = $w32Param.Type -eq 'NT5DS'

    # If it is configured as NT5DS, it is correct for domain members/DCs.
    # We only alert if it is explicitly using the internal clock while NOT being a PDC.
    if (-not $isNt5Ds -and $currentTimeSource -match 'CMOS|LOCL|Free-running') {
        Log-Failure "Time source is set to Local CMOS/Internal Clock"
    }

```

---

### 2: False Positives in Driver Signing

**The Fix: Use AppLocker or Catalog-Aware Classes**

`Win32_PnPSignedDriver` and `Get-AuthenticodeSignature` are unreliable for modern drivers because they often look for an embedded signature in the `.sys` file. Many valid Microsoft/Intel/Realtek drivers are unsigned binary files whose signature lives in an external `.cat` (Catalog) file.

**Suggestion:** Use the `Get-AppLockerFileInformation` cmdlet (available on most modern Windows versions) to check signatures. It is "Catalog-aware" and will correctly identify a file as signed even if the signature is external.

**Modified Code (`HealthTest-UnsignedDrivers`):**

```powershell
    # Inside the loop where you have the driver path ($sysPath):

    # 1. Try standard Authenticode (fastest)
    $sig = Get-AuthenticodeSignature $sysPath
    if ($sig.Status -eq 'Valid') { continue }

    # 2. If invalid, fallback to AppLocker (slower, but catalog-aware)
    if (Get-Command Get-AppLockerFileInformation -ErrorAction SilentlyContinue) {
        try {
            $appLockerInfo = Get-AppLockerFileInformation -Path $sysPath -ErrorAction Stop
            if ($appLockerInfo.Publisher.PublisherName) {
                # If AppLocker finds a publisher, the system trusts the signature (Catalog or Embedded)
                Log-Notice "Driver validated via Catalog (AppLocker): $($d.DeviceName)"
                continue
            }
        } catch {
            # AppLocker failed to read it, likely actually unsigned or unreadable
        }
    }

    # 3. If both fail, flag it
    $bad = $true
    Log-Failure "Unsigned Driver detected: $sysPath"

```

##  Consider if the following health tests are useful
```
# GPT inspired. I'm not sure of whether it's OK
# Run it and in about half the servers it complained it found "no backup signals"
# .SYNOPSIS Looks for recent backup-related events and highlights failures or missing success signals.
function HealthTest-BackupSignals {
    param(
        [int]$WarnHours = 24,
        [int]$FailHours = 48
    )

    if ($WarnHours -lt 1) { $WarnHours = 1 }
    if ($FailHours -lt $WarnHours) { $FailHours = $WarnHours }

    $failCutoff  = (Get-Date).AddHours(-$FailHours)
    $warnCutoff  = (Get-Date).AddHours(-$WarnHours)

    $events = Get-WinEvent -FilterHashtable @{
            LogName   = 'Application'
            StartTime = $failCutoff
        } -ErrorAction SilentlyContinue

    $events = @($events)
    $backupEvents = @(
        $events | Where-Object {
            $_.ProviderName -match 'VSS|Microsoft\-Windows\-Backup|Windows Server Backup|MSSQLSERVER|VMMS|Veeam|Acronis|DPM'
        }
    )

    if ($backupEvents.Count -eq 0) {
        Log-Warning "No recognizable backup-related events in last $FailHours h"
        return
    }

    $fail = @($backupEvents | Where-Object { $_.LevelDisplayName -match 'Error|Critical' })
    if ($fail.Count -gt 0) {
        Log-failure "Backup-related errors present in last $FailHours h"
        return
    }

    $recentOk = @(
        $backupEvents | Where-Object {
            $_.TimeCreated -gt $warnCutoff -and $_.LevelDisplayName -match 'Information'
        }
    )

    if ($recentOk.Count -gt 0) {
        Log-pass "Backup signals present within last $WarnHours h"
        return
    }

    Log-Warning "No clear successful backup signals within last $WarnHours h (but older backup activity exists)"
}

# GPT inspired. I'm not sure of whether it's OK
# Verify BitLocker recovery objects for specific computer exists in AD
function Test-BitLockerRecoveryInAD($computerName){
  $cn="$($computerName)$"
  $comp=Get-ADComputer -Identity $cn -ErrorAction SilentlyContinue
  if(-not $comp){ Log-pass "Computer account not found in AD (skipping BitLocker recovery check)"; return }
  $ri=Get-ADObject -SearchBase $comp.DistinguishedName -LDAPFilter '(objectClass=msFVE-RecoveryInformation)' -SearchScope OneLevel
  if(($ri | Measure-Object).Count -gt 0){ Log-pass ("BitLocker recovery objects present for this computer ($($ri.Count))") } else { Log-failure "No BitLocker recovery objects found for this computer in AD" }
}


```

## List installed SW

```
c:\it\bin\run-script-on-allDomainServers.ps1 -SkipHosts ac2,epsilonnet -code {
function Get-InstalledSoftware {
    #.SYNOPSIS
    # Gets an exhaustive list of all installed software, avoiding WMI/Win32_Product.
    #
    # .DESCRIPTION
    # Uses .NET Registry classes to explicitly query 64-bit, 32-bit, and User registry hives,
    # bypassing PowerShell provider bitness redirection. Queries Appx packages safely.
    # Leaves deduplication to the caller to prevent data loss.
    # Everything that would show up in the "Add or Remove Programs" control panel should be listed.
    [CmdletBinding()]
    param ()

    $installedSoftware = [System.Collections.Generic.List[PSCustomObject]]::new()

    # 1. .NET Registry Scrape (Fast, Bitness-Aware)
    $registryTargets = @(
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry64; Scope = 'Machine'; Arch = '64-bit' },
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry32; Scope = 'Machine'; Arch = '32-bit' },
        @{ Hive = [Microsoft.Win32.RegistryHive]::CurrentUser;  View = [Microsoft.Win32.RegistryView]::Default;    Scope = 'User';    Arch = 'Native' }
    )

    $baseKeyPath = "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"

    Write-Verbose "Scanning Registry for desktop applications via .NET..."
    
    foreach ($target in $registryTargets) {
        try {
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($target.Hive, $target.View)
            $uninstallKey = $baseKey.OpenSubKey($baseKeyPath)

            if ($uninstallKey) {
                foreach ($subKeyName in $uninstallKey.GetSubKeyNames()) {
                    $appKey = $uninstallKey.OpenSubKey($subKeyName)
                    if (-not $appKey) { continue }

                    $displayName = $appKey.GetValue("DisplayName") -as [string]
                    
                    # Skip if it doesn't have a name (not a real tracked install)
                    if ([string]::IsNullOrWhiteSpace($displayName)) { 
                        $appKey.Close()
                        continue 
                    }

                    # Attempt to parse YYYYMMDD into a DateTime object
                    $rawDate = $appKey.GetValue("InstallDate") -as [string]
                    $parsedDate = $null
                    if ($rawDate -match '^\d{8}$') {
                        try { $parsedDate = [datetime]::ParseExact($rawDate, 'yyyyMMdd', $null) } catch { }
                    }

                    $installedSoftware.Add([PSCustomObject]@{
                        Name              = $displayName.Trim()
                        Version           = $appKey.GetValue("DisplayVersion") -as [string]
                        Publisher         = $appKey.GetValue("Publisher") -as [string]
                        InstallDate       = $parsedDate
                        UninstallString   = $appKey.GetValue("UninstallString") -as [string]
                        RegistryKeyName   = $subKeyName
                        AppxPackageName   = $null
                        Source            = "Registry"
                        Scope             = $target.Scope
                        Architecture      = $target.Arch
                        IsSystemComponent = ($appKey.GetValue("SystemComponent") -eq 1)
                        IsFramework       = $null
                    })
                    $appKey.Close()
                }
                $uninstallKey.Close()
            }
            $baseKey.Close()
        }
        catch {
            Write-Warning "Failed to read registry target $($target.Hive) ($($target.Arch)): $_"
        }
    }

    # 2. AppxPackage Scrape (Safe, Cmdlet-Aware)
    Write-Verbose "Scanning Appx packages..."
    
    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        
        try {
            if ($isAdmin) {
                $appxPackages = Get-AppxPackage -AllUsers -ErrorAction Stop
                $appxScope = "Machine (All Users)"
            } else {
                Write-Verbose "Running without Administrator rights. Appx packages limited to current user."
                $appxPackages = Get-AppxPackage -ErrorAction Stop
                $appxScope = "User"
            }

            foreach ($app in $appxPackages) {
                $installedSoftware.Add([PSCustomObject]@{
                    Name              = $app.Name
                    Version           = $app.Version
                    Publisher         = $app.Publisher
                    InstallDate       = $null # Appx doesn't expose standard install dates to this cmdlet
                    UninstallString   = $null # Removed fake string per critique
                    RegistryKeyName   = $null
                    AppxPackageName   = $app.PackageFullName
                    Source            = "Appx"
                    Scope             = $appxScope
                    Architecture      = $app.Architecture.ToString()
                    IsSystemComponent = $null
                    IsFramework       = $app.IsFramework
                })
            }
        }
        catch {
            Write-Warning "Failed to query Appx Packages: $_"
        }
    } else {
        Write-Verbose "Get-AppxPackage cmdlet not found. Skipping Appx scan (expected on Server Core)."
    }

    # Output the raw array (Deduplication / Filtering is left to the caller)
    $installedSoftware
}

function Get-NormalizedSoftwareName {
    #.SYNOPSIS
    # Simplifies software names to their core product identifier to prevent false positives from minor version or date updates.
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$Name
    )

    process {
        $cleanName = $Name

        # Remove Noise Words (version, release, Preview)
        $cleanName = $cleanName -replace '(?i)\b(version|release|preview|edition)\b', ' '

        # Remove Bitness Indicators (x64, x86, amd64, 64-bit, 32-bit)
        $cleanName = $cleanName -replace '(?i)\b(x64|x86|amd64|64-?bit|32-?bit)\b', ' '

        # Replace Dates (YYYYMMDD, YYYY-MM-DD, MM/DD/YYYY) with DATE
        # Matches formats like 20240203, 01/28/2016, 2024-02-03
        $cleanName = $cleanName -replace '\b(20\d{2}[-./]?\d{2}[-./]?\d{2}|\d{2}[-./]\d{2}[-./]20\d{2})\b', 'DATE'

        # Replace 20YYMMDD with DATE even without surounding word limits (BUT NOT inside biger numbers)
        $cleanName = $cleanName -replace '([^\d])20\d{2}[-./]?\d{2}[-./]?\d{2}([^\d])', '$1DATE$2'

        # Replace Minor Versions but keep Major (e.g., 4.6.2 -> 4.VER)
        # Looks for a number followed by one or more dot-number sequences
        $cleanName = $cleanName -replace '\b(\d+)\.\d+(\.\d+)*\b', '$1.VER'

        # Replace brackets and commas with spaces
        $cleanName = $cleanName -replace '[\(\)\{\}\[\],]', ' '

        # Clean up hanging dashes/dots often left behind by removed versions
        $cleanName = $cleanName -replace '\s-\s', ' '

        # Condense multiple spaces into a single space and trim edges
        $cleanName = $cleanName -replace '\s+', ' '
        
        return $cleanName.Trim()
    }
}

$installed=Get-InstalledSoftware

$filtered = ($installed | ?{
	-not(
		$_.Publisher -like '*Microsoft Windows*' `
		-or ($_.Publisher -like '*Microsoft*' -and ($_.name -match '^Microsoft (Visual C\+\+|Windows desktop runtime|.NET Host|.NET Runtime|Edge)(\b| |$)')) `
		-or ($_.Publisher -eq 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' -and $_.Source -eq 'appx')
	)
})

$names_of_inst_sw=($filtered.name | %{Get-NormalizedSoftwareName $_} | sort -unique)

$names_of_inst_sw|%{echo "$_ ~ $($env:computername)"}
}

```