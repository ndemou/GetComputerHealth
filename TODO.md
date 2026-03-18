# TODO

## Add a test that verifies the help-block of HealthTest- functions follows our standards

Also get more explicit about our standards. Both on formatting and meaning. I've seen GPT make a lot of mistakes. 
Considering one function at a time helped it a lot.

## Review the hundrends of warnings from Invoke-ScriptAnalyzer (and 3 errors)

See also : .\tests\script-analysis.ps1

## Automate tests in GitHub

ChatGPT said: GitHub Actions can run Windows PowerShell 5.1 by using the powershell shell (which invokes powershell.exe on Windows runners).
See also: https://docs.github.com/actions/automating-builds-and-tests/building-and-testing-powershell

## Use tags in HealthTest- function names 

E.g. "HealthTest-CheckSomething__sD-V__tS" means:
  - Only perform this test on a system(s) that is 
    domain joined(D) but not a VM (-V)
  - This test is of type(t) slow(S)
```
Possible systems: 
   D: domain joined 
   W: workstation 
   S: server 
   C: domain controller 
   H: hypervisor 
   V: virtual machine 
   L: laptop/mobile
Possible types: 
   S: Slow
   B: Relative (see below)
```
Then I can greatly simplify the main part of the code that execute the built in tests.

**About relative Tests**
relative tests don't produce absolute pass/fail results.
Rather, they warn for every funding as if it's a failure 
and the user is responsible to suppress findings that *are* accepted, thus establishing a baseline.
Examples of relative tests are those that list open ports or installed SW.
The first time a specific relative test is run it automatically 
supresses all findings (except if -DontRecordBaseline is passed)
and appends a line to Get-ComputerHealth.sigs-to-suppress.txt to
note that the first-time supression was performed.
E.g. for a function named HealthTest-CheckSomething__s_D-V__t_S
   `BASELINE_RECORDED_FOR: HealthTest-CheckSomething`

This automatic suppression allows developers of get computer health to add Relative tests without
anoying their users with new warnings. Code is also emmiting a Notice:
  `Automatically suppressed this finding from new test 'HealthTest-OpenPorts': Found unexpected open port TCP:3389`


## HealthTest-SysvolContentConsistency
The function HealthTest-SysvolContentConsistency calculates the size and file count of the entire `\\SYSVOL\...\Policies` tree across **all** Domain Controllers over the network. In a production environment with branch offices or many GPOs, this is dangerous. It generates massive WAN traffic. Since Health Tests are already running on every single DC you could in theory compute the hashes localy on each DC (and compute real hashes instead of the pseudo sigs that this function computes) and then exchange and compare them. This will be super fast even over WAN.


## Look at these Gemini suggestions

### 1. Minor Logical Errors (`Test-NetConnectionFast` & `TimeSync`)

**A. `Test-NetConnectionFast` (DNS ordering bug)**
The original code fetches all IP addresses and arbitrarily picks the first one or filters clumsily. If a host has IPv6 but the network doesn't route it, the test fails even if IPv4 works.

**The Fix: Enforce IPv4 and Registry-Based Time Checks**

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

**The Fix: **

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

##  Consider if the following health tests are useful (GPT inspired)
```
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
function Get-InstalledSW {
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
                    InstallDate       = $null # not exposed by Appx
                    UninstallString   = $null # not exposed by Appx
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

function HealthTest-InstalledSW {
    Get-InstalledSW | %{ 
        $normalizedName = Get-NormalizedSoftwareName $_.Name
        Log-Notice "Found this program installed: $normalizedName" -Comment "Full program name: $($_.Name); Publisher: $($_.Publisher); Installation Date: $($_.InstallDate)"
    }
}

```

## New test: Evaluate secure communication configurations

Most of the servers will emit these failures:
    > FAILURE: [337007c8] .NET 4.x (64-bit) expected Enabled; got SchUseStrongCrypto=1; SystemDefaultTlsVersions=<missing>
    >        Applies to: Client+Server.
    >        Key: HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319.
    > FAILURE: [9045cbcf] .NET 4.x (32-bit) expected Enabled; got SchUseStrongCrypto=1; SystemDefaultTlsVersions=<missing>
    >        Applies to: Client+Server.
    >        Key: HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319.

```
<#
.SYNOPSIS
Evaluates the configured state of secure communication protocols against
target security states.

.OUTPUTS
Produces a custom object for each evaluated configuration component:
  AuditType            : The category of the evaluation.
  Computer             : The local machine name.
  Protocol_Component   : The evaluated protocol or framework.
  CurrentState         : The active operational state.
  Source               : The origin of the current state.
  RecommendedState     : The target security state.
  Note                 : Context regarding the recommendation.
  Key                  : The evaluated registry path.
  EnabledRaw           : The raw numerical enabled value.
  DisabledByDefaultRaw : The raw numerical disabled value.

.DESCRIPTION
Reads configuration data for secure communication protocols and application
framework settings. The effective state accounts for explicit values and
default behaviors tied to the operating system version. Recommendations
reflect the capability of the host operating system to support specific
protocols. Read operations encountering access issues may result in
terminating errors.

.PARAMETER IncludeDotNetCheck
When set, also evaluates .NET framework cryptography settings
#>
function Get-SchannelProtocolState {
    [CmdletBinding()]
    param(
        [ValidateSet('Server','Client')] [string]$Role = 'Server',
        [string[]]$Protocol = @('SSL 3.0','TLS 1.0','TLS 1.1','TLS 1.2','TLS 1.3'),
        [switch]$IncludeDotNetCheck = $true
    )

    $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols'

    $v = [Environment]::OSVersion.Version
    $installType = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'InstallationType' -ErrorAction SilentlyContinue).InstallationType
    $isServer = $false
    if ($installType -like '*Server*') { $isServer = $true }

    $tls13Supported = $false
    if ($isServer) {
        if ($v.Major -ge 10 -and $v.Build -ge 20348) { $tls13Supported = $true }
    } else {
        if ($v.Major -ge 10 -and $v.Build -ge 22000) { $tls13Supported = $true }
    }

    function Get-EffectiveState {
        param([string]$KeyPath, [string]$ProtocolName)

        $enabled = $null
        $disabledByDefault = $null
        $src = 'OS default'
        $state = 'Enabled'

        if (Test-Path $KeyPath) {
            try {
                $props = Get-ItemProperty -Path $KeyPath -ErrorAction Stop
                if ($null -ne $props.Enabled) { $enabled = [uint32]$props.Enabled }
                if ($null -ne $props.DisabledByDefault) { $disabledByDefault = [uint32]$props.DisabledByDefault }
            } catch {
            }
        }

        if ($null -ne $enabled) {
            if ($enabled -eq 0) { $state = 'Disabled'; $src = 'Enabled=0' }
            else { $state = 'Enabled'; $src = 'Enabled=1/FFFF' }
        }
        elseif ($null -ne $disabledByDefault) {
            if ($disabledByDefault -eq 1) { $state = 'Disabled'; $src = 'DisabledByDefault=1' }
            else { $state = 'Enabled'; $src = 'DisabledByDefault=0' }
        }
        else {
            if ($ProtocolName -in 'SSL 3.0','TLS 1.0','TLS 1.1') { $state = 'Disabled'; $src = 'OS default' }
            else { $state = 'Enabled'; $src = 'OS default' }
        }

        ,@($state, $src, $enabled, $disabledByDefault)
    }

    foreach ($proto in $Protocol) {
        $key = Join-Path (Join-Path $base $proto) $Role
        $eff = Get-EffectiveState -KeyPath $key -ProtocolName $proto
        $current = $eff[0]; $source = $eff[1]; $enabledRaw = $eff[2]; $disabledRaw = $eff[3]

        $rec = 'No requirement'
        $note = ''
        $fix = $null

        if ($proto -in 'SSL 3.0','TLS 1.0','TLS 1.1') {
            $rec = 'Disabled'
            $note = 'Disable legacy protocol.'
            $fix = @"
Set: Enabled=0 (DWORD) and DisabledByDefault=1 (DWORD)
Example:
  New-Item -Path '$key' -Force | Out-Null
  New-ItemProperty -Path '$key' -Name Enabled -PropertyType DWord -Value 0 -Force | Out-Null
  New-ItemProperty -Path '$key' -Name DisabledByDefault -PropertyType DWord -Value 1 -Force | Out-Null
"@
        }
        elseif ($proto -eq 'TLS 1.2') {
            $rec = 'Enabled'
            $note = 'Keep TLS 1.2 enabled.'
            $fix = @"
Set: Enabled=1 (DWORD) and DisabledByDefault=0 (DWORD)
Example:
  New-Item -Path '$key' -Force | Out-Null
  New-ItemProperty -Path '$key' -Name Enabled -PropertyType DWord -Value 1 -Force | Out-Null
  New-ItemProperty -Path '$key' -Name DisabledByDefault -PropertyType DWord -Value 0 -Force | Out-Null
"@
        }
        elseif ($proto -eq 'TLS 1.3') {
            if ($tls13Supported) {
                $rec = 'Enabled'
                $note = 'OS supports TLS 1.3; enable it.'
                $fix = @"
Set: Enabled=1 (DWORD) and DisabledByDefault=0 (DWORD)
Example:
  New-Item -Path '$key' -Force | Out-Null
  New-ItemProperty -Path '$key' -Name Enabled -PropertyType DWord -Value 1 -Force | Out-Null
  New-ItemProperty -Path '$key' -Name DisabledByDefault -PropertyType DWord -Value 0 -Force | Out-Null
"@
            } else {
                $rec = 'No requirement'
                $note = 'TLS 1.3 not required on this OS.'
                $fix = $null
            }
        }

        [pscustomobject]@{
            AuditType  = 'Schannel'
            AppliesTo  = $Role
            Name       = "$proto"
            Current    = $current
            Expected   = $rec
            Evidence   = "Source=$source"
            Key        = $key
            EnabledRaw = $enabledRaw
            DisabledByDefaultRaw = $disabledRaw
            Note       = $note
            Fix        = $fix
        }
    }

    if ($IncludeDotNetCheck) {
        $dotNetPaths = @(
            @{ Arch = '64-bit'; Path = 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319' },
            @{ Arch = '32-bit'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319' }
        )

        foreach ($d in $dotNetPaths) {
            $path = $d.Path
            $arch = $d.Arch

            $strongCrypto = $null
            $systemTls = $null

            if (Test-Path $path) {
                $props = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
                if ($null -ne $props.SchUseStrongCrypto) { $strongCrypto = $props.SchUseStrongCrypto }
                if ($null -ne $props.SystemDefaultTlsVersions) { $systemTls = $props.SystemDefaultTlsVersions }
            }

            $scText = '<missing>'
            $stText = '<missing>'
            if ($null -ne $strongCrypto) { $scText = [string]$strongCrypto }
            if ($null -ne $systemTls) { $stText = [string]$systemTls }

            $isCompliant = $false
            if ($strongCrypto -eq 1 -and $systemTls -eq 1) { $isCompliant = $true }

            $fix = @"
New-Item -Path '$path' -Force | Out-Null
New-ItemProperty -Path '$path' -Name SchUseStrongCrypto -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path '$path' -Name SystemDefaultTlsVersions -PropertyType DWord -Value 1 -Force | Out-Null
"@

            [pscustomobject]@{
                AuditType = '.NET'
                AppliesTo = 'Client+Server'
                Name      = ".NET 4.x ($arch)"
                Current   = if ($isCompliant) { 'Enabled' } else { 'Noncompliant' }
                Expected  = 'Enabled'
                Evidence  = "SchUseStrongCrypto=$scText; SystemDefaultTlsVersions=$stText"
                Key       = $path
                Note      = 'Both DWORD values must be 1.'
                Fix       = $fix
            }
        }
    }
}

<#
.SYNOPSIS
Evaluates secure communication configurations against target states.
#>
function HealthTest-SchannelCompliance {
    [CmdletBinding()]
    param()

    foreach ($role in @('Server','Client')) {
        $results = Get-SchannelProtocolState -Role $role -IncludeDotNetCheck:$false

        foreach ($item in $results) {
            if ($item.Expected -eq 'No requirement') { continue }

            $subject = "Schannel $($item.Name) $role"

            if ($item.Current -eq $item.Expected) {
                log-pass "$subject = $($item.Current)" -comment "Evidence: $($item.Evidence). Key: $($item.Key)."
            }
            else {
                $raw = @()
                if ($null -ne $item.EnabledRaw) { $raw += "Enabled=$($item.EnabledRaw)" }
                if ($null -ne $item.DisabledByDefaultRaw) { $raw += "DisabledByDefault=$($item.DisabledByDefaultRaw)" }
                $rawText = ''
                if ($raw.Count -gt 0) { $rawText = " Raw: " + ($raw -join ', ') + "." }

                $msg = "$subject expected $($item.Expected); got $($item.Current)"
                $c = "Evidence: $($item.Evidence).$rawText`nKey: $($item.Key).`nNote: $($item.Note)"
                if ($item.Fix) { $c = $c + "`n`nFix (example):`n$($item.Fix)" }
                log-failure $msg -comment $c
            }
        }
    }

    $dotNet = Get-SchannelProtocolState -Role 'Server' -IncludeDotNetCheck:$true | Where-Object { $_.AuditType -eq '.NET' }
    foreach ($item in $dotNet) {
        $subject = "$($item.Name)"
        if ($item.Current -eq $item.Expected) {
            log-pass "$subject = Enabled" -comment "Applies to: $($item.AppliesTo). Evidence: $($item.Evidence). Key: $($item.Key)."
        }
        else {
            $msg = "$subject expected Enabled; got $($item.Evidence)"
            $c = "Applies to: $($item.AppliesTo).`nKey: $($item.Key).`nNote: $($item.Note)`n`nFix (copy/paste):`n$($item.Fix)"
            log-failure $msg -comment $c
        }
    }
}
```


## Other

  - Allow users to install somewhere besides C:\IT
    Also, maybe config files should be in ProgramData instead of c:\IT\config
    (but not readable by anyone except Admins)

  - Implement -RemoveWhitelisting -ComputerName -Signature

  - Some health tests like these:
      - HealthTest-UnexpectedListeningPorts
      - HealthTest-NonMicrosoftServices
      - HealthTest-InstalledRolesFeatures
      - HealthTest-InstalledSW (TODO)
      - HealthTest-EnabledScheduledTasks (TODO)(I should include a hash of the action and the file(s) it runs)
    are only meaningful if you have first established a baseline by
    running them on an known good state. I should have an option
    to exclude them from running (maybe -ExcludeTestsThatNeedBaseline)

  - I could be monitoring the CPU and memory pressure *while* running all/most 
    other tests. This has pros and cons so I can make it a separate check 
    (e.g. some tests *do* streess the CPU (maybe RAM also). I wonder if I could
    tag them so that they do not run while measuring CPU or RAM)

  - Also measure CPU, board temperature.

  - -AddWhitelisting should be deleting any existing line for the signature.
    Note that even without this fix, everything works as it should 
    (because the last config line wins), but it's confusing to have
    conflicting lines.

  - Use [string[]]$Arg1 everywhere for arguments that expect string arrays
    This style works like this:
         -Arg1 test,foo,bar             --> @("test","foo","bar")
         -Arg1 test -Arg1 foo -Arg1 bar --> @("test","foo","bar")
         -Arg1 @("test","foo","bar")    --> @("test","foo","bar")
         -Arg1 "test,foo,bar"           --> "test,foo,bar" 
         -Arg1 "test foo bar"           --> "test foo bar" 
    If I don't expect the values to have spaces or commas I could fix the last 2 cases manually

  - `Start-HealthTestVeeamRecentBackupsExist` expects to read a text 
    in clear text from a file. Maybe use credentials manager (note that
	the credentials manager stores passwords per user which complicates
	stuff -- you run it from your account and works but not from SYSTEM)
