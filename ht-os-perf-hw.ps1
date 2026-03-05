<#
OS Performance & Hardware
#>

function HealthTest-DisksHaveFreeSpace {
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $d.IsReady) { continue }
        $t = $d.DriveType.ToString()
        if (@('Fixed','Removable','Network') -notcontains $t) { continue }
        # emmits Log-failure/warning/pass
        $out = Test-DiskHasFreeSpace -PathOrDrive $d.Name
        if ($out.level -eq 'Error') {
            Write-Warning "[failure] Disk is critically low on free space`n$out"
        } elseif ($out.level -eq 'Warning') {
            Write-Warning "[warning] Disk is low on free space`n$out"
        } else {
            Write-Warning "[pass] Disk has enough free space`n$out"
        }
    }
}


function HealthTest-RamPressure {
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [ValidateRange(1,2147483647)][int]$Samples=1,
    [ValidateRange(0,3600000)][int]$SampleDelayMs=500
  )

  $os = Get-CimInstance Win32_OperatingSystem
  $totalMB = [math]::Round($os.TotalVisibleMemorySize/1024,1)
  if ($totalMB -le 0) { Write-Warning "[failure] Total visible memory is 0 MB; cannot compute free %."; return }

  function Get-AvailMB {
    try {
      $c = (Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples.CookedValue
      if ($null -eq $c) { throw "No counter value." }
      [math]::Round([double]$c,1)
    } catch { return $null }
  }

  $vals = @()
  for ($i=0; $i -lt $Samples; $i++) {
    $v = Get-AvailMB
    if ($null -eq $v) { Write-Warning "[warning] Skipped a failed \\Memory\\Available MBytes read (sample $($i+1)/$Samples)."; continue }
    $vals += $v
    if (($i+1) -lt $Samples -and $SampleDelayMs) { Write-Verbose "waiting $SampleDelayMs ms"; Start-Sleep -Milliseconds $SampleDelayMs }
  }
  if ($vals.Count -eq 0) { Write-Warning "[failure] Failed to sample available memory."; return }

  $sorted = @($vals | Sort-Object)
  $n = $sorted.Length
  $mid = [int]($n/2)
  $medianFree = if ($n % 2) { [double]$sorted[$mid] } else { ([double]$sorted[$mid-1] + [double]$sorted[$mid]) / 2 }
  $freePcnt = [math]::Round(($medianFree*100)/$totalMB,1)

  if ($Samples -eq 1 -and $freePcnt -lt 10) {
    if ($SampleDelayMs) { Start-Sleep -Milliseconds $SampleDelayMs }
    $v = Get-AvailMB
    if ($null -ne $v) {
      $medianFree = [math]::Round((([double]$medianFree + [double]$v)/2),1)
      $freePcnt = [math]::Round(($medianFree*100)/$totalMB,1)
    }
  }

  if ($freePcnt -lt 2) { Write-Warning "[failure] Free RAM under 2%`n$freePcnt% free RAM"; return }
  elseif ($freePcnt -lt 5) { Write-Warning "[warning] Free RAM between 2 and 5%`n$freePcnt% free RAM"; return }
  elseif ($freePcnt -lt 10) { Write-Warning "[notice] Free RAM between 5 and 10%`n$freePcnt% free RAM"; return }
  Write-Warning "[pass] Free RAM at $($freePcnt)%"
  return
}


function HealthTest-TimeSyncPolicy {
<#
.SYNOPSIS
Validates that the host's time sync topology matches AD/NTP best practices.

.DESCRIPTION
Detects server role via Win32_ComputerSystem.DomainRole:
- PDC Emulator: should sync from an external NTP source (or hypervisor if intentionally configured);
  flags Local CMOS or domain hierarchy sources as failures.
- Other DCs: should sync from domain hierarchy.
- Member servers: should sync from domain hierarchy if domain-joined; otherwise any source is OK.
Also notes if the VMICTimeProvider (hypervisor sync) is enabled on a PDC.

.OUTPUTS
Log-objects regarding findings.

.NOTES
Reads w32tm /query /source and registry VMICTimeProvider; uses Log-pass/Failure/Notice.
#>
    [CmdletBinding()]
    param()

    Write-Verbose "Starting HealthTest-TimeSyncPolicy..."
    $evidences = @()

    # Checks if the provided time source matches a known Domain Controller
    # (from the provided list)
    # or implies the internal AD hierarchy based on the domain suffix.
    function Is-DCSource([string]$timeSource, [string[]]$dcNameSet, [string]$domainName) {
        if (-not $timeSource) { return $false }

        $normalizedSource = $timeSource.Trim().ToLowerInvariant()

        # Check if source is an IP address
        if ($normalizedSource -match '^\d{1,3}(\.\d{1,3}){3}$') { return $false }

        if ($dcNameSet.Count -gt 0) {
            if ($dcNameSet -contains $normalizedSource) { return $true }

            $shortHostName = ($normalizedSource -replace '[.].*')
            if ($dcNameSet -contains $shortHostName) { return $true }
        }

        if ($domainName) {
            $domainNameLower = $domainName.ToLowerInvariant()
            if ($normalizedSource -like "*.$domainNameLower") { return $true }
        }

        $false
    }

    # Checks if the time source matches common public NTP providers
    # (Google, Microsoft, NTP Pool)
    # to distinguish them from internal AD sources.
    function Looks-ExternalNtp {
        param(
            [string]$timeSource,
            [string[]]$externalDomains = @('*.pool.ntp.org', '*time.google.com*', '*time.windows.com*')
        )
        if (-not $timeSource) { return $false }
        $sourceLower = $timeSource.ToLowerInvariant()
        foreach ($pattern in $externalDomains) {
            if ($sourceLower -like $pattern.ToLowerInvariant()) {
                return $true
            }
        }
        $false
    }

    # --- Helper: Robust DC Validator using DNS SRV ---
    function Get-DnsDomainControllers {
        param($DomainName)
        $names = @()
        try {
            $records = Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$DomainName" -Type SRV -ErrorAction Stop |
                        Where-Object { $_.Type -eq 'SRV' }

            foreach ($rec in $records) {
                if ($rec.NameTarget) {
                    $fqdn = $rec.NameTarget.ToLowerInvariant().TrimEnd('.')
                    $short = ($fqdn -split '\.')[0]
                    $names += $fqdn
                    $names += $short
                }
            }
        }
        catch {
            Write-Verbose "DNS SRV lookup failed: $_"
        }
        return ($names | Select-Object -Unique)
    }

    # --- Step 1: Role Detection ---
    $compSystem = Get-CimInstance Win32_ComputerSystem
    $domainRole = $compSystem.DomainRole
    $domainName = $compSystem.Domain

    $isHostDC = ($domainRole -in 4, 5)
    $isHostDomainJoined = ($domainRole -in 1, 3, 4, 5)
    $isHostPDC = $false
    $dcNameSet = @()

    $msg = "Role Detection: DomainJoined=$isHostDomainJoined, IsDC=$isHostDC (Role ID: $domainRole), Domain=$domainName"
    Write-Verbose $msg
    $evidences += $msg

    if ($isHostDomainJoined -and $domainName) {
        $dcNameSet = Get-DnsDomainControllers -DomainName $domainName
        $msg = "Found $($dcNameSet.Count) known DC names: $($dcNameSet -join ', ')"
        Write-Verbose $msg
        $evidences += $msg

        if ($isHostDC) {
            try {
                $pdcRecord = Resolve-DnsName -Name "_ldap._tcp.pdc._msdcs.$domainName" -Type SRV -ErrorAction Stop |
                             Where-Object { $_.Type -eq 'SRV' }

                if ($pdcRecord.NameTarget) {
                    $isHostPDC = (($pdcRecord.NameTarget -replace '[.].*') -eq $env:COMPUTERNAME)
                    $msg = "PDC Detection: IsPDC=$isHostPDC (PDC Record: $($pdcRecord.NameTarget))"
                    Write-Verbose $msg
                    $evidences += $msg
                }
            }
            catch {
                Write-Warning "[warning] HealthTest-TimeSyncPolicy: Unable to determine PDC Role via DNS SRV record: $_"
            }
        }
    }

    # --- Step 2: Registry Type ---
    $w32TimeParamsRegistryPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
    $timeSyncType = (Get-ItemProperty $w32TimeParamsRegistryPath -ErrorAction SilentlyContinue).Type
    if (-not $timeSyncType) { $timeSyncType = '' }

    $msg = "Registry Configuration: Type='$timeSyncType'"
    Write-Verbose $msg
    $evidences += $msg

    # --- Step 3: Current Source ---
    $currentTimeSource = (w32tm /query /source 2>$null).Trim()

    $msg = "Current Time Source: '$currentTimeSource'"
    Write-Verbose $msg
    $evidences += $msg

    # --- Step 4: VMIC Provider ---
    $vmicProviderRegistryPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\VMICTimeProvider'
    $vmicRegistrySettings = Get-ItemProperty -Path $vmicProviderRegistryPath -ErrorAction SilentlyContinue
    $vmicEnabled = ($vmicRegistrySettings -and ($vmicRegistrySettings.Enabled -ne 0) -and ($vmicRegistrySettings.InputProvider -ne 0))

    $isActiveVMIC = ($currentTimeSource -eq 'VM IC Time Synchronization Provider')
    $isActiveCMOS = ($currentTimeSource -eq 'Local CMOS Clock')

    $msg = "Provider Status: VMIC_Active=$isActiveVMIC, CMOS_Active=$isActiveCMOS, VMIC_RegEnabled=$vmicEnabled"
    Write-Verbose $msg
    $evidences += $msg

    # --- Step 5: Only for domain joined except PDC: is source a DC? ---
    $isSourceDC = $null
    if ($isHostDomainJoined -and (-not $isHostPDC)) {
      $isSourceDC = (Is-DCSource $currentTimeSource $dcNameSet $domainName)
      if ($isSourceDC) {
        $msg = "$currentTimeSource is a known DC"
      } else {
        $msg = "$currentTimeSource is NOT a known DC"
      }
      Write-Verbose $msg
      $evidences += $msg
    }

    # --- Step 6: Logic Evaluation ---

    # Special case for domains
    if ($isSourceDC) {
      # Syncing from myself
      $cleanSource = $currentTimeSource.ToLowerInvariant() -replace '\.$','' # remove trailing dot if any
      if ($cleanSource -match "^$($env:COMPUTERNAME.ToLowerInvariant())(\.|$)") {
          Write-Warning "[failure] $("Misconfiguration: syncing from myself.")`n$(($evidences -join "`r`n"))"
      }
      # Confusion: NTP from a DC
      if ($timeSyncType -eq 'NTP' -and $isSourceDC) {
        $msg = "Confusing setup: a specific DC is manually set as the time source. What if this DC goes down or if another one is better (e.g. on the same LAN)?"
        Write-Verbose $msg
        $evidences += $msg
      }
    }

    $evidenceString = $evidences -join "`r`n"
    if ($isHostPDC) {
        # ---- CHECKS FOR PDCs ---
        if ($timeSyncType -eq 'NT5DS') {
            Write-Warning "[failure] $("PDC time syncing type is NT5DS, this is only valid if this is a subdomain and you are syncing from the higher domain")`n$($evidenceString)"
        }
        elseif ($timeSyncType -notin 'NTP', 'AllSync') {
            Write-Warning "[failure] $("PDC time syncing type is '$timeSyncType' instead of 'NTP' or 'AllSync'.")`n$($evidenceString)"
        }
        elseif ($isActiveCMOS) {
            Write-Warning "[failure] $("PDC currently reports 'Local CMOS Clock'.")`n$($evidenceString)"
        }
        elseif ($isActiveVMIC) {
            Write-Warning "[failure] $("PDC is currently syncing from hypervisor (Source='$currentTimeSource').")`n$($evidenceString)"
        }
        else {
            if ($vmicEnabled) {
                if ($isHostPDC) {
                    $comment = "Since this is a PDC consider disabling VM time sync for strict NTP-only behavior."
                }
                else {
                    $comment = ""
                }
                Write-Warning "[notice] $("VMICTimeProvider is enabled, but not used.")`n$($comment)"
            }
            if (Looks-ExternalNtp $currentTimeSource) {
                Write-Warning "[pass] PDC emulator time syncing looks correct (Type=$timeSyncType, Source='$currentTimeSource')."
            }
            else {
                Write-Warning "[notice] PDC emulator Type=$timeSyncType, Source='$currentTimeSource' (not sure if this is a good external NTP)."
            }
        }
    }
    elseif ($isHostDC) {
        # ---- CHECKS FOR DCs (except PDCs) ---
        if ($timeSyncType -ne 'NT5DS') {
            Write-Warning "[failure] $("DC time syncing type is '$timeSyncType' (expected 'NT5DS').")`n$($evidenceString)"
        }
        elseif ($isActiveVMIC) {
            Write-Warning "[failure] $("DC is currently syncing from hypervisor (Source='$currentTimeSource').")`n$($evidenceString)"
        }
        elseif ($isActiveCMOS) {
            Write-Warning "[failure] $("DC reports 'Local CMOS Clock'.")`n$($evidenceString)"
        }
        elseif (Looks-ExternalNtp $currentTimeSource) {
            Write-Warning "[failure] $("DC appears to be using an external NTP source ('$currentTimeSource') instead of domain hierarchy (NT5DS).")`n$($evidenceString)"
        }
        elseif ($isSourceDC) {
            Write-Warning "[pass] DC time syncing is OK (Type=$timeSyncType, Source='$currentTimeSource')."
        }
        else {
            Write-Warning "[failure] $("DC is not clearly syncing from domain hierarchy (Type=$timeSyncType, Source='$currentTimeSource').")`n$($evidenceString)"
        }
    }
    elseif ($isHostDomainJoined) {
        # ---- CHECKS FOR Domain Joined servers except DCs, PDCs ---
        if ($timeSyncType -ne 'NT5DS') {
            Write-Warning "[failure] $("Domain member time syncing type is '$timeSyncType' instead of 'NT5DS'.")`n$($evidenceString)"
        }
        elseif ($isActiveVMIC) {
            Write-Warning "[failure] $("Domain member is currently syncing from hypervisor (Source='$currentTimeSource').")`n$($evidenceString)"
        }
        elseif ($isActiveCMOS) {
            if (Test-IsLaptopOrMobile) {
                Write-Warning "[warning] This domain member (likely a laptop) is not syncing time from domain (Source='Local CMOS Clock')."
            }
            else {
                Write-Warning "[failure] $("Domain member is not syncing time from domain (Source='Local CMOS Clock').")`n$($evidenceString)"
            }
        }
        elseif (Looks-ExternalNtp $currentTimeSource) {
            Write-Warning "[failure] $("Domain member appears to be using an external NTP source ('$currentTimeSource') instead of domain hierarchy.")`n$($evidenceString)"
        }
        elseif ($isSourceDC) {
            Write-Warning "[pass] Domain member is syncing via domain hierarchy (Type=$timeSyncType, Source='$currentTimeSource')."
        }
        else {
            Write-Warning "[failure] $("Domain member is not clearly syncing via domain hierarchy (Type=$timeSyncType, Source='$currentTimeSource').")`n$($evidenceString)"
        }
    }
    else {
        # ---- CHECKS FOR Standalone PCs ---
        if ($currentTimeSource -eq 'Local CMOS Clock' -or -not $currentTimeSource) {
            Write-Warning "[failure] $("Standalone machine is not syncing time (Source='$currentTimeSource').")`n$($evidenceString)"
        }
        elseif ($isActiveVMIC) {
            Write-Warning "[pass] Standalone machine is syncing via Hypervisor/VM Tools."
        }
        else {
            # Assume anything else is a valid NTP server (IP or DNS name)
            Write-Warning "[pass] Standalone machine is syncing from external source '$currentTimeSource'."
        }
    }
}

<#
.SYNOPSIS
Measures time offset vs. a time source and compares against thresholds.

.DESCRIPTION
By default targets the current w32time Source (from w32tm /query /status), unless -AlwaysUseRef
is specified, in which case it targets -RefTimeServer. Uses w32tm /stripchart with 1 sample,
parses the offset in seconds, and evaluates against -WarnOffsetSeconds and -FailOffsetSeconds.

.PARAMETER WarnOffsetSeconds
Warning threshold for absolute offset seconds. Default 2.

.PARAMETER FailOffsetSeconds
Failure threshold for absolute offset seconds. Default 15.

.PARAMETER RefTimeServer
Fallback/explicit NTP server to test when AlwaysUseRef or no usable Source. Default time.windows.com.

.PARAMETER AlwaysUseRef
Force testing against RefTimeServer instead of the current Source.

.EXAMPLE
HealthTest-TimeSyncAccuracy
Uses the current time source and warns/fails on excessive offset.

.EXAMPLE
HealthTest-TimeSyncAccuracy -RefTimeServer 'pool.ntp.org' -AlwaysUseRef -WarnOffsetSeconds 1 -FailOffsetSeconds 5
Tests against a specific NTP pool with stricter thresholds.
#>
function HealthTest-TimeSyncAccuracy {
  param(
    [int]$WarnOffsetSeconds=15,
    [int]$FailOffsetSeconds=30,
    [string]$RefTimeServer='time.windows.com',
    [switch]$AlwaysUseRef
  )

  $source = ''
  try {
    $srcOut = (w32tm /query /source 2>&1) -join "`n"
    if ($LASTEXITCODE -eq 0) {
      $source = ($srcOut -split "`r?`n")[0].Trim()
    }
  } catch {}

  $target = $RefTimeServer
  if (-not $AlwaysUseRef -and $source) {
    $src1 = ($source -split ',',2)[0].Trim()
    $isNonHost = $src1 -match '(?i)(free[-\s]?running|local\s+(cmos|rtc)|vm\s+ic|hyper[-\s]?v|unsynchronized|no\s+source|local\s+clock)'
    $looksIPv4 = $src1 -match '^(?:\d{1,3}\.){3}\d{1,3}$'
    $looksName = $src1 -match '^[A-Za-z0-9][A-Za-z0-9\-\.]*[A-Za-z0-9]$'
    $looksIPv6 = $src1 -match '^[\[\]0-9A-Fa-f:]+$'
    if (($looksIPv4 -or $looksName -or $looksIPv6) -and -not $isNonHost) { $target = $src1 }
  }

  $sc = (w32tm /stripchart /computer:$target /dataonly /samples:2 2>&1) -join "`n"
  $exit = $LASTEXITCODE
  if ($exit -ne 0) {
    $hex = '0x{0:X}' -f ($exit -band 0xFFFFFFFF)
    if ($target -ne $RefTimeServer) {
        Write-Warning "[notice] Failed to test time sync via $target, retrying with $RefTimeServer`nStripchart to $target failed with error $hex"
        # retry
        $sc = (w32tm /stripchart /computer:$RefTimeServer /dataonly /samples:2 2>&1) -join "`n"
        $exit = $LASTEXITCODE
        if ($exit -ne 0) {
          $hex = '0x{0:X}' -f ($exit -band 0xFFFFFFFF)
          Write-Warning "[warning] Failed to test time sync either via $target or via $RefTimeServer`nStripchart to $RefTimeServer failed with error $hex"
          return
        }
        $target = $RefTimeServer
    } else {
        Write-Warning "[warning] Failed to test time sync`nStripchart to $target failed with error $hex"
        return
    }
  }

  $m = [regex]::Match($sc,'([-+]?\d+(?:[.,]\d+)?)s')
  if (-not $m.Success) {
    Write-Warning "[warning] Failed to test time sync`nCould not parse offset from stripchart to $target"
    return
  }

  $valStr = $m.Groups[1].Value.Replace(',', '.')
  $offsetSec = [double]::Parse($valStr, [System.Globalization.CultureInfo]::InvariantCulture)
  $abs = [math]::Abs($offsetSec)
  $ok = $true

  if ($abs -ge $FailOffsetSeconds) {
    Write-Warning "[failure] $("Time offset too high")`n$(("{0} s exceeds {1} s (2-samples)" -f $offsetSec,$FailOffsetSeconds))"
    $ok = $false
  } elseif ($abs -ge $WarnOffsetSeconds) {
    Write-Warning "[warning] $("Time offset rather high")`n$(("{0} s exceeds {1} s (2-samples)" -f $offsetSec,$WarnOffsetSeconds))"
    $ok = $false
  }

  if ($ok) {
    Write-Warning ("[pass] Time OK (1-sample); source: {0}; target: {1}; offset: {2} s" -f $source,$target,$offsetSec)
  }
}

<#
.SYNOPSIS
Detects whether a reboot is pending on this host.

.DESCRIPTION
Checks common reboot indicators:
- CBS: HKLM\...\Component Based Servicing\RebootPending
- Windows Update: HKLM\...\WindowsUpdate\Auto Update\RebootRequired
- Pending file rename operations in Session Manager
Emits Log-Notice if a reboot is pending; Log-pass otherwise.

.EXAMPLE
if (-not (HealthTest-PendingReboot)) { 'Schedule a reboot.' }
#>
function HealthTest-PendingReboot {
    $pending = $false
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending = $true }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending = $true }
    $pfr = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
    if ($pfr -and $pfr.PendingFileRenameOperations) {write-debug "Found entries in HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations (if you are not sure what this means, you can safely ignore it)"}
    if ($pending) { Write-Warning "[notice] Windows need a reboot to apply some changes"; return}
    Write-Warning "[pass] No pending reboot indicators"
}

<#
.SYNOPSIS
Flags stale Windows Update posture based on last successful install date.

.DESCRIPTION
Determines last successful installation via registry
(HKLM:\...\WindowsUpdate\Auto Update\Results\Install\LastSuccessTime). If unavailable,
falls back to latest HotFix InstalledOn. Compares age in days to Warn/Fail thresholds.

.PARAMETER WarnDays
Warn when last success is >= this many days. Default 30.

.PARAMETER FailDays
Fail when last success is >= this many days. Default 45.

.OUTPUTS
[bool] $true when update age < WarnDays; $false otherwise. Emits messages with the date.

.EXAMPLE
HealthTest-UpdateAge -WarnDays 21 -FailDays 35
#>
function HealthTest-UpdateAge {
    param([int]$WarnDays=30,[int]$FailDays=45)
    $lastUpdateDate = $null
    $reg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Install' -ErrorAction SilentlyContinue
    if ($reg -and $reg.LastSuccessTime) { $lastUpdateDate = [datetime]::Parse($reg.LastSuccessTime) }
    if (-not $lastUpdateDate) {
      $hf = Get-HotFix -ErrorAction SilentlyContinue | ?{$_.InstalledOn} | Sort-Object InstalledOn -Descending | Select-Object -First 1
      if ($hf -and $hf.InstalledOn) { $lastUpdateDate = $hf.InstalledOn }
    }
    if (-not $lastUpdateDate) { Write-Warning "[warning] Could not determine last successful Windows Update installation (normal only for a fresh windows installation)"; return}
    $age = (Get-Date) - $lastUpdateDate
    if ($age.Days -ge $FailDays) { Write-Warning "[failure] Too many days since the last successful Windows Update installation`n$($age.Days)d ago ($lastUpdateDate)"; return }
    if ($age.Days -ge $WarnDays) { Write-Warning "[warning] Several days since the last successful Windows Update installation`n$($age.Days)d ago ($lastUpdateDate)"; return }
    Write-Warning "[pass] We have a recent successful installation of a Windows Update ($($age.Days)d ago at $lastUpdateDate)"
}

<#
.SYNOPSIS
Checks Microsoft Defender signature freshness and reports status.

.DESCRIPTION
Reads Get-MpComputerStatus and compares AntispywareSignatureAge and AntivirusSignatureAge
to thresholds. Fails when either age >= FailSigAgeDays; warns when either >= WarnSigAgeDays.
On success, reports current AV signature version.

.PARAMETER WarnSigAgeDays
Warn threshold for signature age (days). Default 1.

.PARAMETER FailSigAgeDays
Fail threshold for signature age (days). Default 7.

.OUTPUTS
[bool] $true if signatures are fresh; $false otherwise. Emits messages.

.EXAMPLE
HealthTest-DefenderStatus -WarnSigAgeDays 2 -FailSigAgeDays 5
#>
function HealthTest-DefenderStatus {
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
      Write-Warning "[pass] Defender signatures fresh (AV=$($s.AntivirusSignatureVersion))"
    } else {
    }
}

<#
.SYNOPSIS
Alerts on soon-to-expire or expired machine certificates (LocalMachine\My).

.DESCRIPTION
Enumerates certificates under Cert:\LocalMachine\My and compares NotAfter with now.
Emits failures for expired or within -FailDays, warnings within -WarnDays, and success otherwise.

.PARAMETER WarnDays
Warn when expiration is within this many days. Default 60.

.PARAMETER FailDays
Fail when expiration is within this many days. Default 30.

.OUTPUTS
[bool] $true if no certs expire within WarnDays; $false on any warning/failure or errors.

.EXAMPLE
HealthTest-CertExpiry -WarnDays 90 -FailDays 21
#>
function HealthTest-CertExpiry {
    param([int]$WarnDays=60,[int]$FailDays=30)
    $now = Get-Date
    $certs = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue
    $problem_found = $false
    if (-not $certs) { Write-Warning "[info] No certificates in LocalMachine\My"; return }
    $fail = @(); $warn = @()
    foreach ($c in $certs) {
      $days = ($c.NotAfter - $now).TotalDays
      if ($days -le -60) { $warn += "$($c.Subject) :: expired long time ago $($c.NotAfter)" }
      elseif ($days -le -1) { $fail += "$($c.Subject) :: expired recently $($c.NotAfter)" }
      elseif ($days -eq 0) { $fail += "$($c.Subject) :: expires today $($c.NotAfter)" }
      elseif ($days -le $FailDays) { $fail += "$($c.Subject) :: will expire soon, at $($c.NotAfter)" }
      elseif ($days -le $WarnDays) { $warn += "$($c.Subject) :: will expire within $WarnDays, at $($c.NotAfter)" }
    }
    if ($problem_found) {return}
    Write-Warning "[pass] No certificates expiring within $WarnDays days"
}

# TODO: consolidate this and HealthTest-ScheduledTasksLastResult
# I think the later seems does more robust detection of issues based on Last Result
<#
.SYNOPSIS
Health check for non-Microsoft scheduled tasks (failures and missed runs).
.DESCRIPTION
Enumerates scheduled tasks excluding Microsoft/Windows built-ins and some noisy patterns. For each
task, flags non-success LastTaskResult values and any NumberOfMissedRuns > 0. Emits Log-Warning
entries with compact task details and returns $false if any problems are found; otherwise reports OK.
.OUTPUTS
[bool] $true if all checked tasks are healthy; $false if any failures/missed runs or on errors.
.EXAMPLE
HealthTest-ScheduledTasks
.NOTES
Uses Convert-TaskResultCode and Get-ScheduledTaskDeepInfo.
#>
function HealthTest-ScheduledTasks {
    $task_name_paterns_to_ignore = @(
      'OneDrive Per-Machine Standalone Update Task*',
      'OneDrive Reporting Task*',
      'OneDrive Standalone Update*',
      'Office Feature Updates*',
      'Firefox Background Update*',
      'Firefox Default Browser Agent*',
      'Office Actions Server*',
      'Clipboard User Service*',
      "Optimize Start Menu Cache Files-*",
      "User_Feed_Synchronization-*"
    )
    $OK_TASK_RESULTS = @(0,267009,267010,267011,267012,267013,267014)

    $problem_found = $false
    $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | ?{$_.TaskPath -notlike "\Microsoft\Windows\*"}

    foreach ($t in $tasks) {
        $skip = $false
        foreach ($p in $task_name_paterns_to_ignore) {
          if ($t.TaskName -like $p) { $skip = $true; break }
        }
        if ($skip) { continue }

        $i = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue
        if ($i -and ($i.LastTaskResult -notin $OK_TASK_RESULTS -or $i.NumberOfMissedRuns -gt 0)) {
            $problem_found = $true
            $details=(Get-ScheduledTaskDeepInfo -TaskName $t.TaskName -TaskPath $t.TaskPath |
              Select-Object state,actions,Description,RunAcntUserId,RunLogonType,LastRunTime,NextRunTime | %{
                $_.PSObject.Properties |
                  Where-Object { $_.Value -ne $null -and "$($_.Value)" -ne '' } |
                    ForEach-Object {
                      if ($_.Name -eq 'actions') {
                        $acts = @($_.Value)
                        foreach($a in $acts){
                          if($null -eq $a){ continue }
                          if($a.PSObject.Properties.Name -contains 'Execute'){
                            "Command: $($a.Execute) $($a.Arguments)"
                          } else {
                            $t = $a.GetType().FullName
                            "Action: $t"
                          }
                        }
                      } else {
                        "{0}: {1}" -f $_.Name, $_.Value
                      }
                    }
              } | out-string)
            if ($i.LastTaskResult -notin $OK_TASK_RESULTS) {
                $meaning = Convert-TaskResultCode $i.LastTaskResult
                Write-Warning "[warning] Scheduled Task with failures: '$($t.TaskPath)$($t.TaskName)'; Last exit code: $($i.LastTaskResult) ($meaning)`nDetails about this task:`r`n$details"
            }
            if ($i.NumberOfMissedRuns -gt 0) {
                if ($i.NumberOfMissedRuns -lt 5){
                    if ($t.TaskName -like '*update*' `
                        -or $t.TaskName -like '*Maintenance*' `
                        -or $t.TaskName -in @('Office Serviceability Manager','Resolut Refresh') `
                    ) {
                        Write-Warning "[info] Scheduled Task with just a few missed runs(<5): '$($t.TaskPath)$($t.TaskName)'`n$($i.NumberOfMissedRuns) runs where missed. Details about this task: $details"
                    } else {
                        Write-Warning "[notice] Scheduled Task with just a few missed runs(<5): '$($t.TaskPath)$($t.TaskName)'`n$($i.NumberOfMissedRuns) runs where missed. Details about this task: $details"
                    }
                } else {
                    Write-Warning "[warning] Scheduled Task with missed runs: '$($t.TaskPath)$($t.TaskName)'`n$($i.NumberOfMissedRuns) runs where missed. Details about this task: $details"
                }
            }
        }
    }
    if ($problem_found) { return }

    Write-Warning "[pass] Scheduled tasks healthy (non-Microsoft)"
}


<#
.SYNOPSIS
Evaluates scheduled task "Last Result" codes on the local host, suppressing informational values, and reports only meaningful warnings and failures.

.DESCRIPTION
Queries all scheduled tasks on the local computer via SCHTASKS /V, normalizes
and interprets Last Result codes (including HRESULTs and bare Win32 values),
suppresses informational and benign results, and emits only actionable warnings
and failures. For each problematic task it outputs a summary message plus a
multiline comment block describing the task and execution details.
#>
function HealthTest-ScheduledTasksLastResult {
  $mapHresult = @{
    0x40010004=@{d='Process terminated externally'}
    0x80070001=@{d='Incorrect function'}
    0x80070002=@{d='File or path not found'}
    0x80070003=@{d='Path not found'}
    0x80070005=@{d='Access denied'}
    0x8007000A=@{d='Invalid environment'}
    0x8007000B=@{d='Bad EXE format / arch mismatch'}
    0x80070070=@{d='Disk full'}
    0x8007052E=@{d='Logon failure (bad username/password)'}
    0x80070533=@{d='Account disabled'}
    0x800705B4=@{d='Operation timed out'}
    0x800706BA=@{d='RPC server unavailable'}
    0x80040121=@{d='Storage access denied'}
    0x80040154=@{d='COM class not registered'}
    0x800401F5=@{d='COM application not found'}
    0x8004130F=@{d='Task engine execution error/timeout'}
    0x80004005=@{d='Unspecified failure'}
    0x80090020=@{d='Cryptographic/DPAPI failure'}
    0xC000006D=@{d='Logon failure'}
    0xC000006A=@{d='Wrong password'}
    0xC0000064=@{d='Unknown user'}
    0xC0000072=@{d='Account disabled'}
    0xC0000234=@{d='Account locked out'}
  }
  $mapWin32Bare = @{
    1056=@{d='Service already running'}
    1326=@{d='Logon failure (bad username/password)'}
    1331=@{d='Account disabled'}
    1909=@{d='Account locked out'}
  }

  function Normalize-Code($v){
    if($null -eq $v){return $null}
    $s="$v".Trim()
    if($s -eq '' -or $s -eq 'N/A'){return $null}
    if($s -match '(?i)^0x([0-9a-f]{1,8})$'){return [int64]([uint32]::Parse($matches[1],[System.Globalization.NumberStyles]::HexNumber))}
    if($s -match '^-?\d+$'){return [int64]$s}
    $null
  }
  function To-UInt32($code){
    try{
      $i64=[int64]$code
      $u64=[uint64]($i64 -band 0xFFFFFFFFFFFFFFFF)
      [uint32]($u64 -band 0x00000000FFFFFFFF)
    }catch{$null}
  }
  function Get-Severity($u32,$isBare){
    if($isBare){return 'Error'}
    if($null -eq $u32){return 'Error'}
    $sev=($u32 -band 0xC0000000)
    if($sev -eq 0x80000000){'Error'}
    elseif($sev -eq 0x40000000){'Warning'}
    elseif($u32 -eq 0){'Success'}
    else{'Success'}
  }

  # Suppress purely informational "Last Result" values entirely
  $benign = [uint32[]](0x00000000,0x10000000,0x40010004) # S_OK, success-severity flag, DBG_TERMINATE_PROCESS
  function Is-Informational($u32,$sev){
    if($null -eq $u32){return $false}
    if($benign -contains $u32){return $true}
    if($sev -eq 'Success'){return $true}
    if($u32 -ge 0x00041300 -and $u32 -le 0x000413FF){return $true} # SCHED_S_* family
    $false
  }

  function Get-RowValue{ param($row,[string[]]$names)
    foreach($n in $names){
      if($row.PSObject.Properties.Name -contains $n){
        $v=$row.$n; if($v){return "$v"}
      }
    }
    $null
  }

  $want = [ordered]@{
    'Task Name'         = @('TaskName','Task Name')
    'Run As User'       = @('Run As User','RunAsUser')
    'Last Run Time'     = @('Last Run Time','LastRunTime')
    'Next Run Time'     = @('Next Run Time','NextRunTime')
    'Status'            = @('Status')
    'Schedule Type'     = @('Schedule Type','ScheduleType')
    'Triggers'          = @('Schedule','Triggers')
    'Task To Run'       = @('Task To Run','TaskToRun','Actions')
    'Start In'          = @('Start In','StartIn')
    'Logon Mode'        = @('Logon Mode','LogonMode')
    'Author'            = @('Author')
    'Last Result (raw)' = @('Last Result','LastResult')
  }

  $passed = $true
  # These conditions:
  #     $_.'Last Result' -notmatch 'Last Result' -and $_.HostName -eq $env:COMPUTERNAME
  # filter-out plenty of invalid lines that schtasks generates
  $tasks = schtasks /query /fo csv /v | ConvertFrom-Csv | Where-Object {
    $_.'Last Result' -ne 0 -and `
    $_.'Last Result' -notmatch 'Last Result' -and $_.HostName -eq $env:COMPUTERNAME
  }

  foreach($t in $tasks){
    $dec = Normalize-Code $t.'Last Result'
    if($null -eq $dec){ continue }
    $u32 = To-UInt32 $dec
    if($null -eq $u32){ continue }

    $isBare = $mapWin32Bare.ContainsKey($u32)
    $sev = Get-Severity $u32 $isBare
    if(Is-Informational $u32 $sev){ continue } # suppress informational results

    $info = if($isBare){ $mapWin32Bare[$u32] } else { $mapHresult[$u32] }
    $desc = if($info){ $info.d } else { 'Unknown failure' }
    $hex  = ('0x{0:X8}' -f $u32)
    $msg  = "Scheduled Task '$($t.TaskName)' terminated with Last Result=$hex('$desc')"

    $lines=@()
    foreach($k in $want.Keys){
      $val = Get-RowValue -row $t -names $want[$k]
      if($val){ $lines += ('{0}: {1}' -f $k,$val) }
    }
    $details = ($lines -join "`r`n")

    if($sev -eq 'Error'){ Write-Warning "[failure] $($msg)`n$($details)"; $passed = $false }
    elseif($sev -eq 'Warning'){ Write-Warning "[warning] $($msg)"; $passed = $false }
  }

  if ($passed) {
      Write-Warning "[pass] HealthTest-ScheduledTasksLastResult found no problem"
  }
}


<#
.SYNOPSIS
    Performs a comprehensive health check of all local physical disks using Windows Storage APIs.

.DESCRIPTION
    HealthTest-Storage examines each physical disk via Get-PhysicalDisk and (where available)
    Get-StorageReliabilityCounter to detect early signs of storage degradation. It evaluates
    parameters such as HealthStatus, temperature, media/uncorrectable errors, and SSD wear
    percentage, returning $true if all drives are within safe limits or $false otherwise.
#>
function HealthTest-Storage {
    [CmdletBinding()]
    param([int]$MaxTemperatureC = 70,[int]$MaxPercentUsed = 95)

    $allHealthy = $true
    $disks = Get-PhysicalDisk -ErrorAction SilentlyContinue
    if (-not $disks) { Write-Warning "[failure] No disks visible via Get-PhysicalDisk"; return }

    foreach ($d in $disks) {
        # 1) Explicit predictive failure
        $predFail = $false
        if ($d.PSObject.Properties.Name -contains 'OperationalStatus') {
            $os = $d.OperationalStatus
            if ($os -is [array]) { foreach($s in $os){ if ($s -eq 'Predictive Failure') { $predFail=$true; break } } }
            else { if ($os -eq 'Predictive Failure') { $predFail=$true } }
        }
        if ($predFail) {
            Write-Warning "[failure] $(("OperationalStatus=Predictive Failure for disk '{0}'" -f $d.FriendlyName))"
            $allHealthy = $false
        }

        # 2) HealthStatus
        if ($d.PSObject.Properties.Name -contains 'HealthStatus') {
            if ($d.HealthStatus -ne 'Healthy') {
                Write-Warning "[failure] $(("HealthStatus={0} for disk '{1}'" -f $d.HealthStatus,$d.FriendlyName))"
                $allHealthy = $false
            }
        }

        # 3) Reliability counters (temp, errors, wear)
        try {
            $c = $d | Get-StorageReliabilityCounter -ErrorAction Stop
            if ($c) {
                if ($c.PSObject.Properties.Name -contains 'Temperature') {
                    if ([double]$c.Temperature -gt $MaxTemperatureC) {
                        Write-Warning "[failure] $(("Temperature({0}) exceeds max for disk '{1}'" -f $c.Temperature,$d.FriendlyName))"
                        $allHealthy = $false
                    }
                }

                $uncorr = 0
                foreach ($p in 'ReadErrorsUncorrected','WriteErrorsUncorrected','MediaErrors','UncorrectableErrors') {
                    if ($c.PSObject.Properties.Name -contains $p) { $uncorr += [int64]$c.$p }
                }
                if ($uncorr -gt 0) {
                    Write-Warning "[failure] $(("Uncorrectable error counter not zero for disk '{0}'" -f $d.FriendlyName))"
                    $allHealthy = $false
                }

                $percentUsed = $null; $propName='(UNKNOWN)'
                foreach ($name in 'PercentageUsed','PercentUsed','Wear','WearPercentage','LifeRemaining','PercentLifeRemaining','LifeLeftPercent') {
                    if ($c.PSObject.Properties.Name -contains $name) {
                        $val = [double]$c.$name
                        if ($name -in 'LifeRemaining','PercentLifeRemaining','LifeLeftPercent') { $percentUsed = 100 - $val } else { $percentUsed = $val }
                        $propName = $name; break
                    }
                }
                if ($percentUsed -ne $null -and $percentUsed -ge $MaxPercentUsed) {
                    Write-Warning "[failure] $(("{0} >= {1} for disk '{2}'" -f $propName,$MaxPercentUsed,$d.FriendlyName))"
                    $allHealthy = $false
                }
            }
        } catch { }
    }

    if ($allHealthy) { Write-Warning "[pass] HealthTest-Storage passed for all disks" }
}


<#
.SYNOPSIS
Check NTFS volumes for the "dirty" bit.
.DESCRIPTION
Enumerates NTFS volumes via Get-Volume and runs `fsutil dirty query` per drive. If any volumes are
marked dirty, emits Log-Warning listing the drive letters and returns $false; otherwise returns $true.
.OUTPUTS
[bool] $true if no dirty volumes; $false if any volume is dirty or on error.
.EXAMPLE
HealthTest-NtfsDirtyBit
#>
function HealthTest-NtfsDirtyBit {
    $dirty = @()
    $drives = Get-Volume -FileSystem NTFS -ErrorAction SilentlyContinue
    foreach ($d in $drives) {
      $out = (& fsutil dirty query $d.DriveLetter`: 2>$null)
      if ($out -and ($out -match 'is dirty')) { $dirty += $d.DriveLetter }
    }
    if ($dirty.Count -gt 0) { Write-Warning "[warning] NTFS dirty bit set on: $($dirty -join ', ')"; return }
    Write-Warning "[pass] No NTFS dirty volumes"
}

<#
.SYNOPSIS
Sanity-check IIS site bindings for common misconfigurations.
.DESCRIPTION
If IIS cmdlets are available, inspects bindings for each website. Warns/notices on:
- HTTP wildcard bindings on port 80 when multiple sites exist;
- HTTPS bindings lacking a certificate assignment.
Returns $false if any issues found, $true otherwise.
.OUTPUTS
[bool] $true if bindings look sane; $false if issues detected or on errors.
.EXAMPLE
HealthTest-IisBindings
.NOTES
Requires WebAdministration module (Get-Website/Get-WebBinding) when present; otherwise no-op success.
#>
function HealthTest-IisBindings {
    # Skip test on workstations
    # 1 = Workstation 2 = Domain Controller 3 = Windows Server
    $host_type = (Get-CimInstance Win32_OperatingSystem).ProductType
    if ($host_type -eq 1) {
        Write-Output "ProductType=$host_type; skiping HealthTest-IisBindings"
        return
    }

    $role = Get-WindowsFeature Web-Server -ErrorAction SilentlyContinue

    if (-not($role -and $role.Installed)) {
        Write-Warning "[info] No IIS installed; skiping HealthTest-IisBindings"
        return
    }
    $problem_found = $false
    $sites = Get-Website
    foreach ($s in $sites) {
      $b = Get-WebBinding -Name $s.Name
      foreach ($x in $b) {
        if ($x.protocol -eq 'http' -and ($x.bindingInformation -like '*:80:*') -and ($sites.count -gt 1)) {
            $commnet = ""
            if ($sites.count -gt 1) {$comment = "`nSince multiple sites are hosted, wildcard bindins may expose unintended content"}
            Write-Warning "[notice] $($s.Name): site serves plain HTTP with wildcard bindings$comment"
            $problem_found = $true
        }
        if ($x.protocol -eq 'https' -and ($x.bindingInformation -like '*:443:*') -and -not $x.certificateHash) {
            Write-Warning "[warning] $($s.Name): site is configured for HTTPS, but it has no certificate assigned"
            $problem_found = $true
        }
      }
    }
    if ($problem_found) {return}
    Write-Warning "[pass] IIS bindings look sane"
}

<#
.SYNOPSIS
Flag high DFS-R backlog for a replication group.
.DESCRIPTION
For the given replication group (default 'Domain System Volume'), enumerates DFS-R connections and
retrieves backlog counts per source->destination. Warns when any backlog exceeds 1000 items; returns
$false if any threshold exceeded, $true otherwise.
.PARAMETER RGName
DFSR Replication Group name. Default: 'Domain System Volume'.
.OUTPUTS
[bool] $true when backlog is within limits or cmdlets unavailable; $false if high backlog detected.
.EXAMPLE
HealthTest-DfsrBacklog -RGName 'Domain System Volume'
.NOTES
Requires DFSR PowerShell cmdlets (Get-DfsrConnection/Get-DfsrBacklog) when present.
#>
function HealthTest-DfsrBacklog {
    param([string]$RGName='Domain System Volume')
    if (-not(Get-Service DFSR -ErrorAction SilentlyContinue)) {
        Write-Output "No DFSR service; skipping HealthTest-DfsrBacklog."
        return
    }
    if (-not (Get-Command Get-DfsrBacklog -ErrorAction SilentlyContinue)) {
        Write-Warning "[warning] DFSR cmdlets not available. Can't start the DFSR backlog healthcheck." `
            -comment 'I suggest you install RSAT-DFS-Mgmt-Con:`n        Install-WindowsFeature RSAT-DFS-Mgmt-Con'
        return
    }
    $conn = Get-DfsrConnection -GroupName $RGName -ErrorAction SilentlyContinue
    if (-not $conn) { Write-Warning "[info] No DFS-R connections found for '$RGName'"; return }
    $over = @()
    foreach ($c in $conn) {
      $b = Get-DfsrBacklog -GroupName $RGName -SourceComputerName $c.SourceComputerName -DestinationComputerName $c.DestinationComputerName -ErrorAction SilentlyContinue
      if ($b -and $b.Count -gt 1000) { $over += "$($c.SourceComputerName)->$($c.DestinationComputerName): $($b.Count)" }
    }
    if ($over.Count -gt 0) { Write-Warning "[warning] DFS-R backlog high`n$($over -join ' | ')"; return }
    Write-Warning "[pass] DFS-R backlog OK"; return
}

<#
.SYNOPSIS
Snapshot test for low free RAM.
.DESCRIPTION
Samples \Memory\Available MBytes `-Samples` times with `-SampleDelayMs` between samples, computes
the median, then compares to percent-of-total thresholds with absolute minimum floors:
~10% (notice), ~5% (warn), ~2% (failure). Emits Log-pass/Notice/Warn/Failure and returns [bool].
If free RAM is below 10% and only one sample was taken, another one is taken and average is used.
.PARAMETER Samples
Number of samples to take. Default 1. (But see note in description)
.PARAMETER SampleDelayMs
Delay in milliseconds between samples. Default 500.
.OUTPUTS
[bool] $true if free RAM is healthy (>= ~10%); $false at warn/failure levels.
.EXAMPLE
HealthTest-RamPressure -Samples 5 -SampleDelayMs 250
#>
function HealthTest-RamPressure {
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [ValidateRange(1,2147483647)][int]$Samples=1,
    [ValidateRange(0,3600000)][int]$SampleDelayMs=500
  )

  $os = Get-CimInstance Win32_OperatingSystem
  $totalMB = [math]::Round($os.TotalVisibleMemorySize/1024,1)
  if ($totalMB -le 0) { Write-Warning "[failure] Total visible memory is 0 MB; cannot compute free %."; return }

  function Get-AvailMB {
    try {
      $c = (Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples.CookedValue
      if ($null -eq $c) { throw "No counter value." }
      [math]::Round([double]$c,1)
    } catch { return $null }
  }

  $vals = @()
  for ($i=0; $i -lt $Samples; $i++) {
    $v = Get-AvailMB
    if ($null -eq $v) { Write-Warning "[warning] Skipped a failed \\Memory\\Available MBytes read (sample $($i+1)/$Samples)."; continue }
    $vals += $v
    if (($i+1) -lt $Samples -and $SampleDelayMs) { Write-Verbose "waiting $SampleDelayMs ms"; Start-Sleep -Milliseconds $SampleDelayMs }
  }
  if ($vals.Count -eq 0) { Write-Warning "[failure] Failed to sample available memory."; return }

  $sorted = @($vals | Sort-Object)
  $n = $sorted.Length
  $mid = [int]($n/2)
  $medianFree = if ($n % 2) { [double]$sorted[$mid] } else { ([double]$sorted[$mid-1] + [double]$sorted[$mid]) / 2 }
  $freePcnt = [math]::Round(($medianFree*100)/$totalMB,1)

  if ($Samples -eq 1 -and $freePcnt -lt 10) {
    if ($SampleDelayMs) { Start-Sleep -Milliseconds $SampleDelayMs }
    $v = Get-AvailMB
    if ($null -ne $v) {
      $medianFree = [math]::Round((([double]$medianFree + [double]$v)/2),1)
      $freePcnt = [math]::Round(($medianFree*100)/$totalMB,1)
    }
  }

  if ($freePcnt -lt 2) { Write-Warning "[failure] Free RAM under 2%`n$freePcnt% free RAM"; return }
  elseif ($freePcnt -lt 5) { Write-Warning "[warning] Free RAM between 2 and 5%`n$freePcnt% free RAM"; return }
  elseif ($freePcnt -lt 10) { Write-Warning "[notice] Free RAM between 5 and 10%`n$freePcnt% free RAM"; return }
  Write-Warning "[pass] Free RAM at $($freePcnt)%"
  return
}

<#
.SYNOPSIS
Baseline check for key Windows Exploit Protection (system) mitigations.
.DESCRIPTION
Reads Get-ProcessMitigation -System and verifies core mitigations:
DEP enabled, ASLR force-relocate, and SEHOP. Emits notices for missing items and returns $false if
any are off; $true only when all are enabled or cmdlets unavailable (soft pass).
.OUTPUTS
[bool] $true if mitigations meet baseline; $false if any are missing or on errors.
.EXAMPLE
HealthTest-ExploitProtectionBaseline
.NOTES
Requires Windows 10/Server 2016+ with Exploit Protection cmdlets.
#>
function HealthTest-ExploitProtectionBaseline {
    if (-not (Get-Command Get-ProcessMitigation -ErrorAction SilentlyContinue)) { Write-Warning "[notice] Exploit Protection cmdlets unavailable"; return }
    $sys = Get-ProcessMitigation -System -ErrorAction SilentlyContinue
    if (-not $sys) { Write-Warning "[warning] Could not read system process mitigations"; return }
    $ok = $true
    if (-not $sys.Dep.Enable) { Write-Warning "[notice] Exploit Protection; DEP not enforced system-wide"; $ok = $false }
    if (-not $sys.ASLR.EnableForceRelocateImages) { Write-Warning "[notice] Exploit Protection; ASLR not enforcing force-relocate"; $ok = $false }
    if (-not $sys.SEHOP.Enable) { Write-Warning "[notice] Exploit Protection; SEHOP not enabled"; $ok = $false }
    if ($ok) { Write-Warning "[pass] Exploit Protection key mitigations enabled"; return } else { return }
}

<#
.SYNOPSIS
    Audits SMB shares for broad access and hygiene issues.

.DESCRIPTION
    The HealthTest-ShareReasonableness function enumerates all SMB shares on the local host
    (excluding admin/system shares unless -IncludeAdminShares is used), inspects
    both share-level and NTFS-level permissions, and reports potential security
    or configuration issues.

    It focuses on "broad access" principals (Everyone, Authenticated Users, Domain Users, etc.)
    and determines whether they have effective Read/Write/Full access by intersecting
    share and NTFS permissions. It highlights risky conditions and hygiene issues such as:
      - Broad write or read access by many users
      - Orphaned share permissions blocked by NTFS (suggesting cleanup)
      - Presence of Null session shares
      - SMB1 enabled
      - SMB signing not required on DCs

    The function outputs status via Log-pass, Log-Warning, Log-Failure, and Log-Notice
    to integrate cleanly into your health check framework, and returns $true if no high-risk
    issues are found, otherwise $false.

.PARAMETER BroadPrincipals
    An array of account or group names considered "broad access".
    Defaults to: Everyone, Authenticated Users, Domain Users, Users, Guests.

.PARAMETER IncludeAdminShares
    If specified, also checks admin/system shares (C$, ADMIN$, IPC$, SYSVOL, NETLOGON).

.OUTPUTS
    [bool] - $true if no risk findings were found, $false otherwise.

.EXAMPLE
    HealthTest-ShareReasonableness

    Runs the check on all non-admin SMB shares on the local machine.

.EXAMPLE
    HealthTest-ShareReasonableness -IncludeAdminShares

    Runs the check on all shares including admin/system ones.

.NOTES
    This function requires the SMB Share and CIM modules to be available.
    It is compatible with PowerShell 5.1 and PowerShell 7+.

.LINK
    https://learn.microsoft.com/powershell/module/smbshare/get-smbshare
.LINK
    https://learn.microsoft.com/powershell/module/smbshare/get-smbshareaccess
.LINK
    https://learn.microsoft.com/powershell/module/smbshare/revoke-smbshareaccess
.LINK
    https://learn.microsoft.com/powershell/module/microsoft.powershell.security/get-acl
.LINK
    https://learn.microsoft.com/powershell/module/cimcmdlets/get-ciminstance
#>
function HealthTest-ShareReasonableness {
  [CmdletBinding()]param(
    [string[]]$BroadPrincipals = @(
      'Everyone',
      'Authenticated Users',
      'Domain Users',
      'Users',
      'Guests',
      'BUILTIN\Users',
      'BUILTIN\Power Users',
      'NT AUTHORITY\INTERACTIVE',
      'NT AUTHORITY\NETWORK',
      'NT AUTHORITY\ANONYMOUS LOGON',
      'NT AUTHORITY\SYSTEM'
    ),
    [switch]$IncludeAdminShares
  )
  # Regarding BUILTIN\Power Users:
  # I have included it in the list allthough it's not a Broad group (in fact it's usually empty).
  # It is a legacy local group from pre-Vista/XP era. On modern Windows, it exists but is empty by default.
  # If it appears, it often indicates old misapplied permissions and that's the reason I left it.

  # 0(Workstation standalone),  1(Workstation domain joined), 2(Server standalone), 3(Server joined), 4(DC non-FSMO), 5(DC with FSMO role)
  $domainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole
  $isHostDC = ($domainRole -in 4,5)

  if ((Get-PropValue -obj (Get-Service -Name LanmanServer) -name Status) -ne 'running') {
      Write-Warning "[pass] Skipping HealthTest-ShareReasonableness; LanmanServer service not running."
      return
  }

  $shares = Get-SmbShare | Where-Object {
    ($IncludeAdminShares -or ($_.Name -notmatch '^\w+\$$')) -and
    $_.ShareType -eq 'FileSystemDirectory'
  }

  $riskFound = $false
  foreach($s in $shares){
    $shareAces = Get-SmbShareAccess -Name $s.Name -ErrorAction SilentlyContinue
    $path = $s.Path
    if(-not (Test-Path $path)){ Write-Warning "[warning] Share '$($s.Name)' points to missing path '$path'"; $riskFound = $true; continue }

    $ntfsAcl = Get-Acl -LiteralPath $path

    # List principals at share and NTFS layers and a coarse "effective" overlap
    #-------------------------------------------------------------------------------
    $sharePrincipals = @()
    foreach($ace in $shareAces){ if($ace.AccountName){ $sharePrincipals += $ace.AccountName } }
    $sharePrincipals = $sharePrincipals | Sort-Object -Unique

    $ntfsPrincipals = @()
    foreach($ace in $ntfsAcl.Access){ if($ace.IdentityReference -and $ace.IdentityReference.Value){ $ntfsPrincipals += $ace.IdentityReference.Value } }
    $ntfsPrincipals = $ntfsPrincipals | Sort-Object -Unique

    # Coarse overlap: exact-name intersection (does not resolve group nesting)
    $effectivePrincipals = @()
    foreach($sp in $sharePrincipals){ if($ntfsPrincipals -contains $sp){ $effectivePrincipals += $sp } }
    $effectivePrincipals = $effectivePrincipals | Sort-Object -Unique

    if ($s.Name -notin @('SYSVOL','NETLOGON','ADMIN$')){
        Write-Warning "[info] Accounts for share '$($s.Name)' (Path: $path)"
        Write-Warning "[info] $(("    Share-level : {0}" -f ($(if($sharePrincipals){ $sharePrincipals -join ', ' } else { '<none>' }))))"
        Write-Warning "[info] $(("    NTFS-level  : {0}" -f ($(if($ntfsPrincipals){ $ntfsPrincipals -join ', ' } else { '<none>' }))))"
        Write-Warning "[info] $(("    Effective(*) : {0}" -f ($(if($effectivePrincipals){ $effectivePrincipals -join ', ' } else { '<none>' }))))"
        Write-Warning "[info]     (*) Effective here means present on both lists; this is a coarse check without group nesting resolution."
    }

    # Identify cases of broad access to the share
    #-------------------------------------------------------------------------------
    $report = @()
    foreach($p in $BroadPrincipals){
      $shareRights = @()
      foreach($ace in $shareAces){ if($ace.AccountName -match "^(.*\\)?$([regex]::Escape($p))$"){ $shareRights += $ace.AccessRight } }
      $ntfsRights = @()
      foreach($ace in $ntfsAcl.Access){
        if($ace.IdentityReference -match "^(.*\\)?$([regex]::Escape($p))$"){
          if(-not $ace.IsInherited){ }
          $ntfsRights += $ace.FileSystemRights.ToString()
        }
      }

      if($shareRights.Count -eq 0 -and $ntfsRights.Count -eq 0){ continue }

      $effRead  = ($shareRights -match 'Read|Full|Change|All').Count -gt 0 -and ($ntfsRights -match 'Read|ReadAndExecute|ListDirectory|Modify|FullControl|All').Count -gt 0
      $effWrite = ($shareRights -match 'Change|Full|All').Count -gt 0 -and ($ntfsRights -match 'Write|Modify|Create|Delete|FullControl|All').Count -gt 0
      $effFull  = ($shareRights -match 'Full|All').Count -gt 0 -and ($ntfsRights -match 'FullControl|All').Count -gt 0

      $report += [pscustomobject]@{
        Share=$s.Name; Path=$path; Principal=$p
        SharePerms=($shareRights -join ','); NtfsPerms=($ntfsRights -join ',')
        Effective = if($effFull){'Full'} elseif($effWrite){'Write'} elseif($effRead){'Read'} else {'None'}
      }
    }

    if($report.Count -eq 0){
      Write-Warning "[pass] $("Share '{0}' has no broad-principal read or write access; ABE={1}; EncryptData={2}" -f $s.Name,$s.FolderEnumerationMode,$s.EncryptData)"
    } else {
      foreach($r in $report){
        if($r.Effective -eq 'Full' -or $r.Effective -eq 'Write'){
          Write-Warning (("[failure] '{1}' can write share '{0}'('$path')`n" -f $r.Share,$r.Principal) + ("Restrict to specific groups; ensure share grants Read or None to broad principals and tighten NTFS. Path: {0}" -f $r.Path))
          $riskFound = $true
        } elseif($r.Effective -eq 'Read') {
            if ($r.Share -ne 'SYSVOL'){
                Write-Warning "[warning] $(("'$($r.Principal)' can read share '$($r.Share)'('$path')"))"
            }
        } else {
          Write-Warning "[pass] $(("No effective access for {0} on '{1}' (blocked by layer intersection)" -f $r.Principal,$r.Share))"
        }
      }
      # Log-Info ("ABE={0}; EncryptData={1}; Caching={2}" -f $s.FolderEnumerationMode,$s.EncryptData,$s.CachingMode)
    }

    # Hygiene extras
    # if($s.FolderEnumerationMode -ne 'AccessBased'){ Write-Warning "[warning] $(("Enable Access-Based Enumeration on '{0}' if multi-tenant" -f $s.Name))" }
    # if(-not $s.EncryptData){ Write-Warning "[warning] $(("Consider SMB encryption on '{0}' for sensitive data" -f $s.Name))" }
    # if($s.CachingMode -ne 'None'){ Write-Warning "[warning] $(("Offline caching is {0} on '{1}' - assess if appropriate" -f $s.CachingMode,$s.Name))" }
  }

  # Global checks
  #--------------------------
  $srv = Get-SmbServerConfiguration
  if($srv.EnableSMB1Protocol){
    Write-Warning "[warning] SMB1 is enabled; disable unless really needed`nYou can disable it by running: Set-SmbServerConfiguration -EnableSMB1Protocol `$false"
  }
  if($srv.RequireSecuritySignature -eq $false){
    if ($isHostDC) {
      Write-Warning "[warning] SMB signing not required and this is a DC. It is recomended to enable`nYou can enable it by running: Set-SmbServerConfiguration -RequireSecuritySignature `$true"
    } else {
      Write-Warning "[info] SMB signing not required; You may want to consider enabling it. It helps avoid sophisticated internal data integrity attacks."
    }
  }

  # Null session shares
  $nullShares = @()
  try{
    $reg = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -ErrorAction SilentlyContinue
    if ($reg -and ($reg.PSObject.Properties.Name -contains 'NullSessionShares')) {
      $val = $reg.NullSessionShares
      if ($null -ne $val) {
        if ($val -is [array]) { $nullShares = $val }
        elseif ([string]::IsNullOrWhiteSpace([string]$val) -eq $false) { $nullShares = @([string]$val) }
      }
    }
  } catch {}
  if($nullShares -and $nullShares.Count -gt 0){
    Write-Warning "[failure] Null session shares configured: $($nullShares -join ', ')`nRemove unless a documented legacy requirement exists."
    $riskFound = $true
  }

  # Null session pipes
  $nullPipes = @()
  try{
    $reg = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -ErrorAction SilentlyContinue
    if ($reg -and ($reg.PSObject.Properties.Name -contains 'NullSessionPipes')) {
      $val = $reg.NullSessionPipes
      if ($null -ne $val) {
        if ($val -is [array]) { $nullPipes = $val }
        elseif ($val -is [string]) { $nullPipes = $val -split ',' }
      }
    }
  } catch {}

  $nullPipes = $nullPipes | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ } | Sort-Object -Unique
  if ($isHostDC) {
      # these are recomended by Microsoft to be kept in DCs
      $nullPipes = $nullPipes | ?{$_ -notin @('lsarpc', 'netlogon', 'samr')}
  }
  if (Test-IsRdsLicensingServer) {
      # these are by default present in RDS servers (Terminal Services)
      $nullPipes = $nullPipes | ?{$_ -notin @('HydraLsPipe','TermServLicensing')}
  }

  if ($nullPipes -and $nullPipes.Count -gt 0) {
    Write-Warning (("[notice] Null session pipes (Named Pipes that can be accessed anonymously) found: {0}`n" -f ($nullPipes -join ', ')) + "Anonymous users are allowed to open those pipes. Modern domains don't need null pipes and they increase attack surface if other policies are loose. If you don't have legacy (pre-Windows 2000-era) trusts/clients, it's recommended to keep Null session pipes empty. Change Local Security Policy > Security Options > 'Network access: Named Pipes that can be accessed anonymously' (set to None), or the equivalent GPO.")
  }

  if (!$riskFound) {Write-Warning "[pass] No risks related to SMB shares were detected"}
}

<#
.SYNOPSIS
Checks if there are any non-default file or print shares on this machine.

.DESCRIPTION
Warns if any non-hidden shares (not ending in $) exist besides SYSVOL.
If none exist, outputs a good status. Also suggests disabling the LanmanServer
service if file and print sharing is not needed on non-domain controllers.
#>
function HealthTest-NonDefaultShares {
  # 0(Workstation standalone),  1(Workstation domain joined), 2(Server standalone), 3(Server joined), 4(DC non-FSMO), 5(DC with FSMO role)
  $domainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole
  $isHostDC = ($domainRole -in 4,5)

    $lanManServer_service = (get-service -Name "LanmanServer")
    $shares_beside_the_system_ones = Get-CimInstance -ClassName Win32_Share | Select-Object Name, Path | ?{$_.name -notlike '*$' -and $_.path -notlike 'C:\Windows\SYSVOL\sysvol*'}
    if ($shares_beside_the_system_ones) {
        $shares_beside_the_system_ones | %{Write-Warning "[warning] Found a share named '$($_.name)' that shares '$($_.Path)'"}
    } else {
        if ((Get-Service  -Name "LanmanServer").status -eq 'Stopped') {
            Write-Warning "[pass] No shares except the defaults and LanMan service is stopped."
        } else {
            Write-Warning "[pass] Found no shares except the default ones (like C$, ADMIN$)."
            if (!$isHostDC -and ($lanManServer_service.status -ne 'stopped' -or $lanManServer_service.StartType -ne 'Disabled')) {
                if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 2) { # server
                    Write-Warning "[warning] File & print sharing is enabled. It's recomended to disable it unless you really need it`nRun this if you want to disable:`n   Set-Service -Name 'LanmanServer' -StartupType Disabled; Stop-Service -Name 'LanmanServer'"
                } else { # workstation
                    Write-Output "File & print sharing is enabled on a workstation.`nYou may consider disabling it to reduce the attack surface"
                }
            }
        }
    }
}

<#
.SYNOPSIS
Checks for services set to start automatically but are not currently running.

.DESCRIPTION
Warns about any services with StartType=Automatic that are stopped (excluding a few known exceptions).
Reports success if all automatic services are running.
#>
function HealthTest-AutoStartServicesRunning {
  function Get-ServiceExitCodeMessage {
      param([int]$ExitCode)

      $known = $null
      switch ($ExitCode) {
          0    { $known = 'The operation completed successfully.'; break }
          1077 { $known = 'No attempts to start the service have been made since the last boot.'; break }
          1    { $known = 'Incorrect function.'; break }
          2    { $known = 'The system cannot find the file specified.'; break }
          3    { $known = 'The system cannot find the path specified.'; break }
          5    { $known = 'Access is denied.'; break }
          13   { $known = 'The data is invalid.'; break }
          14   { $known = 'Not enough storage is available to complete this operation.'; break }
          87   { $known = 'The parameter is incorrect.'; break }
          1053 { $known = 'The service did not respond to the start or control request in a timely fashion.'; break }
          1058 { $known = 'The service cannot be started because it is disabled or has no enabled devices associated with it.'; break }
          1067 { $known = 'The process terminated unexpectedly.'; break }
          1068 { $known = 'A dependency service or group failed to start.'; break }
          1075 { $known = 'The dependency service does not exist or has been marked for deletion.'; break }
          1114 { $known = 'A dynamic link library (DLL) initialization routine failed.'; break }
      }

      if ($known) { return $known }

      try {
          $raw = (& cmd.exe /c "net helpmsg $ExitCode" 2>$null)
          if ($raw) {
              $msg = ($raw -join ' ') -replace '\s+$',''
              if ($msg -and $msg -notmatch 'is not a valid Windows|more help is available') {
                  return $msg
              }
          }
      } catch {}

      "Unknown Windows service exit code."
  }

    <#
    SERVICES_THAT_ARE_OFTEN_STOPPED

    edgeupdate: Microsoft Edge Update Service
    InventorySvc: Inventory and Compatibility Appraisal service
    MapsBroker: Downloaded Maps Manager
    sppsvc: Software Protection
    gupdate: Google Update Service
    dmwappushservice: Device Management Wireless Application Protocol (WAP) Push message Routing Service
    gpsvc: Group Policy Client
    AppXSvc: AppX Deployment Service (for installing/updating .appx Microsoft Store apps)
    TrustedInstaller: windows updates service
    #>
    $SERVICES_THAT_ARE_OFTEN_STOPPED=@('edgeupdate', 'InventorySvc', 'MapsBroker', 'sppsvc',
        'gupdate', 'dmwappushservice', 'RemoteRegistry', 'StateRepository', 'gpsvc', 'AppXSvc',
        'TrustedInstaller')
    # The regex below is more powerful but more difficult to update correctly.
    $SERVICES_THAT_ARE_OFTEN_STOPPED_REGEX = '^(GoogleUpdaterInternalService[0-9.]+|GoogleUpdaterService[0-9.]+)$'

    $not_started_services = (Get-CimInstance Win32_Service -Filter "StartMode='Auto' and State!='Running'" |
        select Name,DisplayName,State,StartMode,DelayedAutoStart,ExitCode)

    if ($not_started_services) {
        $not_started_services | %{
            # TODO: consider exitcode 1077 practicly equivalent to 0 (no problem)
            # 1077 = No attempts to start the service have been made since the last boot.
            $exitCodeMeaning = Get-ServiceExitCodeMessage $_.ExitCode
            $serviceInListOfOftenStoped = (
                ($_.name -in $SERVICES_THAT_ARE_OFTEN_STOPPED) -or
                ($_.name -match $SERVICES_THAT_ARE_OFTEN_STOPPED_REGEX)
            )
            if ($serviceInListOfOftenStoped -and ($_.ExitCode -in (0,1077))) {
                    Write-Warning "[info] This service is stoped but its last execution terminated NORMALY and it's one of the services that are often stopped: Service '$($_.Name)', StartMode=$($_.StartMode), DelayedAutoStart=$($_.DelayedAutoStart), last ExitCode=$($_.ExitCode)($exitCodeMeaning)."
            } else {
                if ($_.ExitCode  -in (0,1077)) {
                    Write-Warning "[notice] Service '$($_.Name)' which is set to automatically start is not running; calmingly its last execution terminated normally: ExitCode=$($_.ExitCode)($exitCodeMeaning).`nDisplay name: $($_.DisplayName), StartMode=$($_.StartMode), DelayedAutoStart=$($_.DelayedAutoStart), last ExitCode=$($_.ExitCode)($exitCodeMeaning)."
                } else {
                    Write-Warning "[failure] Service '$($_.Name)' which is set to automatically start is not running; alarmingly its last execution terminated abnormally: ExitCode=$($_.ExitCode)($exitCodeMeaning).`nDisplay name: $($_.DisplayName), StartMode=$($_.StartMode), DelayedAutoStart=$($_.DelayedAutoStart), last ExitCode=$($_.ExitCode)($exitCodeMeaning)."
                }
            }
        }
    } else {
        Write-Warning "[pass] All services that are set to automatically start are running"
    }
}

<#
.SYNOPSIS
Checks if the system default locale (ACP/OEMCP) matches expected values.

.DESCRIPTION
Validates the system's ANSI (ACP) and OEM code pages. Warns if they are not the usual Greek (1253/737) or English (1252/437) combinations.
#>
function HealthTest-DefaultLocale {
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

<#
.SYNOPSIS
Checks if any local user accounts have PasswordRequired set to False.

.DESCRIPTION
Finds enabled local accounts without required passwords and reports them as failures.
#>
function HealthTest-LocalAcntRequirePass {
    $ok = $true
    $no_req_pass_accounts=Get-CimInstance -Class Win32_UserAccount -Filter `
        "LocalAccount=True AND Disabled=False AND PasswordRequired=False"
    if ($no_req_pass_accounts) {
        $no_req_pass_accounts | %{
            try {$account_name = $_.name} catch {$account_name="(FAILED_TO_GET_NAME)"}
            $ok = $false
            $comment = "Make sure the account password is set and then run this command:`n& cmd /c 'net user `"$($_.name)`" /passwordreq:yes'"
            Write-Warning "[failure] This local account has the property PasswordRequired set to false: $account_name`n$comment"
        }
    }
    if ($ok) {Write-Warning "[pass] All local accounts have PasswordRequired True"}
}

<#
.SYNOPSIS
Checks if any fixed, removable, or network drives are low on free space.

.NOTES
Relies on Test-DiskHasFreeSpace to perform the actual threshold check.
#>
function HealthTest-DisksHaveFreeSpace {
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $d.IsReady) { continue }
        $t = $d.DriveType.ToString()
        if (@('Fixed','Removable','Network') -notcontains $t) { continue }
        # emmits Log-failure/warning/pass
        $out = Test-DiskHasFreeSpace -PathOrDrive $d.Name
        if ($out.level -eq 'Error') {
            Write-Warning "[failure] Disk is critically low on free space`n$out"
        } elseif ($out.level -eq 'Warning') {
            Write-Warning "[warning] Disk is low on free space`n$out"
        } else {
            Write-Warning "[pass] Disk has enough free space`n$out"
        }
    }
}

<#
.SYNOPSIS
Warns for every directory that has more than 10,000 immediate child items.

.DESCRIPTION
Uses Find-LargeDirectory to locate directories with high item counts under C:\.
Each matching directory is logged as a warning with the item count in -Comment.
#>
function HealthTest-LargeDirectories {
    $foundLargeDirectory = $false

    foreach ($dir in Find-LargeDirectory -Path 'C:\' -Threshold 10000 -SkipPaths @("C:\windows\servicing","C:\windows\WinSxS")) {
        $foundLargeDirectory = $true
        $comment = "$($dir.ItemsCount) items found"
        try {
            $profileComment = Get-DirFileProfile $dir.Path | Format-DirFileProfileNarrative -SingleLine -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($profileComment)) {
                $comment = $profileComment
            }
        }
        catch {}

        Write-Warning "[warning] $("Directory $($dir.Path) has more than 10000 child items")`n$($comment)"
    }

    if (-not $foundLargeDirectory) {
        Write-Warning "[pass] No large directories found over threshold"
    }
}

<#
.SYNOPSIS
Reports a warning for any non Microsoft service it finds
#>
function HealthTest-NonMicrosoftServices {
    $ok = $true
    $CORE_MICROSOFT_VENDORS = @('Microsoft Windows','Microsoft Windows Publisher','Microsoft Corporation','Microsoft Windows Hardware Compatibility Publisher')
    $COMMON_VENDORS_FOR_WORKSTATIONS = @('Adobe Inc.', 'Cisco Systems, Inc.', 'Google LLC', 'Lenovo', 'Mozilla Corporation')
    $domainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole
    $isHostServer = ($domainRole  -in 3,4,5)
    Get-ServiceVendors | ?{$_.Vendor -notin $CORE_MICROSOFT_VENDORS -or $_.ExceptionsThrown} | %{
        if ($_.ExeSHA256) {$extra_msg = " (SHA256 of '$($_.ExePath)' is $($_.ExeSHA256))"} else {$extra_msg=""}
        $TrimmdServiceName = $_.ServiceName -replace '[0-9]+[.][0-9][0-9.]*$','[VERSION]'
        $ok = $false
        if ($_.ExceptionsThrown) {
            Write-Warning "[warning] Either something's wrong with service '$($_.ServiceName)' or there's a bug in Get-ServiceVendors.`n$($_.ExceptionsThrown)"
        } else {
            if ($isHostServer -or ($_.Vendor -notin $COMMON_VENDORS_FOR_WORKSTATIONS)) {
                $comment = "Admin must verify if service is legit and needed. Service Description: '$($_.DisplayName)'`nExecutable: '$($_.ExePath)'."
                Write-Warning "[warning] Found service that is not a core Microsoft service: Vendor='$($_.Vendor)' Name='$TrimmdServiceName'$extra_msg`n$comment"
            } else {
                $comment = "It is however from a common vendor. Admin must verify if service is legit and needed. Service Description: '$($_.DisplayName)'`nExecutable: '$($_.ExePath)'."
                Write-Warning "[notice] Found service that is not a core Microsoft service: Vendor='$($_.Vendor)' Name='$TrimmdServiceName'$extra_msg`n$comment"
            }
        }
    }
    if ($ok) {Write-Warning "[pass] Found no service except Microsoft ones"}
}

<#
.SYNOPSIS
Checks if any Hyper-V VMs that should auto-start are not currently running.

.DESCRIPTION
Lists all VMs where AutomaticStartAction is "Start" but their state is not "Running" and reports them as failures.
#>
function HealthTest-HyperVRunningVMs {
    $ok=$true
    $all_vm = get-vm
    $all_vm |?{$_.state -ne 'Running' -and $_.AutomaticStartAction -eq 'Start'} | %{
        Write-Warning "[failure] VM $($_.name) should be running but is not"
        $ok=$false
    }
    if ($all_vm |?{$_.AutomaticStartAction -eq 'Start'}) {
        if ($ok) {Write-Warning "[pass] All VMs that are set to always auto-start are running"}
    } else {
        Write-Warning "[info] No VM is set to always auto-start"
    }
}

<#
.SYNOPSIS
Checks running Hyper-V VMs for unexpected property values.

.DESCRIPTION
Iterates through running VMs and compares selected properties against the expected values stored in $EXPECTED_VALUES_FOR_VM_PROPERTIES.
Warns if any property value does not match the expected value.
#>
function HealthTest-HyperVVMProperties {
    # For Hyper-V hosts put here the expected values for these VM properties
    $EXPECTED_VALUES_FOR_VM_PROPERTIES = @{
        ReplicationHealth        = 'Normal'
        Status                   = 'Operating normally'
        PrimaryOperationalStatus = 'Ok'
        Heartbeat                = 'Ok*'
        AutomaticStartAction     = 'Start*'
        AutomaticStopAction      = 'Save'
        VMIntegrationService     = 'Guest Service Interface,Heartbeat,Key-Value Pair Exchange,Shutdown,Time Synchronization,VSS'
        Generation               = '2'
        Version                  = '9.0'
    }

    $vms = Get-VM | Where-Object { $_.State -eq 'Running' }
    foreach ($vm in $vms) {
        $EXPECTED_VALUES_FOR_VM_PROPERTIES.Keys | ForEach-Object {
            $prop_name = $_
            $expected_value = $EXPECTED_VALUES_FOR_VM_PROPERTIES[$prop_name]
            # write-host "Checking if $prop_name = $expected_value"

            if ($prop_name -eq 'VMIntegrationService') {
                # for VMIntegrationService we need to canonicalize the values
                $expected_value = ($expected_value -split ',' | % { $_.Trim() } | Sort-Object -Unique)  -join ','
                $actual_value   = ($vm.VMIntegrationService.Name | Sort-Object -Unique) -join ','
            } else {
                # for all other properties we have a simple value we expect them to have
                $actual_value = $vm.$prop_name
            }
            if ($actual_value -notlike $expected_value) {
                Write-Warning "[warning] VM $($vm.Name) has $prop_name='$actual_value' instead of '$expected_value'."
            }
        }
    }
}

<#
.SYNOPSIS
Checks if all Microsoft Defender (Malware Protection) features are enabled.

.DESCRIPTION
Evaluates the output of Get-MpComputerStatus and reports the state of several protection-related properties using Write-BasedOnTestResult.
#>
function HealthTest-MalwareProtectionFeatures {
    # $MPs holds the Malware Protection status
    $MPs=(Get-MpComputerStatus)
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).DefenderSignaturesOutOfDate not true?" -Test (!$MPs.DefenderSignaturesOutOfDate) -Comment "You may run`n  Update-MpSignature`n  to update."
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).AMServiceEnabled true?"                -Test $MPs.AMServiceEnabled
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).AMRunningMode Normal?"                 -Test ($MPs.AMRunningMode -eq 'Normal')
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).RealTimeProtectionEnabled true?"       -Test $MPs.RealTimeProtectionEnabled
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).OnAccessProtectionEnabled true?"       -Test $MPs.OnAccessProtectionEnabled
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).NISEnabled true?"                      -Test $MPs.NISEnabled
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).IoavProtectionEnabled true?"           -Test $MPs.IoavProtectionEnabled
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).BehaviorMonitorEnabled true?"          -Test $MPs.BehaviorMonitorEnabled
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).AntivirusEnabled true?"                -Test $MPs.AntivirusEnabled
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).AntispywareEnabled true?"              -Test $MPs.AntispywareEnabled
}

<#
.SYNOPSIS
Checks if the firewall service is running and enabled for all profiles.

.DESCRIPTION
Confirms the Windows Firewall (mpssvc) service is running and that the firewall is enabled on each network profile.
#>
function HealthTest-FirewallEnabled {
    Write-BasedOnTestResult "Is mpssvc (the firewall service) enabled?" -Test ((Get-Service -name mpssvc).status -eq 'Running')
    Get-NetFirewallProfile | ForEach-Object {
        Write-BasedOnTestResult "Is firewall enabled for the $($_.Name) profile?" -Test ($_.Enabled -eq 1) -comment "To enable firewall for *ALL* profiles run this:`nSet-NetFirewallProfile -Profile Domain,Private,Public -Enabled True"
    }
}

<#
.SYNOPSIS
Checks if Windows Defender performed a quick scan recently
#>
function HealthTest-RecentWindowsScan {
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
        Write-Warning "[pass] $("Did windows defender perform a quick scan recently?")`n$($comment)"
    } elseif ($days -lt $MAX_FAILURE_DAYS) {
        Write-Warning "[warning] $("Did windows defender perform a quick scan recently?")`n$($comment)"
    } else {
        Write-Warning "[failure] $("Did windows defender perform a quick scan recently?")`n$($comment)"
    }
}

<#
.SYNOPSIS
Tests SYSVOL/NETLOGON accessibility across DCs.
.DESCRIPTION
Checks UNC reachability for \\<DC>\SYSVOL and \\<DC>\NETLOGON.
#>
function HealthTest-SysvolNetlogonAccessible{
    $dcs = Get-DomainControllers
    $bad = @()
    foreach($dc in $dcs){
      $ok1 = Test-Path "\\$dc\SYSVOL"
      if (!$ok1) {Write-Warning "[failure] '\\$dc\SYSVOL' not reachable"}
      $ok2 = Test-Path "\\$dc\NETLOGON"
      if (!$ok2) {Write-Warning "[failure] '\\$dc\NETLOGON' not reachable"}
      if(-not($ok1 -and $ok2)){ $bad += $dc.HostName }
    }
    $pass = ($bad.Count -eq 0)
    if($pass){Write-Warning "[pass] All DCs have reachable SYSVOL & NETLOGON"}
}

<#
.SYNOPSIS
Ensures AD schema objectVersion matches across all DCs.

.DESCRIPTION
Reads objectVersion from the Schema NC via each DC and normalizes to [int].
Passes if there is exactly one distinct version. Returns details per-DC and a summary.
#>
function HealthTest-SchemaVersionConsistency{
  $schemaNC=(Get-ADRootDSE).schemaNamingContext
  $vers=@{}; $errs=@()
  foreach($dc in (Get-ADDomainController -Filter *)){
    try{
      $ov=(Get-ADObject -Identity $schemaNC -Server $dc.HostName -Properties objectVersion -ErrorAction Stop).objectVersion
      if($null -eq $ov -or "$ov" -eq ''){
        $msg="$($dc.HostName): objectVersion missing"; $errs+=$msg; Write-Warning "[failure] $($msg)"; continue
      }
      $ov=[int]("$ov".Trim()); $vers[$dc.HostName]=$ov
    }catch{
      $msg="$($dc.HostName): $($_.Exception.Message)"; $errs+=$msg; Write-Warning "[failure] $($msg)"
    }
  }

  if($vers.Count -eq 0){
    Write-Warning "[failure] $("AD schema version consistency")`n$(("No schema versions retrieved. Errors: "+($errs -join ' | ')))"
    return
  }

  # Force array so .Count and [0] are always valid even when only one element
  $distinct = @($vers.Values | Sort-Object -Unique)
  $distinctCount = $distinct.Count

  $perDc = ($vers.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; '

  $det = if ($distinctCount -eq 1) {
    "SchemaVersion=$($distinct[0]); $perDc"
  } else {
    "Mismatch: "+($distinct -join ', ')+" | "+$perDc
  }

  if($errs){ $det += " | Errors: "+($errs -join ' | ') }

  $pass = ($distinctCount -eq 1 -and $errs.Count -eq 0)

  if($pass){
    Write-Warning "[pass] AD schema version consistent across DCs ($det)"
  } else {
    Write-Warning "[failure] $("AD schema version consistent across DCs")`n$($det)"
  }
}

<#
.SYNOPSIS
Verifies NTDS.dit and log paths are on intended volumes.
.DESCRIPTION
Reads NTDS parameters and returns their current locations.
#>
function HealthTest-NtdsPathsLocation{
  [CmdletBinding()]
  param(
    [string[]]$ExpectedDbRoots,
    [string[]]$ExpectedLogRoots
  )
  $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
  $db = (Get-ItemProperty -Path $regPath -Name 'DSA Database file' -ErrorAction Stop).'DSA Database file'
  $lg = (Get-ItemProperty -Path $regPath -Name 'Database log files path' -ErrorAction Stop).'Database log files path'

  $dbOk = if($ExpectedDbRoots -and $ExpectedDbRoots.Count){
    ($ExpectedDbRoots | Where-Object { $db -like "$_*" -or ([IO.Path]::GetPathRoot($db) -eq $_) }).Count -gt 0
  } else { $true }
  if(-not $dbOk){ Write-Warning "[failure] NTDS database path not on an expected volume`nDB=$db; Expected roots: $($ExpectedDbRoots -join ', ')" }

  $lgOk = if($ExpectedLogRoots -and $ExpectedLogRoots.Count){
    ($ExpectedLogRoots | Where-Object { $lg -like "$_*" -or ([IO.Path]::GetPathRoot($lg) -eq $_) }).Count -gt 0
  } else { $true }
  if(-not $lgOk){ Write-Warning "[failure] NTDS log path not on an expected volume`nLOGS=$lg; Expected roots: $($ExpectedLogRoots -join ', ')" }

  if($dbOk -and $lgOk){ Write-Warning "[pass] NTDS database/log paths sane (DB=$db; LOGS=$lg)" }
}

<#
.SYNOPSIS
Checks tombstoneLifetime and links interval sanity.
#>
function HealthTest-TombstoneLifetime{
  [CmdletBinding()] param([int]$MinDays=60)
  $ds="CN=Directory Service,CN=Windows NT,CN=Services,$((Get-ADRootDSE).ConfigurationNamingContext)"
  $tl=(Get-ADObject $ds -Properties tombstoneLifetime).tombstoneLifetime
  if(-not $tl){$tl=60}
  if($tl -ge $MinDays){ Write-Warning "[pass] AD tombstoneLifetime is sufficient ($tl days >= $MinDays)" }
  else{ Write-Warning "[failure] AD tombstoneLifetime below threshold`nCurrent=$tl; Min=$MinDays" }
}

<#
.SYNOPSIS
Confirms AD Recycle Bin is enabled.
#>
function HealthTest-RecycleBinEnabled{
  $f=Get-ADOptionalFeature 'Recycle Bin Feature' -ErrorAction Stop
  $enabled=($f.EnabledScopes -ne $null -and $f.EnabledScopes.Count -gt 0)
  if($enabled){ Write-Warning "[pass] AD Recycle Bin enabled" } else { Write-Warning "[notice] AD Recycle Bin is not enabled -- consider enabling it." }
}

<#
.SYNOPSIS
Verifies domain trusts and performs netdom /verify.
#>
function HealthTest-TrustsVerify{
  $trusts=Get-ADTrust -Filter * -ErrorAction Stop
  if(-not $trusts){ Write-Warning "[pass] No inter-domain trusts configured"; return }
  $bad=$false
  foreach($t in $trusts){
    $r=& netdom.exe trust $t.TargetName /domain:$($t.Source) /verify 2>&1
    if($LASTEXITCODE -ne 0){ $bad=$true; Write-Warning "[failure] Trust verification failed`n$($t.Source) -> $($t.TargetName): $r" }
  }
  if(-not $bad){ Write-Warning "[pass] All domain trusts verify successfully" }
}

<#
.SYNOPSIS
Checks replication latency on schema/config partitions.
#>
function HealthTest-ReplicationLatency{
  [CmdletBinding()] param([int]$MaxMinutes=30)
  $parts=@((Get-ADRootDSE).schemaNamingContext,(Get-ADRootDSE).configurationNamingContext)
  $anyFail=$false
  foreach($dc in (Get-ADDomainController -Filter *)){
    foreach($p in $parts){
      $m=Get-ADReplicationPartnerMetadata -Target $dc.HostName -Partition $p -ErrorAction Stop
      foreach($row in $m){
        $mins = [int](((Get-Date)-$row.LastReplicationSuccess).TotalMinutes)
        if($mins -gt $MaxMinutes){ $anyFail=$true; Write-Warning "[failure] Replication latency above threshold`n$($dc.HostName) partition '$p' latency=$mins min (Max=$MaxMinutes)" }
      }
    }
  }
  if(-not $anyFail){ Write-Warning "[pass] AD replication latency acceptable (<= $MaxMinutes min on schema/config)" }
}

<#
.SYNOPSIS
Validates DNS zone replication scope for AD-integrated zones.
#>
function HealthTest-DnsZoneReplicationScope{
  $zones = Get-DnsServerZone -ErrorAction Stop | Where-Object { $_.IsDsIntegrated }
  if(-not $zones){ Write-Warning "[pass] No AD-integrated zones present"; return }
  $lines = ($zones | ForEach-Object { "{0}:{1}" -f $_.ZoneName, $_.ReplicationScope })
  Write-Warning ("[pass] DNS zone replication scope reviewed`n" + ($lines -join '; '))
}

<#
.SYNOPSIS
Confirms some important SRV records exist:
_ldap._tcp.dc._msdcs.<domain> = where are the Domain Controllers (LDAP over TCP)?
_kerberos._tcp.<domain> = where are Kerberos KDCs over TCP?
_kerberos._udp.<domain> = where are Kerberos KDCs over UDP?
#>
function HealthTest-RequiredSrvRecords{
  $dom=(Get-CimInstance Win32_ComputerSystem).Domain
  $labels=@("_ldap._tcp.dc._msdcs.$dom","_kerberos._tcp.$dom","_kerberos._udp.$dom")
  $missing=$false
  foreach($q in $labels){
    try{ $r=Resolve-DnsName -Type SRV $q -ErrorAction Stop }catch{$r=$null}
    if(-not $r){ $missing=$true; Write-Warning "[failure] $("Required SRV record missing")`n$($q)" }
  }
  if(-not $missing){ Write-Warning "[pass] Required AD SRV records present" }
}

<#
.SYNOPSIS
Checks DNS scavenging/aging configuration (server + per-zone).
.DESCRIPTION
Returns Pass=$true only if server scavenging is enabled AND all AD-integrated primary zones have AgingEnabled=$true.
Details list server state and zones with/without aging.
#>
function HealthTest-DnsScavenging{
  $sv = Get-DnsServerScavenging -ErrorAction Stop
  $zones = Get-DnsServerZone -ErrorAction Stop | Where-Object { $_.IsDsIntegrated -and $_.ZoneType -eq 'Primary' }
  $comment = "Severity: Medium.`nWhat it means: Server-level scavenging is off, so stale dynamic records never age out.`nRisk: Stale A/PTR clutter, service discovery problems, and opportunities for name re-use confusion. In secure-updates AD zones, outright hijack is harder, but operational pain is real."

  $flagged=$false
  if(-not $sv.ScavengingState){ $flagged=$true; Write-Warning "[warning] $("DNS server scavenging is disabled")`n$($comment)" }

  foreach($z in $zones){
    $ai = $null; try { $ai = Get-DnsServerZoneAging -Name $z.ZoneName -ErrorAction Stop } catch {}
    if(-not ($ai -and $ai.AgingEnabled)){ $flagged=$true; Write-Warning "[warning] DNS zone aging is disabled`nzone: $($z.ZoneName) `nNote that scavenging must be enabled both at the server level and at the zone`n$comment"}
  }

  if(-not $flagged){
    $on=@($zones | ForEach-Object { $_.ZoneName })
    Write-Warning "[pass] $("DNS scavenging configured on server and zones")`n$(("Zones: " + ($on -join ', ')))"
  }
}

<#
.SYNOPSIS
Validates DNS forwarders reachability and forbids loopback.
#>
function HealthTest-DnsForwarders{
  $f=Get-DnsServerForwarder -ErrorAction Stop
  if(-not $f -or -not $f.IPAddress){ Write-Warning "[pass] No DNS forwarders configured"; return }
  $ips=$f.IPAddress
  $bad=$false
  foreach($ip in $ips){
    if(($ip -eq '127.0.0.1') -or ($ip -eq '::1')){ $bad=$true; Write-Warning "[failure] $("Loopback address is configured as a DNS forwarder")`n$($ip)"; continue }
    $ok=(Test-Connection -ComputerName $ip -Count 1 -Quiet)
    if(-not $ok){ $bad=$true; Write-Warning "[failure] $("DNS forwarder not reachable")`n$($ip)" }
  }
  if(-not $bad){ Write-Warning "[pass] $("DNS forwarders sane & reachable")`n$(("Forwarders: " + ($ips -join ', ')))" }
}

<#
.SYNOPSIS
Ensures LDAP signing and channel binding settings are enforced.
#>
function HealthTest-LdapSigningChannelBinding {
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'

    # Read all registry values in one shot (avoids repeated calls)
    $props = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue

    # LDAPServerIntegrity
    $signProp = $props.PSObject.Properties['LDAPServerIntegrity']
    $sign     = if ($signProp) { $signProp.Value } else { $null }

    # LdapEnforceChannelBinding
    $cbProp = $props.PSObject.Properties['LdapEnforceChannelBinding']
    $cb     = if ($cbProp) { $cbProp.Value } else { $null }

    # Bonus tip: normalize null -> 0 (disabled)
    $sign = [int]($sign + 0)
    $cb   = [int]($cb   + 0)

    if (($sign -ge 1) -and ($cb -ge 1)) {
        Write-Warning "[pass] LDAP signing & channel binding enforced"
    } else {
        Write-Warning "[notice] LDAP signing and/or channel binding not enforced`nLDAPServerIntegrity=$sign; LdapEnforceChannelBinding=$cb"
    }
}

<#
.SYNOPSIS
Requires SMB signing on the server.
#>
function HealthTest-SmbSigningRequired{
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

# TODO this test is repeated in HealthTest-ShareReasonableness
<#
.SYNOPSIS
Verifies SMBv1 is disabled.
#>
function HealthTest-Smb1Disabled{
  $f=Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -ErrorAction SilentlyContinue
  $state=$f.State
  $disabled=($state -eq 'Disabled' -or -not $f -or $state -eq 'DisabledWithPayloadRemoved')
  if($disabled){ Write-Warning "[pass] SMBv1 is disabled" } else { Write-Warning "[warning] SMBv1 is enabled`nState=$state" }
}

<#
.SYNOPSIS
Finds accounts with unconstrained delegation (excludes DCs by default).

.DESCRIPTION
Flags user/computer objects where userAccountControl has TRUSTED_FOR_DELEGATION (0x80000).
By default excludes Domain Controllers (SERVER_TRUST_ACCOUNT 0x2000), since DCs are inherently trusted.
Use -IncludeDomainControllers to include them in the results.
#>
function HealthTest-UnconstrainedDelegationAccounts{
  [CmdletBinding()] param([switch]$IncludeDomainControllers)

  $bitTrusted  = 524288    # 0x80000 TRUSTED_FOR_DELEGATION
  $bitDC       = 8192      # 0x2000  SERVER_TRUST_ACCOUNT

  if ($IncludeDomainControllers) {
    $ldap = "(&(|(objectClass=user)(objectClass=computer))(userAccountControl:1.2.840.113556.1.4.803:=$bitTrusted))"
  } else {
    $ldap = "(&(|(objectClass=user)(objectClass=computer))(userAccountControl:1.2.840.113556.1.4.803:=$bitTrusted)(!(userAccountControl:1.2.840.113556.1.4.803:=$bitDC)))"
  }

  $objs = @(
    Get-ADObject -LDAPFilter $ldap -Properties sAMAccountName,objectClass,dnsHostName |
      Select-Object sAMAccountName,objectClass,dnsHostName
  )

  if ($objs.Count -gt 0) {

    foreach($o in $objs){

      # Determine if computer object (objectClass may be array or string)
      $isComputer = $false
      if ($o.objectClass -is [array]) {
        if ($o.objectClass -contains 'computer') { $isComputer = $true }
      } elseif ($o.objectClass -eq 'computer') {
        $isComputer = $true
      }

      # Build a friendly name
      if ($isComputer) {
        $name = $o.sAMAccountName.TrimEnd('$')
        if ($o.dnsHostName) {
          $name += " ($($o.dnsHostName))"
        }
        $cls = 'computer'
      } else {
        $name = $o.sAMAccountName
        $cls  = 'user'
      }

      Write-Warning "[failure] Unconstrained delegation account found`n$($cls): $name"
    }

  } else {
    Write-Warning "[pass] No unconstrained delegation accounts"
  }
}

<#
.SYNOPSIS
Flags service accounts with PasswordNeverExpires.
#>
function HealthTest-ServiceAccountsPwdNeverExpires{
  $filter='(servicePrincipalName=*)'
  $objs=Get-ADUser -LDAPFilter $filter -Properties PasswordNeverExpires,PasswordLastSet
  $bad=@($objs | Where-Object {$_.PasswordNeverExpires -eq $true})
  if($bad.Count -gt 0){
    foreach($u in $bad){ Write-Warning "[failure] $("Service account password set to never expire")`n$($u.SamAccountName)" }
  } else {
    Write-Warning "[pass] Service accounts have expiring passwords"
  }
}

<#
.SYNOPSIS
Checks anonymous access hardening against modern baselines.

.DESCRIPTION
Pass when:
  - RestrictAnonymousSAM = 1  (Do not allow anonymous enumeration of SAM accounts)
  - EveryoneIncludesAnonymous = 0 (Anonymous not included in Everyone)
RestrictAnonymous (legacy 'SAM and shares') is informational:
  - 0 (baseline) -> OK
  - 1 (stricter) -> Warn: may break legacy browsing/trust; rarely needed today
  - 2 -> Obsolete/unsupported on modern Windows; treat as warn/fail
#>
function HealthTest-RestrictAnonymous {
  $p  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
  $ra = (Get-ItemProperty $p -Name restrictanonymous      -ErrorAction SilentlyContinue).restrictanonymous
  $rs = (Get-ItemProperty $p -Name restrictanonymoussam   -ErrorAction SilentlyContinue).restrictanonymoussam
  $ea = (Get-ItemProperty $p -Name EveryoneIncludesAnonymous -ErrorAction SilentlyContinue).EveryoneIncludesAnonymous

  $pass = ($rs -eq 1 -and $ea -eq 0)
  $details="RestrictAnonymous=$ra; RestrictAnonymousSAM=$rs; EveryoneIncludesAnonymous=$ea"

  if($pass){
    Write-Warning "[pass] $("Anonymous access hardening (baseline met)")`n$($details)"
  } else {
    Write-Warning "[failure] Anonymous access hardening not at baseline`n$details. Recommendation: Set RestrictAnonymousSAM=1 and EveryoneIncludesAnonymous=0 via GPO."
  }
}

<#
.SYNOPSIS
Checks that a pagefile exists and meets a minimum size.

.DESCRIPTION
Handles both explicit and system-managed pagefiles.
- Primary source: Win32_PageFileUsage (current allocated size).
- Fallback: 'PagingFiles' registry (C:\pagefile.sys 0 0 means system-managed).
Pass=$true when total AllocMB >= MinMB, and (optionally) one pagefile is on the system drive.
#>
function HealthTest-PagefileSanity{
  [CmdletBinding()] param([int]$MinMB=1024,[switch]$RequireOnSystemDrive)
  $cs   = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
  $auto = $cs.AutomaticManagedPagefile
  $usage = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
  $regPath='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
  $pfReg=(Get-ItemProperty -Path $regPath -Name PagingFiles -ErrorAction SilentlyContinue).PagingFiles

  $entries=@()
  if($usage){
    foreach($u in $usage){ $entries += [pscustomobject]@{Name=$u.Name;AllocMB=[int]$u.AllocatedBaseSize;CurrMB=[int]$u.CurrentUsage} }
  }
  if(-not $entries -and $pfReg){
    foreach($line in $pfReg){
      $parts=$line -split '\s+'
      if($parts.Length -ge 1){
        $name=$parts[0]; $min= if($parts.Length -ge 2){ [int]$parts[1] } else { 0 }
        $entries += [pscustomobject]@{Name=$name;AllocMB=$min;CurrMB=$null}
      }
    }
  }

  if(-not $entries){
    Write-Warning "[failure] $("No pagefile detected")`n$(("AutomaticManagedPagefile="+[int]$auto))"
    return
  }

  $sumAlloc=($entries | Measure-Object AllocMB -Sum).Sum
  $okSize = ($sumAlloc -ge $MinMB)
  $okSys  = $true
  if($RequireOnSystemDrive){
    $sys = $env:SystemDrive  # Typically 'C:'
    $okSys = (($entries | Where-Object {$_.Name -like "$sys\*"}).Count -gt 0)
    if(-not $okSys){ Write-Warning "[failure] No pagefile on system drive`nSystemDrive=$sys; Entries="+(($entries | ForEach-Object {"$($_.Name):$($_.AllocMB)MB"}) -join ', ') }
  }
  if(-not $okSize){ Write-Warning "[failure] Total pagefile size below threshold`nTotalAllocMB=$sumAlloc; MinMB=$MinMB" }

  if($okSize -and $okSys){
    Write-Warning ("[pass] Paging file configured sensibly`n" + ("Auto="+[int]$auto+"; TotalAllocMB=$sumAlloc; Entries="+(($entries | ForEach-Object {"$($_.Name):$($_.AllocMB)MB"}) -join ', ')))
  }
}

<#
.SYNOPSIS
Confirms WinRM is running and responsive.
#>
function HealthTest-WinRMListening{
  $svc=Get-Service WinRM -ErrorAction Stop
  if($svc.Status -ne 'Running'){ Write-Warning "[failure] WinRM service is not running`nStatus=$($svc.Status)"; return }
  try{ $null=Test-WSMan -ErrorAction Stop; Write-Warning "[pass] WinRM running and responding" }
  catch{ Write-Warning "[failure] $("WinRM not responding")`n$($_.Exception.Message)" }
}

<#
.SYNOPSIS
Verifies IPv6 binding state per policy (PS5.1-safe).
#>
function HealthTest-IPv6Binding{
  [CmdletBinding()] param([switch]$RequireEnabled)
  $rows = Get-NetAdapterBinding -ComponentID ms_tcpip6 | Select-Object Name,Enabled
  if(-not $rows){ Write-Warning "[failure] No adapters returned for IPv6 binding (ms_tcpip6)"; return }
  $bad=$false
  if($RequireEnabled){
    foreach($r in $rows){
      if(-not $r.Enabled){ $bad=$true; Write-Warning "[failure] $("IPv6 disabled on adapter")`n$($r.Name)" }
    }
    if(-not $bad){ Write-Warning "[pass] IPv6 enabled on all adapters" }
  } else {
    Write-Warning ("[pass] IPv6 binding state reported`n" + (($rows | ForEach-Object { "$($_.Name)=$($_.Enabled)" }) -join '; '))
  }
}

<#
.SYNOPSIS
Verifies DNS Client service is running.
#>
function HealthTest-DnsClientService{
  $s=Get-Service Dnscache -ErrorAction Stop
  if($s.Status -eq 'Running'){ Write-Warning "[pass] DNS Client service running" } else { Write-Warning "[failure] DNS Client service is not running`nStatus=$($s.Status)" }
}

<#
.SYNOPSIS
Verifies WMI repository consistency.
#>
function HealthTest-WmiRepository{
  $out=& winmgmt /verifyrepository 2>&1
  $ok=($out -match 'consistent')
  if($ok){ Write-Warning "[pass] WMI repository consistent" } else { Write-Warning "[failure] $("WMI repository inconsistent")`n$(($out -join ' '))" }
}

<#
.SYNOPSIS
Lists VSS writers and flags non-stable states.
#>
function HealthTest-VssWriters{
  $out=& vssadmin list writers 2>&1
  $bad=($out | Select-String -Pattern 'State: \d+ \((?i:Retryable error|Waiting for completion|Failed)\)')
  if($bad){
    foreach($b in $bad){ Write-Warning "[failure] $("VSS writer not healthy")`n$($b.Line)" }
  } else {
    Write-Warning "[pass] All VSS writers report stable states"
  }
}

<#
.SYNOPSIS
Checks shadow storage presence and size info.
#>
function HealthTest-ShadowStorage{
  [CmdletBinding()] param(
    [string[]]$RequireOnVolumes = @()   # e.g. 'D:','E:'; empty = informational only
  )
  $assoc = Get-CimInstance -ClassName Win32_ShadowStorage 2>$null
  $vols  = Get-CimInstance -ClassName Win32_Volume | Select-Object DeviceID, DriveLetter

  $present = @{}
  if ($assoc) {
    foreach($a in $assoc){
      $volRef = [string]$a.Volume
      $devId  = $null
      if ($volRef -match 'DeviceID="([^"]+)"') { $devId = $Matches[1] }
      if ($devId) { $devId = ($devId -replace '\\\\','\') }
      $drive = $null
      if ($devId -and ($devId -match '^[A-Z]:\\')) {
        $drive = $devId.Substring(0,2)
      } else {
        if ($devId) {
          $m = $vols | Where-Object { $_.DeviceID -eq $devId }
          if ($m -and $m.DriveLetter) { $drive = $m.DriveLetter }
        }
      }
      if (-not $drive) { $drive = $devId }
      if ($drive) { $present[$drive.TrimEnd('\')] = $true }
    }
  }

  if ($RequireOnVolumes.Count -gt 0) {
    $missing = @()
    foreach($v in $RequireOnVolumes){
      $k = $v.TrimEnd('\')
      if (-not $present.ContainsKey($k)) { $missing += $k; Write-Warning "[failure] $("Shadow storage not configured on required volume")`n$($k)" }
    }
    if($missing.Count -eq 0){
      Write-Warning ("[pass] Shadow storage on required volumes`nConfigured on: " + ((@($present.Keys) | Sort-Object) -join ', '))
    }
  } else {
    if ($present.Count -gt 0) {
      Write-Warning ("[pass] Shadow storage configured`nOn: " + ((@($present.Keys) | Sort-Object) -join ', '))
    } else {
      Write-Warning "[notice] Shadow storage (Volume Shadow Copies) is not enabled`nUsers won't see Previous Version for files/folders. (Note that this issue is UNRELATED to the VSS service that backup software use.)"
    }
  }
}

<#
.SYNOPSIS
Scrapes common auto-start locations for rogues.
#>
function HealthTest-StartupItems{
  $paths=@(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
  )
  $items=@()
  foreach($p in $paths){
    if(Test-Path $p){
      $props=Get-ItemProperty $p
      $props.PSObject.Properties | Where-Object { $_.Name -notin 'PSPath','PSParentPath','PSChildName','PSDrive','PSProvider' } | ForEach-Object {
        $items += "$p -> $($_.Name)=$($_.Value)"
      }
    }
  }
  if($items.Count -gt 0){
    Write-Warning ("[pass] Startup items reviewed`n" + ($items -join '; '))
  } else {
    Write-Warning "[pass] No startup items found in standard keys"
  }
}

<#
.SYNOPSIS
Detects duplicate SPNs by querying AD directly (no setspn parsing).

.DESCRIPTION
Enumerates all directory objects that have servicePrincipalName, groups by SPN,
and flags any SPN that appears on more than one distinct object.

RETURNS
[pscustomobject]@{ Pass=bool; Details=string }
#>
function HealthTest-DuplicateSpn{
  $objs = Get-ADObject -LDAPFilter "(servicePrincipalName=*)" -Properties servicePrincipalName,sAMAccountName,distinguishedName -ErrorAction Stop
  if(-not $objs){ Write-Warning "[pass] No objects with SPN found"; return }

  $map = @{}
  foreach($o in $objs){
    $acct = if($o.sAMAccountName){ $o.sAMAccountName } else { $o.distinguishedName }
    foreach($spn in @($o.servicePrincipalName)){
      if([string]::IsNullOrEmpty($spn)){ continue }
      if($map.ContainsKey($spn)){ $map[$spn] += $acct } else { $map[$spn] = @($acct) }
    }
  }

  $dupsFound=$false
  foreach($spn in $map.Keys){
    $owners = @($map[$spn] | Sort-Object -Unique)
    if($owners.Count -gt 1){
      $dupsFound=$true
      Write-Warning "[failure] $("Duplicate SPN detected")`n$(("$spn -> " + ($owners -join ', ')))"
    }
  }
  if(-not $dupsFound){ Write-Warning "[pass] No duplicate SPNs detected" }
}


function Test-MultipleGatewayConfiguration {
<#
.SYNOPSIS
  Validates multi-default-gateway setup and reports good/bad.

.DESCRIPTION
  When multiple IPv4 default routes (0.0.0.0/0) exist, compares TotalMetric
  (RouteMetric + InterfaceMetric) to ensure there is a single clear winner and
  that AutomaticMetric is sensibly configured. Emits Log-Info on good setups,
  or Log-Failure with hints on problems. Includes verbose/debug traces.

.NOTES
  Requires NetTCPIP module (Get-NetRoute/Get-NetIPInterface).
  Uses external Log-Info / Log-Failure helpers.
#>
  [CmdletBinding()]
  param()

  Write-Verbose "[Test-MultipleGatewayConfiguration] Gathering active IPv4 default routes..."
  $routes = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.NextHop -and ($_.State -eq 'Active' -or -not $_.State) }

  if (-not $routes -or $routes.Count -lt 2) {
    Write-Verbose "[Test-MultipleGatewayConfiguration] Fewer than 2 default routes; nothing to validate."
    return
  }

  write-verbose ("[DBG] Raw routes:`n" + (
      $routes | Select ifIndex,InterfaceAlias,NextHop,RouteMetric,InterfaceMetric,State |
      Format-Table -AutoSize | Out-String
  ))

  $table = $routes |
    Select-Object InterfaceAlias,ifIndex,NextHop,RouteMetric,InterfaceMetric,
      @{n='TotalMetric';e={($_.RouteMetric + $_.InterfaceMetric)}} |
    Sort-Object TotalMetric, InterfaceAlias

  write-verbose ("[DBG] Computed table (TotalMetric=Route+Interface):`n" + (
      $table | Format-Table InterfaceAlias,NextHop,RouteMetric,InterfaceMetric,TotalMetric -AutoSize | Out-String
  ))

  $ifAliases = $table.InterfaceAlias | Select-Object -Unique
  $ifInfo = Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $ifAliases -contains $_.InterfaceAlias } |
            Select-Object InterfaceAlias,AutomaticMetric,InterfaceMetric,ConnectionState

  write-verbose ("[DBG] Interface metrics:`n" + (
      $ifInfo | Format-Table InterfaceAlias,AutomaticMetric,InterfaceMetric,ConnectionState -AutoSize | Out-String
  ))

  $best  = $table | Select-Object -First 1
  $worst = $table | Select-Object -Last 1
  $ties  = @($table | Where-Object { $_.TotalMetric -eq $best.TotalMetric }).Count

  $autoOk = (@($ifInfo | Where-Object { $_.AutomaticMetric -eq $true }).Count -eq $ifInfo.Count)
  $allUp  = (@($ifInfo | Where-Object { $_.ConnectionState -eq 'Connected' }).Count -eq $ifInfo.Count)

  write-verbose ("[DBG] Best route: {0} -> {1} (TotalMetric={2})" -f $best.InterfaceAlias,$best.NextHop,$best.TotalMetric)
  write-verbose ("[DBG] Worst route: {0} -> {1} (TotalMetric={2})" -f $worst.InterfaceAlias,$worst.NextHop,$worst.TotalMetric)
  write-verbose ("[DBG] Ties on best metric: {0}" -f $ties)
  write-verbose ("[DBG] AutomaticMetric OK on all?: {0}" -f $autoOk)
  write-verbose ("[DBG] All interfaces connected?: {0}" -f $allUp)

  $list = (( $table | ForEach-Object { "$($_.InterfaceAlias)->$($_.NextHop) (metric=$($_.TotalMetric))" } ) -join ', ')
  $desc = "Detected multiple default gateways: $list. Preferred: $($best.InterfaceAlias)."

  # Good if exactly one best metric AND (all AutomaticMetric enabled OR strictly lower best metric)
  $good = (($ties -eq 1) -and ( $autoOk -or ($best.TotalMetric -lt $worst.TotalMetric) ))

  if ($good) {
    $note = ""
    if (-not $allUp) { $note = " Note: one or more interfaces not Connected; failover may be impaired." }
    Write-Warning "[info] Gateway Configuration looks fine - Windows will prefer $($best.InterfaceAlias).$note"
  } else {
    $hints = @()
    if ($ties -gt 1) { $hints += "Multiple routes share the same lowest TotalMetric (tie)"; }
    if (-not $autoOk) {
      $offenders = ($ifInfo | Where-Object { -not $_.AutomaticMetric } | Select-Object -ExpandProperty InterfaceAlias) -join ', '
      if ($offenders) { $hints += ("AutomaticMetric is disabled on: " + $offenders) }
    }
    if ($best.TotalMetric -ge $worst.TotalMetric) { $hints += "No strictly lower preferred metric found" }
    if (-not $allUp) { $hints += "One or more interfaces not Connected" }
    $hintText = if ($hints.Count) { " Hints: " + ($hints -join '; ') + "." } else { "" }

    Write-Warning "[failure] Multiple Gateways with metrics that may cause routing instability.`n$desc`n$hintText"
  }
}

<#
.SYNOPSIS
Ensures the host does not have multiple default gateways.

.DESCRIPTION
Collects IPv4/IPv6 default gateways from Get-NetIPConfiguration. By default Pass=$true only if the
total count of default gateways (v4+v6) <= 1. Use -AllowOnePerFamily to permit up to one v4 and one v6.
#>
function HealthTest-SingleDefaultGateway{
  [CmdletBinding()] param([switch]$AllowOnePerFamily)
  $cfg = Get-NetIPConfiguration
  $gws = @(
    $cfg | ForEach-Object {
      if ($_.IPv4DefaultGateway) { $_.IPv4DefaultGateway }
      if ($_.IPv6DefaultGateway) { $_.IPv6DefaultGateway }
    }
  )
  $nextHops = @($gws | ForEach-Object { $_.NextHop } | Where-Object { $_ })

  if ($AllowOnePerFamily) {
    $v4 = @($nextHops | Where-Object { $_ -notmatch ':' }).Count
    $v6 = @($nextHops | Where-Object { $_ -match ':' }).Count
    if(($v4 -le 1) -and ($v6 -le 1)){
        Write-Warning "[pass] Default gateways: at most one per IP family"
    } else {
        if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 2) { # server -- always considered a failure
            Write-Warning "[failure] Multiple default gateways detected per IP family`nIPv4=$v4; IPv6=$v6; Gateways=$(($nextHops) -join ', ')"
        } else { # workstation
            Test-MultipleGatewayConfiguration
        }
    }
  } else {
    if($nextHops.Count -le 1){
      Write-Warning "[pass] Default gateways: at most one overall"
    } else {
        if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 2) { # server -- always considered a failure
            Write-Warning "[failure] Multiple default gateways configured`nGateways=$(($nextHops) -join ', ')"
        } else { # workstation
            Test-MultipleGatewayConfiguration
        }
    }
  }
}

<#
.SYNOPSIS
Checks for stale/mismatched DC DNS A records vs. AD DC IPs. OnlyForDCs
#>
function HealthTest-DcDnsARecords{
  $bad=@()
  foreach($dc in (Get-ADDomainController -Filter *)){
    $hn=$dc.HostName; $ip=$dc.IPv4Address
    if(-not $hn -or -not $ip){ continue }
    $ares=(Resolve-DnsName -Name $hn -Type A -ErrorAction SilentlyContinue).IPAddress
    if(-not $ares){ $msg="$hn has no A records in DNS"; $bad+=$msg; Write-Warning "[failure] $($msg)"; continue }
    if($ares -notcontains $ip){ $msg="$hn A record mismatch: AD IP=$ip, DNS IPs="+($ares -join ','); $bad+=$msg; Write-Warning "[failure] $($msg)" }
  }
  if($bad.Count -eq 0){ Write-Warning "[pass] DC DNS A records match AD IPs for all DCs" }
}

<#
.SYNOPSIS
Validates DNS recursion configuration (enabled/forwarders/EDNS). OnlyForDCs
#>
function HealthTest-DnsRecursionConfig {
    if (-not (Get-Command Get-DnsServerRecursion -ErrorAction SilentlyContinue)) {
        Write-Warning "[notice] DNS Server tools not available`nDNS role/RSAT missing?"
        return
    }

    $rec   = Get-DnsServerRecursion -ErrorAction SilentlyContinue
    $cache = Get-DnsServerCache     -ErrorAction SilentlyContinue
    $edns  = Get-DnsServerEDns      -ErrorAction SilentlyContinue

    $recEnabled = $null
    if ($rec) {
        $p = $rec.PSObject.Properties['EnableRecursion']
        if ($p) { $recEnabled = $p.Value }
    }

    $maxTtl = $null
    if ($cache) {
        $p = $cache.PSObject.Properties['MaxTTL']
        if ($p) { $maxTtl = $p.Value }
    }

    $ecsEnabled = $null
    if ($edns) {
        $p = $edns.PSObject.Properties['EnableEcsClientSubnet']
        if ($p) { $ecsEnabled = $p.Value }
    }

    # --- Normalize for output ---
    if ($recEnabled -ne $null) { $recText = [string]$recEnabled } else { $recText = 'n/a' }

    if ($maxTtl -ne $null) {
        if ($maxTtl -is [TimeSpan]) {
            $ttlText = ("{0}s" -f [int][Math]::Round($maxTtl.TotalSeconds))
        } elseif ($maxTtl -is [int] -or $maxTtl -is [long]) {
            $ttlText = ("{0}s" -f $maxTtl)
        } else {
            $ttlText = [string]$maxTtl
        }
    } else {
        $ttlText = 'n/a'
    }

    if ($ecsEnabled -ne $null) { $ecsText = [string]$ecsEnabled } else { $ecsText = 'n/a' }

    if ($rec -or $cache -or $edns) {
        Write-Warning (("[pass] No issues found in the DNS recursion configuration`nEnableRecursion={0}; MaxTTL={1}; EDNS-ECS={2}" `
                    -f $recText, $ttlText, $ecsText))
    } else {
        Write-Warning "[notice] Unable to read DNS recursion configuration on this host`nHost is probably not a DNS server"
    }
}


<#
.SYNOPSIS
Confirms reverse lookup zones exist for known subnets. OnlyForDCs
#>
function HealthTest-ReverseZonesPresent{
  [CmdletBinding()] param([string[]]$ExpectedReverseZones)
  $zones=Get-DnsServerZone | Where-Object {$_.IsReverseLookupZone} | Select-Object -ExpandProperty ZoneName
  if(-not $ExpectedReverseZones){ Write-Warning "[pass] $(("Reverse zones present: "+(($zones -join ', ')-replace '^$','<none>')))"; return }
  $missing=@()
  foreach($z in $ExpectedReverseZones){
    if($zones -notcontains $z){ $missing+=$z; Write-Warning "[failure] Reverse zone missing: $z" }
  }
  if($missing.Count -eq 0){ Write-Warning "[pass] All expected reverse zones are present" }
}

<#
.SYNOPSIS
Checks GC placement (at least one per site or per-domain policy). OnlyForDCs
#>
function HealthTest-GcPlacement{
  [CmdletBinding()] param([switch]$AtLeastOnePerSite=$true)
  $dcs=Get-ADDomainController -Filter *
  if(-not $AtLeastOnePerSite){
    $has=($dcs | Where-Object {$_.IsGlobalCatalog}).Count -gt 0
    if($has){ Write-Warning "[pass] At least one Global Catalog exists in the domain" } else { Write-Warning "[failure] No Global Catalog server detected in the domain" }
    return
  }
  $sites=$dcs | Group-Object Site
  $bad=@()
  foreach($s in $sites){
    if(($s.Group | Where-Object {$_.IsGlobalCatalog}).Count -eq 0){ $bad+=$s.Name; Write-Warning "[failure] No Global Catalog in site '$($s.Name)'" }
  }
  if($bad.Count -eq 0){ Write-Warning "[pass] Each AD site has at least one Global Catalog" }
}

<#
.SYNOPSIS
Checks AdminSDHolder applied to protected groups reasonably. OnlyForDomainServers
#>
function HealthTest-AdminSDHolderCoverage{
  $prot=Get-ADUser -LDAPFilter '(adminCount=1)' -Properties MemberOf | Select-Object -ExpandProperty SamAccountName
  if($prot){ Write-Warning "[pass] AdminSDHolder applied; protected users: $($prot -join ", ")" } else { Write-Warning "[pass] No users currently protected by AdminSDHolder" }
}

<#
.SYNOPSIS
DFSR backlog for SYSVOL within threshold. OnlyForDCs
.NOTES Stesses Network: Potentially noticeable on the WAN if run frequently or in parallel
#>
function HealthTest-DfsrBacklogSysvol{
  [CmdletBinding()] param([int]$MaxBacklog=100)
  $group='Domain System Volume'; $folder='SYSVOL Share'
  $dcs=Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName
  $bad=$false
  foreach($dc in $dcs){
    foreach($peer in $dcs){
      if($dc -eq $peer){continue}
      $b=Get-DfsrBacklog -GroupName $group -FolderName $folder -SourceComputerName $peer -DestinationComputerName $dc -ErrorAction SilentlyContinue
      if($null -ne $b){
        $count=($b | Measure-Object).Count
        if($count -gt $MaxBacklog){ $bad=$true; Write-Warning "[failure] DFSR backlog above threshold: $dc <- $peer : $count (Max=$MaxBacklog)" }
      }
    }
  }
  if(-not $bad){ Write-Warning "[pass] DFSR SYSVOL backlog within threshold on all DC pairs" }
}

<#
.SYNOPSIS
Flags unsigned PnP drivers, ignoring common false positives from core system components.
  OnlyForDomainServers
#>
function HealthTest-UnsignedDrivers {
  [CmdletBinding()]
  param([string[]]$WhitelistDeviceIdRegex = @('^BTHENUM\\'))

  $bad=$false
  $drivers = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_.DeviceName) }

  foreach($d in $drivers){
    $isSigned=$false
    if($d.PSObject.Properties.Name -contains 'IsSigned'){ $isSigned=[bool]$d.IsSigned }
    if($isSigned){ continue }

    $provider=''
    if($d.PSObject.Properties.Name -contains 'DriverProviderName' -and $d.DriverProviderName){ $provider=$d.DriverProviderName }
    elseif($d.PSObject.Properties.Name -contains 'Manufacturer' -and $d.Manufacturer){ $provider=$d.Manufacturer }

    $deviceId=''
    if($d.PSObject.Properties.Name -contains 'DeviceID' -and $d.DeviceID){ $deviceId=[string]$d.DeviceID }

    $isMicrosoft=($provider -match '^(Microsoft|Windows)\b')
    $isWhitelisted=$false
    foreach($rx in $WhitelistDeviceIdRegex){ if($deviceId -match $rx){ $isWhitelisted=$true; break } }

    if($isMicrosoft -or $isWhitelisted){
      $provText = if($provider){" (Provider='$provider')"} else {""}
      $manText  = if($d.Manufacturer){ $d.Manufacturer+', ' } else { '' }
      Write-Warning "[notice] $(("Unsigned device instance treated as benign: {0}{1}{2}" -f $manText,$d.DeviceName,$provText))"
      continue
    }

    $dev = $null
    try{ $dev = Get-PnpDevice -InstanceId $deviceId -ErrorAction Stop }catch{}
    if($dev){
      $p = Get-PnpDeviceProperty -InstanceId $deviceId -ErrorAction SilentlyContinue
      $inf = ($p|? KeyName -eq 'DEVPKEY_Device_DriverInfPath').Data
      $prob= ($p|? KeyName -eq 'DEVPKEY_Device_ProblemCode').Data
      $inst= ($p|? KeyName -eq 'DEVPKEY_Device_InstallState').Data

      # Suppress logical child: empty INF + OK state; verify parent's service is signed
      if([string]::IsNullOrWhiteSpace($inf) -and $dev.Status -eq 'OK' -and ($prob -eq 0 -or -not $prob) -and ($inst -eq 0 -or -not $inst)){
        $parent = ($p|? KeyName -eq 'DEVPKEY_Device_Parent').Data
        if($parent){
          $pp = Get-PnpDeviceProperty -InstanceId $parent -ErrorAction SilentlyContinue
          $svc = ($pp|? KeyName -eq 'DEVPKEY_Device_Service').Data
          if($svc){
            $img = (Get-ItemProperty ("HKLM:\SYSTEM\CurrentControlSet\Services\{0}" -f $svc) -ErrorAction SilentlyContinue).ImagePath
            if($img){
              $expanded = ($img -replace '"','') -replace '%SystemRoot%','\SystemRoot'
              $full = $expanded -replace '^\s*\\SystemRoot', "$env:SystemRoot"
              $sysPath = ($full -split '\s+')[0]
              if(Test-Path $sysPath){
                $sig = Get-AuthenticodeSignature $sysPath
                if($sig.Status -eq 'Valid'){
                  Write-Warning (("[notice] Benign logical child without INF: {0} (ParentSvc={1}, Signed={2})" -f $d.DeviceName,$svc,$sig.SignerCertificate.Subject))
                  continue
                }
              }
            }
          }
        }
      }

      # If INF exists, try to find referenced .sys and check signatures
      if(-not [string]::IsNullOrWhiteSpace($inf)){
        $infPath = if(Test-Path $inf){ $inf } else { Join-Path "$env:SystemRoot\INF" $inf }
        if(Test-Path $infPath){
          $sysNames = Select-String -Path $infPath -Pattern '\.sys' -AllMatches -ErrorAction SilentlyContinue |
                      ForEach-Object { $_.Matches.Value.Trim() } | Select-Object -Unique
          $anyBad=$false
          foreach($name in $sysNames){
            $p1 = Join-Path "$env:SystemRoot\System32\drivers" $name
            $p2 = $null
            try{ $p2 = (Resolve-Path "C:\Windows\System32\DriverStore\FileRepository\*\$name" -ErrorAction SilentlyContinue | Select-Object -First 1).Path }catch{}
            $path = $null
            if($p1 -and (Test-Path $p1)){ $path=$p1 } elseif($p2 -and (Test-Path $p2)){ $path=$p2 }
            if($path){
              $sig = Get-AuthenticodeSignature $path
              if($sig.Status -ne 'Valid'){ $anyBad=$true }
            }
          }
          if(-not $anyBad){
            Write-Warning (("[notice] Win32 reports unsigned but INF-linked drivers are signed: {0} (INF={1})" -f $d.DeviceName,(Split-Path $infPath -Leaf)))
            continue
          }
        }
      }
    }

    $bad=$true
    $ver = if($d.DriverVersion){ $d.DriverVersion } else { '' }
    $man = if($d.Manufacturer){ $d.Manufacturer } else { '' }
    $detail = [string]($d | Select-Object Description,DeviceName,DeviceID,Location,DriverVersion,DriverProviderName,InfName)
    Write-Warning (("[failure] Unsigned 3rd-party driver detected: {0}{1} ver [{2}]`n" -f ($(if($man){"$man, "}), $d.DeviceName, $ver)) + ("Details: {0}" -f $detail))
  }

  if(-not $bad){ Write-Warning "[pass] All non-Microsoft PnP drivers appear signed (benign logical/child nodes and whitelisted instances excluded)." }
}

<#
.SYNOPSIS
Flags unexpected listening TCP ports; ignores 49152-65535 and notes optional baseline ports (3389, 47001, 593). OnlyForDomainServers
.DESCRIPTION
Filters out ports listening only on the loopback addresses (127.0.0.1 and ::1) before checking against allowed ports.
#>
function HealthTest-UnexpectedListeningPorts {
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
                Write-Warning "[warning] $("Unexpected listening port: $p (Process: $procDescr, Vendor: $vendor)")`n$($comment)"
            } else {
                Write-Warning "[notice] $("Unexpected listening port: $p (Process: $procDescr, Vendor: $vendor)")`n$($comment)"
            }
        } else {
            Write-Warning "[failure] $("Unexpected listening port: $p (Process: $procDescr, Vendor: $vendor)")`n$($comment)"
        }
    }

    if (-not $bad) { Write-Warning "[pass] Listening ports are within baseline" }
}

<#
.SYNOPSIS
Verifies DFS Namespace (domain-based) objects enumerate without error. OnlyForDomainServers
#>
function HealthTest-DfsNamespaceEnumerate{
  $roots=Get-DfsnRoot -ErrorAction SilentlyContinue
  if(-not $roots){ Write-Warning "[pass] No DFS Namespace roots found (nothing to check)"; return }
  $count=0
  foreach($r in $roots){ $count += (Get-DfsnFolder -Path $r.Path -ErrorAction SilentlyContinue | Measure-Object).Count }
  Write-Warning "[pass] DFSN roots/folders enumerate: Roots=$($roots.Count); Folders=$count"
}

<#
.SYNOPSIS
Lists SYSTEM-scheduled tasks that are disabled, stale, or failing.
#>
function HealthTest-SystemScheduledTasks{
  [CmdletBinding()] param(
    [string[]]$MustBeEnabled = @(),  # exact paths or regex
    [string[]]$Ignore = @(
      '^\\Microsoft\\Windows\\(AppxDeploymentClient|Bluetooth|Clip|PushToInstall|SharedPC)\\',
      '^\\Microsoft\\Windows\\(InstallService|WaaSMedic|UpdateOrchestrator)\\',
      '^\\Microsoft\\Windows\\(PLA\\Server Manager Performance Monitor|File Classification Infrastructure\\Property Definition Sync)$',
      '^\\Microsoft\\Windows\\\.NET Framework\\\.NET Framework NGEN v4\.0\.30319.*$',
      '^\\Microsoft\\Windows\\Server Initial Configuration Task$'
    ),
    [switch]$IncludeHidden,
    [switch]$IncludeBuiltIn,   # include Microsoft-authored tasks in checks
    [int]$StaleDays = 30,
    [switch]$WarnOnNonZeroLastResult
  )

  $hadIssue = $false
  $isSystem       = { param($t) $t.Principal.UserId -match '^(NT AUTHORITY\\)?SYSTEM$' }
  $isMicrosoft    = { param($t) ($t.Author -match 'Microsoft') -or ($t.TaskPath -like '\Microsoft\*') }
  $shouldIgnore   = { param($path) foreach($rx in $Ignore){ if($path -match $rx){ return } } return }
  $isRequired     = { param($path) foreach($rx in $MustBeEnabled){ if($path -match $rx){ return } } return }

  $tasks = Get-ScheduledTask | Where-Object { & $isSystem $_ }
  if(-not $IncludeHidden){ $tasks = $tasks | Where-Object { -not $_.Settings.Hidden } }
  if(-not $IncludeBuiltIn){ $tasks = $tasks | Where-Object { -not (& $isMicrosoft $_) } }

  foreach($t in $tasks){
    # Keep the leading "\" so paths look like \Microsoft\Windows\...
    $path = "$($t.TaskPath.TrimEnd('\'))\$($t.TaskName)"
    if(& $shouldIgnore $path){ continue }

    $info = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath
    $enabled = [bool]$t.Settings.Enabled
    $state = $t.State
    $hasEnabledTrigger = ($t.Triggers | Where-Object { $_.Enabled }) -ne $null
    $lastRun = $info.LastRunTime
    if (-not $lastRun) {$lastRun = [datetime]::new(1900, 1, 1)}
    $lastRes = ('0x{0:X8}' -f ([uint32]$info.LastTaskResult))

    # 1) Disabled tasks
    if(-not $enabled -or $state -eq 'Disabled'){
      $hadIssue = $true
      if(& $isRequired $path){ Write-Warning "[failure] Required SYSTEM task is disabled: $path" }
      else { Write-Warning "[warning] SYSTEM task is disabled: $path" }
      continue
    }

    # 2) Stale runs (only if triggers exist)
    if($hasEnabledTrigger -and $StaleDays -gt 0){
      if(($lastRun -eq [datetime]::MinValue) -or ((Get-Date) - $lastRun).TotalDays -gt $StaleDays){
        $hadIssue = $true
        Write-Warning "[warning] SYSTEM task appears stale: $path ; LastRun=$lastRun (> $StaleDays days or never)"
      }
    }

    # 3) Non-zero last result (optional)
    if($WarnOnNonZeroLastResult -and $info.LastTaskResult -ne 0){
      $hadIssue = $true
      if(& $isRequired $path){ Write-Warning "[failure] Required SYSTEM task has non-zero LastTaskResult: $path ; Code=$lastRes" }
      else { Write-Warning "[warning] SYSTEM task has non-zero LastTaskResult: $path ; Code=$lastRes" }
    }
  }

  if(-not $hadIssue){ Write-Warning "[pass] All relevant SYSTEM scheduled tasks are enabled and healthy" }
}

<#
.SYNOPSIS
Checks SYSVOL NTFS ACLs do not grant write to broad principals. OnlyForDCs
#>
function HealthTest-SysvolAclHygiene{
  $path="C:\Windows\SYSVOL\sysvol"
  $acl=Get-Acl -Path $path
  $bad=$false
  foreach($ace in $acl.Access){
    $id=$ace.IdentityReference.Value
    $wr=($ace.FileSystemRights.ToString() -match 'Write|Modify|FullControl')
    if($wr -and ($id -match 'Everyone|Authenticated Users')){ $bad=$true; Write-Warning "[failure] SYSVOL ACL too broad: $id has $($ace.FileSystemRights)" }
  }
  if(-not $bad){ Write-Warning "[pass] SYSVOL does not grant write to broad principals (Everyone/Auth Users)" }
}

<#
.SYNOPSIS
Reports accounts permitting RC4 via msDS-SupportedEncryptionTypes. OnlyForDomainServers
#>
function HealthTest-KerberosEncryptionTypes{
  $objs=Get-ADObject -LDAPFilter '(msDS-SupportedEncryptionTypes=*)' -Properties msDS-SupportedEncryptionTypes,sAMAccountName,objectClass
  $bad_count = 0
  foreach($o in $objs){
    $v=[int]$o.'msDS-SupportedEncryptionTypes'
    if(($v -band 0x4) -ne 0){
        Write-Warning "[warning] RC4 permitted for $($o.objectClass): $($o.sAMAccountName)"
        $bad_count += 1
        if ($bad_count -gt 10) {
            Write-Warning "[warning] I will not report any more 'RC4 permitted for...' warnings"
            break
        }
    }
  }
  if($bad_count -eq 0){ Write-Warning "[pass] No accounts permit RC4 in msDS-SupportedEncryptionTypes" }
}

<#
.SYNOPSIS
Ensures DHCP server presence/authorization sane if role installed. OnlyForDomainServers
#>
function HealthTest-DhcpInAd{
  $dhcp=Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
  if(-not $dhcp -or -not $dhcp.Installed){ Write-Warning "[pass] DHCP role not installed on this server"; return }
  $auth=Get-DhcpServerInDC -ErrorAction SilentlyContinue
  $fqdn=[System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName
  $isAuth=($auth | Where-Object { $_.DnsName -ieq $fqdn })
  if($isAuth){ Write-Warning "[pass] DHCP server is authorized in AD ($fqdn)" } else { Write-Warning "[failure] DHCP server is NOT authorized in AD ($fqdn)" }
}

<#
.SYNOPSIS
Flags enabled NICs that are disconnected (cleanup). OnlyForDomainServers
#>
function HealthTest-UnusedEnabledAdapters{
  $nics=Get-NetAdapter | Where-Object {$_.AdminStatus -eq 'Up' -and $_.Status -ne 'Up'}
  foreach($n in $nics){ Write-Warning "[warning] Enabled network adapter is disconnected: $($n.Name) ($($n.Status))" }
  if(($nics | Measure-Object).Count -eq 0){ Write-Warning "[pass] No enabled-but-disconnected network adapters detected" } else { Write-Warning "[failure] There are enabled-but-disconnected network adapters present" }
}

<#
.SYNOPSIS
Checks active interface metrics for sane binding preference. OnlyForDomainServers
#>
function HealthTest-NetworkInterfaceMetrics{
  [CmdletBinding()] param([int]$MaxPreferredMetric=25)
  $ifs=Get-NetIPInterface -AddressFamily IPv4 | Where-Object {$_.ConnectionState -eq 'Connected'}
  $bad=$false
  foreach($i in $ifs){
    if($i.InterfaceMetric -gt $MaxPreferredMetric -and !($i.InterfaceAlias -like "Loopback*")){ $bad=$true; Write-Warning "[warning] Interface metric too high: $($i.InterfaceAlias) Metric=$($i.InterfaceMetric) (Max=$MaxPreferredMetric)" }
  }
  if(-not $bad){ Write-Warning "[pass] All connected interfaces have acceptable metrics (<= $MaxPreferredMetric)" } else { Write-Warning "[failure] One or more interfaces have metrics above the preferred threshold" }
}

<#
.SYNOPSIS
Detects disabled GPO links at domain root (policy choice). OnlyForDCs
#>
function HealthTest-DisabledGpoLinksAtDomainRoot{
  if(-not (Get-Command Get-GPO -ErrorAction SilentlyContinue)){
    Write-Warning "[warning] GroupPolicy cmdlets not available; install RSAT/GPMC (GroupPolicy module)."
    return
  }

  $root=$null
  if(Get-Command Get-ADDomain -ErrorAction SilentlyContinue){
    try{ $root=(Get-ADDomain).DistinguishedName }catch{}
  }
  if(-not $root){
    try{
      $dns=(Get-CimInstance Win32_ComputerSystem).Domain
      if(-not $dns -or $dns -eq 'WORKGROUP'){ throw "Not on a domain" }
      $root=($dns -split '\.')|ForEach-Object{"DC=$_"} -join ','
    }catch{
      Write-Warning "[warning] Cannot resolve domain root DN (need AD or machine joined to a domain)."
      return
    }
  }

  $parseFailures=0
  $links=@()
  foreach($g in (Get-GPO -All -ErrorAction Stop)){
    try{
      $xml=[xml](Get-GPOReport -Guid $g.Id -ReportType Xml -ErrorAction Stop)
      foreach($lnk in @($xml.GPO.LinksTo.LinkTo)){
        if($lnk.SOMPath -eq $root){
          $links += [pscustomobject]@{
            DisplayName=$xml.GPO.Name
            Enabled= if($lnk.Enabled -eq 'true'){1}else{0}
            Enforced=if($lnk.NoOverride -eq 'true'){1}else{0}
            Order=[int]$lnk.Order
          }
        }
      }
    }catch{
      $parseFailures++
      $msg=($_.Exception.Message -replace '\s+',' ').Trim()
      Write-Warning "[warning] Failed to parse GPO report; skipping GPO: $($g.DisplayName) ($($g.Id)) - $msg"
    }
  }

  if($parseFailures -gt 0){
    Write-Warning "[warning] One or more GPO reports could not be read/parsed ($parseFailures). Results may be incomplete."
  }

  if(-not $links){
    Write-Warning "[pass] No GPO links found at the domain root ($root)."
    return
  }

  $flagged=$false
  foreach($l in $links){
    if($l.Enabled -eq 0){ $flagged=$true; Write-Warning "[warning] Domain-root GPO link is disabled: $($l.DisplayName)" }
    if($l.Enforced -eq 0){ $flagged=$true; Write-Warning "[warning] Domain-root GPO link is not enforced: $($l.DisplayName)" }
  }

  if(-not $flagged){ Write-Warning "[pass] All domain-root GPO links are enabled (and enforced per policy)" }
  else{ Write-Warning "[failure] There are disabled or non-enforced GPO links at the domain root" }
}

<#
.SYNOPSIS
Ensures event log max sizes meet baseline without reading events. OnlyForDomainServers
#>
function HealthTest-EventLogMaxSizes{
  [CmdletBinding()]
  param([hashtable]$OverrideMinSizesMB)

  $role = (Get-CimInstance Win32_ComputerSystem).DomainRole
  $MinSizesMB = switch ($role) {
    0 { @{Security=20; System=20;  Application=20} }     # Workstation, non-domain
    1 { @{Security=20; System=20;  Application=20} }     # Workstation, domain-joined
    2 { @{Security=512; System=256; Application=256} }    # Server, non-domain
    3 { @{Security=512; System=256; Application=256} }    # Server, domain-joined
    4 { @{Security=1024;System=256; Application=256} }    # DC (non-FSMO)
    5 { @{Security=1024;System=256; Application=256} }    # DC (PDC Emulator)
    Default { @{Security=512; System=256; Application=256} }
  }
  if ($OverrideMinSizesMB) {
    foreach($k in $OverrideMinSizesMB.Keys){ $MinSizesMB[$k] = [int]$OverrideMinSizesMB[$k] }
  }

  $bad=$false
  foreach($name in $MinSizesMB.Keys){
    $sz=[int64]0
    try{
      $log=Get-WinEvent -ListLog $name -ErrorAction Stop
      $sz=[int64]$log.MaximumSizeInBytes
    }catch{
      $out=& wevtutil gl $name 2>&1
      $line=($out | Select-String -Pattern 'maximum size:' -SimpleMatch | Select-Object -First 1).Line
      if($line -and ($line -match 'maximum size:\s*(\d+)')){ $sz=[int64]$Matches[1] }
    }
    if(-not $sz){ Write-Warning "[warning] $name log size could not be determined"; $bad=$true; continue }

    $minMB=[int]$MinSizesMB[$name]
    $minBytes=[int64]$minMB*1MB
    if($sz -lt $minBytes){
      $bad=$true
      $currentMB=[math]::Round($sz/1MB)
      Write-Warning "[failure] $name log maximum size too small`nIt's ${currentMB}MB < ${minMB}MB`nFix: Run  wevtutil sl $name /ms:$minBytes"
    }
  }

  if(-not $bad){ Write-Warning "[pass] Event log maximum sizes meet or exceed baseline" }
}


<#
.SYNOPSIS
Runs DCDIAG RIDManager and checks for failures or low pool signals. OnlyForDCs
#>
function HealthTest-RidManager{
  $out=& dcdiag /test:ridmanager /v 2>&1
  $fail=($out | Select-String -Pattern 'failed test RidManager','is low' -SimpleMatch)
  if($fail){ Write-Warning "[failure] RID Manager test reported issues`nReview dcdiag /test:ridmanager output"; } else { Write-Warning "[pass] RID Manager health OK (dcdiag)" }
}

<#
.SYNOPSIS
Checks presence of EFS Data Recovery Agents policy/certs. OnlyForDomainServers
#>
function HealthTest-EfsRecoveryAgents{
  $out=& certutil -recoveryagent 2>&1
  $has=($out | Select-String -Pattern 'Recovery Agent' -SimpleMatch)
  if($has){ Write-Warning "[pass] EFS Data Recovery Agents are configured" } else { Write-Warning "[notice] No EFS Data Recovery Agents configured.`nIf anyone uses EFS (NTFS file encryption), there's no domain recovery agent to decrypt data if the user's key is lost." }
}

<#
.SYNOPSIS
Verifies DNS zone transfers are restricted. OnlyForDCs
#>
function HealthTest-DnsZoneTransfers{
  $zones=Get-DnsServerZone | Where-Object { -not $_.IsAutoCreated }
  $bad=$false
  foreach($z in $zones){
    if($z.SecureSecondaries -eq 'Any'){ $bad=$true; Write-Warning "[failure] DNS zone transfer open to Any: $($z.ZoneName)" }
  }
  if(-not $bad){ Write-Warning "[pass] DNS zone transfers are restricted (not 'Any')" }
}

<#
.SYNOPSIS
Flags stale krbtgt (pwdLastSet age above threshold). OnlyForDomainServers
.NOTES
What a failure means: The KRBTGT account key hasn't been rotated for years. Windows keeps the previous KRBTGT key to validate existing TGTs; never rotating extends the window for 'golden ticket' persistence if the key ever leaked.
Risk: If an attacker ever accessed the KRBTGT key, they can mint TGTs and persist. Rotating twice (with replication time in between) is the standard mitigation.
Severity: Critical.
#>
function HealthTest-KrbtgtAge{
  [CmdletBinding()] param([int]$MaxDays=720)
  $u=Get-ADUser krbtgt -Properties pwdLastSet
  $ageDays=[int]((Get-Date) - [DateTime]::FromFileTime($u.pwdLastSet)).TotalDays
  if($ageDays -le $MaxDays){
    Write-Warning "[pass] krbtgt password age acceptable ($ageDays days <= $MaxDays)"
  } else {
    Write-Warning "[failure] krbtgt password age exceeds threshold($MaxDays)`nThe KRBTGT account key hasn't been rotated for $ageDays days. Windows keeps the previous KRBTGT key to validate existing TGTs; never rotating extends the brute force time window for an attacker. Risk: If an attacker ever accessed the KRBTGT key, they can mint TGTs and persist. Rotating twice (with replication time in between) is the standard mitigation."
  }
}

<#
.SYNOPSIS
Ensures NTDS log volume free space above threshold. OnlyForDCs
#>
function HealthTest-NtdsLogVolumeFree{
  [CmdletBinding()] param([int]$MinFreeGB=5)
  $p='HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
  $logPath=(Get-ItemProperty $p -Name 'Database log files path').'Database log files path'
  $drive=(Get-Item $logPath).PSDrive.Name+':'
  $d=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive'"
  $freeGB=[math]::Round($d.FreeSpace/1GB,2)
  if($freeGB -ge $MinFreeGB){ Write-Warning "[pass] NTDS log volume free space OK ($freeGB GB >= $MinFreeGB GB)" } else { Write-Warning "[failure] NTDS log volume low free space ($freeGB GB < $MinFreeGB GB)`nLog path: $logPath" }
}

<#
.SYNOPSIS
Verifies required hotfix baseline is present. OnlyForDomainServers
#>
function HealthTest-HotfixBaseline{
  [CmdletBinding()] param([string[]]$RequiredKBs)
  if(-not $RequiredKBs -or $RequiredKBs.Count -eq 0){ Write-Warning "[pass] No hotfix baseline provided"; return }
  $have=(Get-HotFix | Select-Object -ExpandProperty HotFixID)
  $miss=@()
  foreach($kb in $RequiredKBs){
    if($have -notcontains $kb){ $miss += $kb; Write-Warning "[failure] Missing required hotfix: $kb" }
  }
  if($miss.Count -eq 0){ Write-Warning "[pass] All required hotfixes are installed" }
}

<#
.SYNOPSIS
Validates DHCP DNS update credential account health. OnlyForDomainServers
#>
function HealthTest-DhcpDnsCredential{
  [CmdletBinding()] param([int]$MaxPwdAgeDays=365)
  $dhcp=Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
  if(-not $dhcp -or -not $dhcp.Installed){ Write-Warning "[pass] DHCP role not installed on this server"; return }
  $cred=Get-DhcpServerDnsCredential -ErrorAction SilentlyContinue
  if(-not $cred -or -not $cred.UserName){ Write-Warning "[failure] No DHCP DNS update credentials configured"; return }
  $u=Get-ADUser -Identity $cred.UserName -Properties Enabled,pwdLastSet
  $age=[int]((Get-Date) - [DateTime]::FromFileTime($u.pwdLastSet)).TotalDays
  if(-not $u.Enabled){ Write-Warning "[failure] DHCP DNS credential account is disabled: $($cred.UserName)"; return }
  if($age -gt $MaxPwdAgeDays){ Write-Warning "[failure] DHCP DNS credential password age too high ($age days > $MaxPwdAgeDays): $($cred.UserName)" } else { Write-Warning "[pass] DHCP DNS credential healthy (Enabled, pwd age $age days <= $MaxPwdAgeDays)" }
}

<#
.SYNOPSIS
Validates GPT vs GPC version numbers for GPO consistency. OnlyForDomainServers
#>
function HealthTest-GpoVersionConsistency{

    $dom=(Get-CimInstance Win32_ComputerSystem).Domain
    $base="\\$dom\SYSVOL\$dom\Policies"
    $bad=$false
    foreach($g in Get-GPO -All){
      $ini="$base\{$($g.Id)}\gpt.ini"
      $gptVer = if(Test-Path $ini){ [int]((Get-Content $ini | where {$_ -match '^Version='}) -replace 'Version=','') } else { -1 }
      if($gptVer -lt 0){ $bad=$true; Write-Warning "[failure] GPO missing GPT: $($g.DisplayName)"; continue }
      $uGpt=$gptVer -shr 16; $cGpt=$gptVer -band 0xFFFF
      if($uGpt -ne $g.User.DSVersion -or $cGpt -ne $g.Computer.DSVersion){
        $bad=$true
        Write-Warning "[failure] GPO GPT/AD version mismatch: '$($g.DisplayName)' User AD=$($g.User.DSVersion) GPT=$uGpt; Computer AD=$($g.Computer.DSVersion) GPT=$cGpt"
      }
    }
  if(-not $bad){ Write-Warning "[pass] All GPOs have matching GPT/GPC versions" }
}

<#
.SYNOPSIS
Compares SYSVOL policy tree manifest across DCs (count+hash). OnlyForDCs
.NOTES
Stresses Network: SMB directory tree walks to each DC's SYSVOL\Policies across sites.
#>
function HealthTest-SysvolContentConsistency{
    $dom=(Get-CimInstance Win32_ComputerSystem).Domain
    $dcs=Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName

    $sigs = foreach($dc in $dcs){
      $p="\\$dc\SYSVOL\$dom\Policies"
      if(-not (Test-Path -LiteralPath $p)){
        Write-Warning "[failure] SYSVOL Policies path missing on ${dc}: $p"
        [pscustomobject]@{DC=$dc;Sig='<missing>'}
        continue
      }
      $files = Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue
      $count = ($files | Measure-Object).Count
      [uint64]$total=0; foreach($f in $files){ $total += [uint64]$f.Length }
      [pscustomobject]@{DC=$dc;Sig=('' + $count + '|' + $total).Trim()}
    }

    # Compute uniqueness without Group-Object
    $uniqueSigs = @($sigs | Select-Object -ExpandProperty Sig -Unique)
    $hasMissing = $uniqueSigs -contains '<missing>'
    $allSame    = ($uniqueSigs.Count -eq 1) -and -not $hasMissing
    $map        = ($sigs | ForEach-Object { "$($_.DC)=$($_.Sig)" }) -join ' | '

    # Debug: show what PowerShell *thinks* are distinct values and their bytes
    write-verbose "`nDEBUG: Distinct Sig values ($uniqueSigs.Count):"
    $uniqueSigs | ForEach-Object {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($_)
      write-verbose "  '$_'  bytes=[$([System.BitConverter]::ToString($bytes))]"
    }

    if($allSame){
      Write-Warning "[pass] SYSVOL policy tree manifests match across all DCs"
    } elseif($hasMissing){
      Write-Warning "[failure] $("At least one DC lacks SYSVOL\Policies")`n$($map)"
    } else {
      Write-Warning "[failure] $("SYSVOL policy manifests are not consistent across DCs")`n$($map)"
    }
}

<#
.SYNOPSIS
Reviews RODC PRP (allow/deny) presence where RODCs exist. OnlyForDomainServers
#>
function HealthTest-RodcPrp{
  $rodcs=Get-ADDomainController -Filter {IsReadOnly -eq $true}
  if(-not $rodcs){ Write-Warning "[pass] No RODCs found (PRP not applicable)"; return }
  $bad=$false
  foreach($r in $rodcs){
    $ro=Get-ADObject $r.NTDSSettingsObjectDN -Properties msDS-RevealOnDemandGroup,msDS-NeverRevealGroup
    if(-not $ro.'msDS-RevealOnDemandGroup' -and -not $ro.'msDS-NeverRevealGroup'){ $bad=$true; Write-Warning "[failure] RODC PRP not configured on $($r.HostName)" }
  }
  if(-not $bad){ Write-Warning "[pass] PRP is configured on all RODCs" }
}

<#
.SYNOPSIS
Reports members of 'Pre-Windows 2000 Compatible Access' (should be empty). OnlyForDomainServers
#>
function HealthTest-PreWin2000Group{
  $g=Get-ADGroup -Identity 'Pre-Windows 2000 Compatible Access'
  $m=Get-ADGroupMember $g -Recursive -ErrorAction SilentlyContinue
  foreach($u in $m){ Write-Warning "[failure] 'Pre-Windows 2000 Compatible Access' contains member: $($u.SamAccountName)" }
  if(($m | Measure-Object).Count -eq 0){ Write-Warning "[pass] 'Pre-Windows 2000 Compatible Access' group has no members" }
}

<#
.SYNOPSIS
Validates GP WMI filters use namespaces that exist on this host. OnlyForDomainServers
#>
function HealthTest-GpWmiFiltersNamespaces{
  $bad=$false
  $items=@()

  # Resolve domain via RootDSE
  $dns=$null; $dn=$null
  try{
    $rootDse = [ADSI]"LDAP://RootDSE"
    $dn = $rootDse.defaultNamingContext
    $dns = $rootDse.rootDomainNamingContext -replace '(?i)(?<=,|^)\s*dc=','' -replace '\s*,\s*','.'
  }catch{
    Write-Warning "[warning] This machine cannot read LDAP RootDSE. Is it domain-joined and can it reach a DC?"
    return
  }

  # Try GPMC COM first if present
  $usedCom=$false
  try{
    if([type]::GetTypeFromProgID('GPMgmt.GPM')){
      $gpm   = New-Object -ComObject GPMgmt.GPM
      $const = $gpm.GetConstants()
      $dom   = $gpm.GetDomain($dns,$null,$const.UseAnyDC)
      $sc    = $gpm.CreateSearchCriteria()
      foreach($f in @($dom.SearchWmiFilters($sc))){
        $got=$false
        try{
          foreach($q in @($f.Queries)){
            if($q -and $q.Namespace){ $items += [pscustomobject]@{Filter=$f.Name; Namespace=$q.Namespace}; $got=$true }
          }
        }catch{}
        if(-not $got){
          $txt = ($f.Query,$f.Description,$f.ToString()) -join "`n"
          foreach($m in [regex]::Matches($txt,'(?im)\broot(\\[A-Za-z0-9_]+)+')){
            $items += [pscustomobject]@{Filter=$f.Name; Namespace=$m.Value}
          }
        }
      }
      $usedCom=$true
    }
  }catch{
    # fall through to LDAP
    $usedCom=$false
  }

  # LDAP fallback (and also used to detect "no filters defined")
  if(-not $usedCom -or -not $items){
    try{
      $wmipath = "LDAP://CN=WMIPolicy,CN=System,$dn"
      $wmicont = [ADSI]$wmipath
      if(-not $wmicont.psbase.Name){
        Write-Warning "[pass] No GPO WMI filters defined (CN=WMIPolicy container not found)."
        return
      }
      $ds = New-Object System.DirectoryServices.DirectorySearcher($wmicont)
      $ds.PageSize=500
      $ds.ReferralChasing = [System.DirectoryServices.ReferralChasingOption]::All
      [void]$ds.PropertiesToLoad.AddRange(@('msWMI-Name','msWMI-Parm1'))
      $ds.Filter="(objectClass=msWMI-Som)"
      foreach($res in @($ds.FindAll())){
        $name = ($res.Properties['mswmi-name']|Select-Object -First 1)
        foreach($p in @($res.Properties['mswmi-parm1'])){
          $ns=$null
          if($p -match '^\s*\d+\s*;\s*([^;:]+)'){ $ns=$matches[1] }
          if(-not $ns){
            $m=[regex]::Match($p,'(?im)\broot(\\[A-Za-z0-9_]+)+')
            if($m.Success){ $ns=$m.Value }
          }
          if($ns){ $items += [pscustomobject]@{Filter=$name; Namespace=$ns} }
        }
      }
    }catch{
      Write-Warning "[warning] Cannot enumerate WMI filters via GPMC or LDAP. Check: domain join, DC reachability/DNS, and GPMC installation."
      return
    }
  }

  if(-not $items){ Write-Warning "[pass] No GPO WMI filters defined"; return }

  $unique = $items | Sort-Object Filter,Namespace -Unique
  foreach($i in $unique){
    try{
      $null=Get-CimInstance -Namespace $i.Namespace -ClassName __NAMESPACE -ErrorAction Stop
    } catch {
      $bad=$true
      Write-Warning "[failure] WMI namespace missing for filter '$($i.Filter)': $($i.Namespace)"
    }
  }

  if(-not $bad){ Write-Warning "[pass] All WMI namespaces referenced by GPO WMI filters exist on this host" }
  else{ Write-Warning "[warning] One or more GPO WMI filter namespaces are missing on this host" }
}

function Get-SoftwareLicensing {
    [CmdletBinding()]
    param([string]$ComputerName = $env:COMPUTERNAME)

    function Convert-LicenseStatus {
        param([int]$code)
        switch ($code) {
            0 {'Unlicensed'}
            1 {'Licensed'}
            2 {'OOB Grace'}
            3 {'OOT Grace'}
            4 {'Non-Genuine Grace'}
            5 {'Notification'}
            6 {'Extended Grace'}
            default {"Unknown ($code)"}
        }
    }

    if ($ComputerName -eq $env:COMPUTERNAME) {
        $products = Get-CimInstance -ClassName SoftwareLicensingProduct -ErrorAction Stop |
                Where-Object { $_.PartialProductKey -and $_.LicenseStatus -ne $null }
    } else {
        $products = Get-CimInstance -ClassName SoftwareLicensingProduct -ComputerName $ComputerName -ErrorAction Stop |
                Where-Object { $_.PartialProductKey -and $_.LicenseStatus -ne $null }
    }

    $objects = foreach($p in $products){
        $statusText = Convert-LicenseStatus -code ([int]$p.LicenseStatus)

        $channel = $null
        if ($p.Description) {
            $m = [regex]::Match($p.Description, '(?i)\b([A-Z0-9_]+)\s+channel\b')
            if ($m.Success) { $channel = $m.Groups[1].Value }
        }

        [pscustomobject][ordered]@{
            ComputerName         = $ComputerName
            ProductName          = $p.Name
            LicenseFamily        = Get-PropValue $p 'LicenseFamily'
            ApplicationId        = $p.ApplicationId
            ProductSkuId         = Get-PropValue $p 'ProductSkuId'
            PartialProductKey    = Get-PropValue $p 'PartialProductKey'
            LicenseStatus        = [int]$p.LicenseStatus
            LicenseStatusText    = $statusText
            IsLicensed           = [bool]($p.LicenseStatus -eq 1)
            GracePeriodRemaining = Get-PropValue $p 'GracePeriodRemaining'
            Description          = $p.Description
            Channel              = $channel
        }
    }

    $objects | Sort-Object ProductName, LicenseStatus
}

<#
.SYNOPSIS
Verifies Windows are Licensed.
#>
function HealthTest-SoftwareLicensing{
    Get-SoftwareLicensing | %{
        # ($_ | Format-List * -Force | Out-String).Trim()|write-host -f green
        Write-BasedOnTestResult "Is $($_.ProductName) Licensed?" -Test $_.IsLicensed -comment "$_"
    }
}

<#
.SYNOPSIS
Checks if TPM is activated. OnlyForMobile
#>
function HealthTest-IsTPMActivated {
  Write-BasedOnTestResult "Is TPM Activated?" -Test (Get-Tpm).TpmActivated
}




<#
.SYNOPSIS
Checks DNS suffix for the AD domain. OnlyForDomain,NotForDCs
#>
function HealthTest-DnsSuffixMatchesDomain {
  [CmdletBinding()] param()
  $cs = Get-CimInstance Win32_ComputerSystem
  $role = $cs.DomainRole
  $fn = $MyInvocation.MyCommand.Name
  if ($role -in 0,2) { Write-Warning "[notice] This test ($fn) is not applicable to non-domain joined hosts"; return }
  if ($role -in 4,5) { Write-Warning "[notice] This test ($fn) is not applicable to Domain Controllers"; return }

  $domain = $cs.Domain
  $out = ipconfig /all 2>&1
  $pattern = "DNS Suffix.* $domain`$"
  if ($out | Select-String -Pattern $pattern) {
    Write-Warning "[pass] Domain name appears in DNS suffix`nDomain: $domain"
  } else {
    Write-Warning "[failure] Domain name does not appear in DNS suffix`nExpected suffix: $domain"
  }
}

<#
.SYNOPSIS
Checks that the domain DNS name A record points to at least one DC IP. OnlyForDomain,NotForDCs

IMPORTANT: you need to have a json list with the IPs of all DCs in file
	'C:\it\config\ips-of-all-DCs.conf'. E.g:
	{"ips":["192.168.0.1","192.168.0.2"]}
#>
function HealthTest-DomainARecordPointsToDcIp {
  $cs = Get-CimInstance Win32_ComputerSystem
  $role = $cs.DomainRole
  $fn = $MyInvocation.MyCommand.Name
  if ($role -in 0,2) { Write-Warning "[notice] This test ($fn) is not applicable to non-domain joined hosts"; return }
  if ($role -in 4,5) { Write-Warning "[notice] This test ($fn) is not applicable to Domain Controllers"; return }

  Write-Output "Reading C:\it\config\ips-of-all-DCs.conf to get the list of the IPs of all DCs"
  # will return a list of IPs or throw
  $dcIps = Get-AllDCIPs -Path 'C:\it\config\ips-of-all-DCs.conf'

  $domain = $cs.Domain
  $ares = $null
  try { $ares = Resolve-DnsName -Name $domain -Type A -ErrorAction Stop } catch {}
  if (-not $ares) {
    Write-Warning "[failure] $("No A records found for domain DNS name.")`n$($domain)"
    return
  }

  $aIps = @($ares | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
  $intersection = @()
  foreach ($ip in $aIps) { if ($dcIps -contains $ip) { $intersection += $ip } }

  $comment = "Domain=$domain; DC IPs=" + ($dcIps -join ', ') + "; Domain A IPs=" + ($aIps -join ', ')
  if ($intersection.Count -gt 0) {
    Write-Warning "[pass] $("Domain DNS name resolves to at least one DC IP.")`n$($comment)"
  } else {
    Write-Warning "[failure] $("Domain DNS name does not resolve to any known DC IPv4 address.")`n$($comment)"
  }
}

<#
.SYNOPSIS
Ensures each interface DNS server list contains only DC IPs. OnlyForDomain,NotForDCs

IMPORTANT: you need to have a json list with the IPs of all DCs in file
	'C:\it\config\ips-of-all-DCs.conf'. E.g:
	{"ips":["192.168.0.1","192.168.0.2"]}
#>
function HealthTest-InterfaceDnsServersUseDcs {

  $cs = Get-CimInstance Win32_ComputerSystem
  $role = $cs.DomainRole
  $fn = $MyInvocation.MyCommand.Name
  if ($role -in 0,2) { Write-Warning "[notice] This test ($fn) is not applicable to non-domain joined hosts"; return }
  if ($role -in 4,5) { Write-Warning "[notice] This test ($fn) is not applicable to Domain Controllers"; return }

  Write-Output "Reading C:\it\config\ips-of-all-DCs.conf to get the list of the IPs of all DCs"
  # will return a list of IPs or throw
  $dcIps = Get-AllDCIPs -Path 'C:\it\config\ips-of-all-DCs.conf'

  $nets = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=TRUE"
  if (-not $nets) {
    Write-Warning "[failure] No IP-enabled network adapters found."
    return
  }

  $anyClean = $false
  $anyBad   = $false

  foreach ($net in $nets) {
    $dns  = $net.DNSServerSearchOrder
    $desc = $net.Description
    if (-not $dns -or $dns.Count -eq 0) {
      Write-Warning "[notice] $("Interface has no DNS servers configured.")`n$($desc)"
      continue
    }

    $dnsList = $dns -join ', '
    $allDomain = $true
    $allNonDomain = $true
    foreach ($s in $dns) {
      if ($dcIps -notcontains $s) { $allDomain = $false; break }
    }
    foreach ($s in $dns) {
      if ($dcIps -contains $s) { $allNonDomain = $false; break }
    }

    if ($allDomain) {
      $anyClean = $true
      Write-Warning ("[pass] Interface has only DCs as DNS servers.`n" + ("Interface: " + $desc + "; DNS=" + $dnsList))
    } elseif ($allNonDomain) {
      # Ignoring this interface that only has non-domain DNS servers
    } else {
      $anyBad = $true
      Write-Warning ("[failure] Interface DNS servers include non-DC addresses.`n" + ("Interface: " + $desc + "; DNS=" + $dnsList + "; DC IPs=" + ($dcIps -join ', ')))
    }
  }

  if (-not $anyClean) {
    Write-Warning "[failure] No interface found where all DNS servers are DC IPs."
  } elseif (-not $anyBad) {
    Write-Warning "[pass] All interfaces with DNS configured use only DC IPs."
  }
}

<#
.SYNOPSIS
Verifies NLTEST /dsgetsite can determine the client AD site. OnlyForDomain,NotForDCs
#>
function HealthTest-NltestSiteDiscovery {
  [CmdletBinding()] param()
  $cs = Get-CimInstance Win32_ComputerSystem
  $role = $cs.DomainRole
  $fn = $MyInvocation.MyCommand.Name
  if ($role -in 0,2) { Write-Warning "[notice] This test ($fn) is not applicable to non-domain joined hosts"; return }
  if ($role -in 4,5) { Write-Warning "[notice] This test ($fn) is not applicable to Domain Controllers"; return }

  $out  = nltest /dsgetsite 2>&1
  $exit = $LASTEXITCODE
  $txt  = ($out | Out-String).Trim()

  if ($exit -eq 0 -and $txt -match 'The command completed successfully') {
    $lines = $txt -split "`r?`n"
    $site  = $null
    foreach ($l in $lines) {
      if (-not $site -and $l -and $l -notmatch 'The command completed successfully') {
        $site = $l.Trim()
        break
      }
    }
    if (-not $site) { $site = '(unknown)' }
    Write-Warning "[pass] $("NLTEST /dsgetsite succeeded.")`n$(("Site: " + $site))"
  } else {
    $hex = '0x{0:X}' -f ($exit -band 0xFFFFFFFF)
    Write-Warning ("[failure] NLTEST /dsgetsite failed.`n" + ("ExitCode=" + $hex + "; Output=`n" + $txt))
  }
}

<#
.SYNOPSIS
Runs gpupdate and validates computer and user policy application. OnlyForDomain,NotForDCs
#>
function HealthTest-GpupdatePolicyApply {
  [CmdletBinding()] param()
  $cs   = Get-CimInstance Win32_ComputerSystem
  $role = $cs.DomainRole
  $fn   = $MyInvocation.MyCommand.Name
  if ($role -in 0,2) { Write-Warning "[notice] This test ($fn) is not applicable to non-domain joined hosts"; return }
  if ($role -in 4,5) { Write-Warning "[notice] This test ($fn) is not applicable to Domain Controllers"; return }


  if (!(Test-ComputerSecureChannel)) {
      Write-Warning "[warning] Can't connected to any Domain Controller. Can not run gpupdate.`nMake sure you are on the domain LAN or connected via VPN."
    return
  }

  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $isSystem = $false
  try {
    if ($id -and $id.User -and $id.User.Value -eq 'S-1-5-18') { $isSystem = $true }
  } catch {}

  $out  = gpupdate 2>&1
  $text = ($out | sls -notmatch '^ *$' | Out-String)

  $compOk = ($text -like "*Computer Policy update has completed successfully*")
  $userOk = ($text -like "*User Policy update has completed successfully*")

  if ($compOk -and $userOk) {
    Write-Warning "[pass] Computer and user policy updates completed successfully (gpupdate)."
    return
  }

  if ($compOk) {
    Write-Warning "[pass] Computer policy update completed successfully (gpupdate)."
  } else {
    Write-Warning "[failure] $("Computer policy update did not report success.")`n$(("gpupdate output:`n" + $text))"
  }

  if (-not $userOk) {
    if ($isSystem) {
      Write-Warning "[notice] $("User policy update did not report success (gpupdate running under SYSTEM/non-interactive).")`n$(("This can be expected when no interactive user is logged on.`nRaw gpupdate output:`n" + $text))"
    } else {
      Write-Warning "[failure] $("User policy update did not report success.")`n$(("Expected success for interactive user.`nRaw gpupdate output:`n" + $text))"
    }
  } else {
    Write-Warning "[pass] User policy update completed successfully (gpupdate)."
  }
}

#--------------------------------------------------------
# xxx new tests 20205-11-26

<# .SYNOPSIS Checks recent critical disk/NTFS/storage errors in the System event log. #>
function HealthTest-RecentDiskErrors {
    param([int]$Hours = 48)

    $pass = $true
    if ($Hours -lt 1) { $Hours = 1 }

    $start     = (Get-Date).AddHours(-$Hours)
    $providers = @('disk','ntfs','stornvme')
    $events    = @()

    foreach ($p in $providers) {
        try {
            Get-WinEvent -FilterHashtable @{
                    LogName      = 'System'
                    ProviderName = $p
                    Level        = 2     # Error
                    StartTime    = $start
            } -ErrorAction SilentlyContinue | %{
                Write-Warning "[failure] Storage($p) error in last N hours`nN=$Hours hours; Event: $($_.TimeCreated), $($_.LevelDisplayName), $($_.Message)"
                $pass = $false
            }
        } catch {
            if ($_.Exception.Message -notlike '*There is not an event provider*') {
                Write-Warning "[warning] Failed reading System log for provider '$p': $($_.Exception.Message)"
            }
        }
    }

    if ($pass) {
        Write-Warning "[pass] No disk/NTFS/storage errors in last $Hours h"
    }

}

<# .SYNOPSIS Looks for crash dumps and bugcheck events as indicators of recent system crashes. #>
function HealthTest-CrashDumpSignals {
    param([int]$Hours = 48)

    $pass = $true
    if ($Hours -lt 1) { $Hours = 1 }
    $cutoff = (Get-Date).AddHours(-$Hours)

    Get-ChildItem "$env:SystemRoot\Minidump" -Filter *.dmp -ErrorAction SilentlyContinue | ?{ $_.LastWriteTime -gt $cutoff } | %{
        Write-Warning "[failure] Found $env:SystemRoot\Minidump\ file(s) within the last N hours`nN=$Hours hours. File: $env:SystemRoot\Minidump\$($_.name))"
    }
    if ($pass) {
        Write-Warning "[pass] No recent minidumps"
    }

    $pass = $true
    Get-WinEvent -FilterHashtable @{
            LogName   = 'System'
            Id        = 1001  # BugCheck
            StartTime = $cutoff
    } -ErrorAction SilentlyContinue | %{
        Write-Warning "[failure] Found System Event #1001 within the last N hours (this event often indicates a crash)`nN=$Hours hours. Event: $($_.TimeCreated), $($_.LevelDisplayName), $($_.Message)"
    }

    if ($pass) {
        Write-Warning "[pass] No recent System #1001 events"
    }
}

<# .SYNOPSIS Detects unexpected members in the local Administrators group. #>
function HealthTest-LocalAdminsBaseline {
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
        Write-Warning "[pass] No unexpected accounts in Local Administrators"
    }
}

<# .SYNOPSIS Checks physical NICs for link problems and significant error rates. #>
function HealthTest-Nic {
    $nics = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
    if (-not $nics) {
        Write-Output "No physical NICs with Status=Up; skipping NIC health check"
        return
    }

    $pass = $true
    $minPackets = 100000

    foreach ($n in $nics) {
        $stat = Get-NetAdapterStatistics -Name $n.Name -ErrorAction SilentlyContinue
        if (-not $stat) {
            Write-Output "Network interface skipped due to missing stats ($($n.Name))"
            continue
        }

        $errors =
            $stat.ReceivedDiscardedPackets +
            $stat.ReceivedPacketErrors +
            $stat.OutboundDiscardedPackets +
            $stat.OutboundPacketErrors

        $totalPackets =
            $stat.ReceivedUnicastPackets +
            $stat.ReceivedBroadcastPackets +
            $stat.ReceivedMulticastPackets +
            $stat.OutboundUnicastPackets +
            $stat.OutboundBroadcastPackets +
            $stat.OutboundMulticastPackets

        if ($n.MediaConnectionState -ne 'Connected') {
            $warnList += "$($n.Name): mediaState=$($n.MediaConnectionState)"
            Write-Warning "[warning] Disconnected network interface ($($n.Name))`n"
            $pass = $false
            continue
        }

        if ($totalPackets -lt $minPackets) {
            Write-Output "Network interface skipped due to low traffic ($($n.Name))"
            continue
        }

        if ($errors -le 0) {
            continue
        }

        $errorPct = 0.0
        if ($totalPackets -gt 0) {
            $errorPct = [double]$errors * 100.0 / [double]$totalPackets
        }

        $pctStr = ("{0:N4}%%" -f $errorPct)

        if ($errors -ge 1000 -and $errorPct -ge 0.01) {
            $warnList += "$($n.Name): errors=$pctStr ($errors/$totalPackets total)"
            Write-Warning "[warning] Network interface with plenty of errors ($($n.Name))`nerrors=$pctStr ($errors/$totalPackets total packets)"
            $pass = $false
        } elseif ($errors -ge 100 -and $errorPct -ge 0.002) {
            $noticeList += "$($n.Name): errors=$pctStr ($errors/$totalPackets total)"
            Write-Warning "[notice] Network interface with some errors ($($n.Name))`nerrors=$pctStr ($errors/$totalPackets total packets)"
            $pass = $false
        } else {
            # below 0.002%: considered OK, no log entry
            continue
        }
    }

    if ($pass) {
        Write-Warning "[pass] Network interfaces healthy; no significant error rates or disconnected interfaces detected"
    }
}

<# .SYNOPSIS Summarizes BitLocker protection status for local volumes. #>
function HealthTest-BitLockerStatus {
    if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        Write-Warning "[warning] BitLocker PowerShell cmdlets not available; skipping BitLocker status check"
        return
    }

    $pass = $true

    $vols = Get-BitLockerVolume -ErrorAction SilentlyContinue
    if (-not $vols) {
        Write-Warning "[notice] No BitLocker-capable volumes found"

    }
    $vols | Where-Object { $_.ProtectionStatus -ne 'On' } | %{
        Write-Warning "[failure] Volume not protected by BitLocker: $($_.MountPoint)"
        $pass = $false
    }
    if ($pass) {
        Write-Warning "[pass] BitLocker protection is ON for all detected volumes"
    }
}

<# .SYNOPSIS Detects DHCP scopes whose utilization is close to exhaustion. #>
function HealthTest-DhcpScopeUtilization {
    $svc = Get-Service -Name 'DHCPServer' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Output "Host is not a DHCP server (DHCPServer service missing); skipping DHCP scope utilization test"
        return
    }

    if (-not (Get-Command Get-DhcpServerv4ScopeStatistics -ErrorAction SilentlyContinue)) {
        Write-Warning "[warning] DHCP server cmdlets not available on this DHCP server; skipping DHCP scope utilization test"
        return
    }

    $stats = Get-DhcpServerv4ScopeStatistics -ErrorAction SilentlyContinue
    if (-not $stats) {
        Write-Warning "[warning] DHCP server role present but no DHCPv4 scopes found"
        return
    }

    $over = @()
    foreach ($s in $stats) {
        if ($s.PercentageInUse -ge 90) {
            $over += $s.ScopeId
            Write-Warning "[failure] DHCP scope is >=90% used: $($s.ScopeId)"
        } elseif ($s.PercentageInUse -ge 80) {
            $over += $s.ScopeId
            Write-Warning "[warning] DHCP scope is >=80% used: $($s.ScopeId)"
        }
    }

    if ($over.Count -gt 0) {
        Write-Warning "[pass] DHCP scope utilization OK (<80% in use)"
    }

}

<#
.SYNOPSIS
  Verifies key DNS suffix/devolution/registration settings for a small, single-domain AD.
#>
function HealthTest-DnsSuffixBaseline {
    $DomainName=(Get-CimInstance Win32_ComputerSystem).Domain

    # 1) Primary DNS suffix equals the AD DNS name
    $ipg = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    $primarySuffix = $ipg.DomainName

    if ([string]::IsNullOrWhiteSpace($primarySuffix)) {
        Write-Warning "[failure] Primary DNS suffix`nCurrent is empty`nEnsure the system has a primary DNS suffix (normally set by domain join)."
    } elseif ($primarySuffix -ieq $DomainName) {
        Write-Warning "[pass] Primary DNS suffix`n$primarySuffix"
    } else {
        Write-Warning (("[failure] Primary DNS suffix`nCurrent='{0}' Expected='{1}'`nEnsure primary DNS suffix equals the AD DNS name (normally set by domain join)." -f $primarySuffix,$DomainName))
    }

    # 2) DNS devolution is enabled (boolean only)
    try {
        $g = Get-DnsClientGlobalSetting -ErrorAction Stop
        if ($g.UseDevolution -eq $true) {
            Write-Warning "[pass] DNS devolution enabled`nUseDevolution=True"
        } else {
            Write-Warning "[failure] DNS devolution enabled`nUseDevolution=False`nEnable devolution (GPO: Computer Configuration/Administrative Templates/Network/DNS Client/Turn off DNS devolution = Disabled)."
        }
    } catch {
        $err = $_
        Write-Warning (("[failure] DNS devolution enabled`nUnable to query global DNS client settings: {0}`nCheck OS support for Get-DnsClientGlobalSetting and that the DNS Client service is running." -f $err.Exception.Message))
    }

    # 3) Per-NIC checks (only PASS/FAIL; no discovery warning if none found)
    $nics = @()
    try {
        $nics = Get-DnsClient -ErrorAction Stop |
                Where-Object { $_.InterfaceOperationalStatus -eq "Up" -and $_.ConnectionSpecificSuffix -ne "localdomain" }
    } catch {
        $err = $_
        Write-Warning (("[failure] NIC DNS settings`nUnable to query DNS client interfaces: {0}`nConfirm OS supports Get-DnsClient and you have sufficient privileges." -f $err.Exception.Message))
        $nics = @()
    }

    foreach ($n in $nics) {
        $nicName = $n.InterfaceAlias

        # 3a) Registration flags must both be True
        if ($n.RegisterThisConnectionsAddress -and $n.UseSuffixWhenRegistering) {
            Write-Warning ("[pass] NIC '{0}' DNS registration`nRegisterThisConnectionsAddress=True, UseSuffixWhenRegistering=True" -f $nicName)
        } else {
            Write-Warning (("[failure] NIC '{0}' DNS registration`nRegisterThisConnectionsAddress={1}, UseSuffixWhenRegistering={2}`nEnable both flags on important interfaces." -f $nicName,$n.RegisterThisConnectionsAddress,$n.UseSuffixWhenRegistering))
        }

        # 3b) Connection-specific suffix: must be Empty OR exactly the domain
        $css = $n.ConnectionSpecificSuffix
        if ([string]::IsNullOrWhiteSpace($css)) {
            Write-Warning ("[pass] NIC '{0}' Conn.-specific suffix`nEmpty" -f $nicName)
        } elseif ($css -ieq $DomainName) {
            Write-Warning ("[pass] NIC '{0}' Conn.-specific suffix`nEquals {1}" -f $nicName,$DomainName)
        } else {
            Write-Warning (("[failure] NIC '{0}' Conn.-specific suffix`nSet to '{1}'`nLeave blank for single-domain setups unless a specific suffix is required." -f $nicName,$css))
        }
    }
}

<#
.SYNOPSIS
HealthTest-ADReplicationDomainRepadmin: Domain-wide AD replication health using repadmin.exe (replsum + showreps). DC-only; fails if repadmin or AD DS prerequisites are missing.
#>
function HealthTest-ADReplicationDomainRepadmin {
  $domainRole = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).DomainRole
  $isHostDC = ($domainRole -in 4,5)

  if (-not $isHostDC) { return }

  $repadminCmd = Get-Command repadmin.exe -ErrorAction SilentlyContinue
  $repadmin = if ($repadminCmd -and $repadminCmd.Source) { $repadminCmd.Source } else { "$env:windir\system32\repadmin.exe" }

  if (-not (Test-Path -LiteralPath $repadmin)) {
    Write-Warning "[failure] AD replication (repadmin): repadmin.exe not found; cannot run domain-wide checks."
    return
  }

  $ok = $true

  # --- Test 1: repadmin /replsum -> ensure all 'fails' are 0
  try {
    $sumOut = (& $repadmin /replsum 2>&1 | Out-String)
  } catch {
    Write-Warning "[failure] $("AD replication (repadmin): failed to execute 'repadmin /replsum'.")`n$($_.Exception.Message)"
    return
  }

  if (-not $sumOut) {
    Write-Warning "[failure] AD replication (repadmin): no output from 'repadmin /replsum'."
    $ok = $false
  } else {
    $bad = @()
    foreach ($ln in ($sumOut -split '\r?\n')) {
      if ($ln -match '^\s*(?<DSA>\S+)\s+(?<Delta>(?:\d+d:)?(?:\d+h:)?\d+m:\d+s|\d+s)\s+(?<Fails>\d+)\s*/\s*(?<Total>\d+)\b') {
        $dsa = $Matches.DSA
        $fails = [int]$Matches.Fails
        $total = [int]$Matches.Total
        if ($fails -gt 0) { $bad += [pscustomobject]@{ DSA=$dsa; Fails=$fails; Total=$total } }
      }
    }

    if ($bad.Count -gt 0) {
      foreach ($b in $bad) {
        Write-Warning "[failure] $("AD replication (repadmin): replsum reports failures on '$($b.DSA)'")`n$(("{0} fail(s) out of {1} neighbors." -f $b.Fails,$b.Total))"
      }
      $ok = $false
    } else {
      Write-Warning "[pass] AD replication (repadmin): replsum shows 0 fails for all DSAs."
    }
  }

  # --- Test 2: repadmin /showreps -> all latest attempts 'was successful.'
  try {
    $showOut = (& $repadmin /showreps 2>&1 | Out-String)
  } catch {
    Write-Warning "[failure] $("AD replication (repadmin): failed to execute 'repadmin /showreps'.")`n$($_.Exception.Message)"
    return
  }

  if (-not $showOut) {
    Write-Warning "[failure] AD replication (repadmin): no output from 'repadmin /showreps'."
    $ok = $false
  } else {
    $attemptLines = ($showOut -split '\r?\n') | Where-Object { $_ -match 'Last attempt @' }
    if (-not $attemptLines -or $attemptLines.Count -eq 0) {
      Write-Warning "[warning] AD replication (repadmin): showreps produced no 'Last attempt' lines.`nRun 'repadmin /showreps' manually to inspect output."
      $ok = $false
    } else {
      $notOk = @($attemptLines | Where-Object { $_ -notmatch 'was successful\.$' })
      if ($notOk.Count -gt 0) {
        foreach ($ln in $notOk) {
          Write-Warning "[failure] $("AD replication (repadmin): showreps has unsuccessful last attempt")`n$(($ln.Trim()))"
        }
        $ok = $false
      } else {
        Write-Warning "[pass] AD replication (repadmin): showreps indicates all last attempts were successful."
      }
    }
  }

  if (-not $ok) {
    Write-Warning "[notice] AD replication (repadmin): issues detected."
  }
}


<#
.SYNOPSIS
HealthTest-ADReplicationLocalRSAT: Local DC AD replication partner health using RSAT AD cmdlets (Get-ADReplicationPartnerMetadata). DC-only; fails if AD module/ADWS prerequisites are missing.
#>
function HealthTest-ADReplicationLocalRSAT {
  $domainRole = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).DomainRole
  $isHostDC = ($domainRole -in 4,5)

  if (-not $isHostDC) { return }

  $adModuleOk = $true
  try {
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) { $adModuleOk = $false }
  } catch {
    $adModuleOk = $false
  }

  if (-not $adModuleOk) {
    Write-Warning "[failure] AD replication (RSAT): ActiveDirectory module not available; cannot query replication partner metadata."
    return
  }

  try {
    Import-Module ActiveDirectory -ErrorAction Stop
  } catch {
    Write-Warning "[failure] $("AD replication (RSAT): failed to import ActiveDirectory module.")`n$($_.Exception.Message)"
    return
  }

  $me = $null
  try {
    $me = Get-ADDomainController -ErrorAction Stop
  } catch {
    Write-Warning "[failure] $("AD replication (RSAT): failed to identify local domain controller.")`n$($_.Exception.Message)"
    return
  }

  if (-not $me -or -not $me.HostName) {
    Write-Warning "[failure] AD replication (RSAT): could not determine local DC hostname."
    return
  }

  try {
    [void](Get-ADDomain -ErrorAction Stop)
  } catch {
    Write-Warning "[failure] $("AD replication (RSAT): cannot query domain info (ADWS/permissions/connectivity issue).")`n$($_.Exception.Message)"
    return
  }

  $md = $null
  try {
    $md = Get-ADReplicationPartnerMetadata -Target $me.HostName -ErrorAction Stop
  } catch {
    Write-Warning "[failure] $("Exception from: Get-ADReplicationPartnerMetadata -Target $($me.HostName)")`n$($_.Exception.Message)"
    return
  }

  if (-not $md) {
    Write-Warning "[failure] AD replication (RSAT): no partner metadata returned for $($me.HostName)."
    return
  }

  $bad = @($md | Where-Object { $_.LastReplicationResult -ne 0 })
  if ($bad.Count -gt 0) {
    $details = $bad | ForEach-Object { "$($_.Partner) rc=$($_.LastReplicationResult) at $($_.LastSuccessfulSync)" }
    Write-Warning "[failure] $("AD replication (RSAT): replication partner errors for $($me.HostName).")`n$(($details -join " | "))"
    return
  }

  Write-Warning "[pass] AD replication (RSAT): replication partner results healthy for $($me.HostName)."
}


function HealthTest-TimeSyncAccuracy {
  param(
    [int]$WarnOffsetSeconds=15,
    [int]$FailOffsetSeconds=30,
    [string]$RefTimeServer='time.windows.com',
    [switch]$AlwaysUseRef
  )

  $source = ''
  try {
    $srcOut = (w32tm /query /source 2>&1) -join "`n"
    if ($LASTEXITCODE -eq 0) {
      $source = ($srcOut -split "`r?`n")[0].Trim()
    }
  } catch {}

  $target = $RefTimeServer
  if (-not $AlwaysUseRef -and $source) {
    $src1 = ($source -split ',',2)[0].Trim()
    $isNonHost = $src1 -match '(?i)(free[-\s]?running|local\s+(cmos|rtc)|vm\s+ic|hyper[-\s]?v|unsynchronized|no\s+source|local\s+clock)'
    $looksIPv4 = $src1 -match '^(?:\d{1,3}\.){3}\d{1,3}$'
    $looksName = $src1 -match '^[A-Za-z0-9][A-Za-z0-9\-\.]*[A-Za-z0-9]$'
    $looksIPv6 = $src1 -match '^[\[\]0-9A-Fa-f:]+$'
    if (($looksIPv4 -or $looksName -or $looksIPv6) -and -not $isNonHost) { $target = $src1 }
  }

  $sc = (w32tm /stripchart /computer:$target /dataonly /samples:2 2>&1) -join "`n"
  $exit = $LASTEXITCODE
  if ($exit -ne 0) {
    $hex = '0x{0:X}' -f ($exit -band 0xFFFFFFFF)
    if ($target -ne $RefTimeServer) {
        Write-Warning "[notice] Failed to test time sync via $target, retrying with $RefTimeServer`nStripchart to $target failed with error $hex"
        # retry
        $sc = (w32tm /stripchart /computer:$RefTimeServer /dataonly /samples:2 2>&1) -join "`n"
        $exit = $LASTEXITCODE
        if ($exit -ne 0) {
          $hex = '0x{0:X}' -f ($exit -band 0xFFFFFFFF)
          Write-Warning "[warning] Failed to test time sync either via $target or via $RefTimeServer`nStripchart to $RefTimeServer failed with error $hex"
          return
        }
        $target = $RefTimeServer
    } else {
        Write-Warning "[warning] Failed to test time sync`nStripchart to $target failed with error $hex"
        return
    }
  }

  $m = [regex]::Match($sc,'([-+]?\d+(?:[.,]\d+)?)s')
  if (-not $m.Success) {
    Write-Warning "[warning] Failed to test time sync`nCould not parse offset from stripchart to $target"
    return
  }

  $valStr = $m.Groups[1].Value.Replace(',', '.')
  $offsetSec = [double]::Parse($valStr, [System.Globalization.CultureInfo]::InvariantCulture)
  $abs = [math]::Abs($offsetSec)
  $ok = $true

  if ($abs -ge $FailOffsetSeconds) {
    Write-Warning "[failure] $("Time offset too high")`n$(("{0} s exceeds {1} s (2-samples)" -f $offsetSec,$FailOffsetSeconds))"
    $ok = $false
  } elseif ($abs -ge $WarnOffsetSeconds) {
    Write-Warning "[warning] $("Time offset rather high")`n$(("{0} s exceeds {1} s (2-samples)" -f $offsetSec,$WarnOffsetSeconds))"
    $ok = $false
  }

  if ($ok) {
    Write-Warning ("[pass] Time OK (1-sample); source: {0}; target: {1}; offset: {2} s" -f $source,$target,$offsetSec)
  }
}


function HealthTest-PagefileSanity{
  [CmdletBinding()] param([int]$MinMB=1024,[switch]$RequireOnSystemDrive)
  $cs   = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
  $auto = $cs.AutomaticManagedPagefile
  $usage = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
  $regPath='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
  $pfReg=(Get-ItemProperty -Path $regPath -Name PagingFiles -ErrorAction SilentlyContinue).PagingFiles

  $entries=@()
  if($usage){
    foreach($u in $usage){ $entries += [pscustomobject]@{Name=$u.Name;AllocMB=[int]$u.AllocatedBaseSize;CurrMB=[int]$u.CurrentUsage} }
  }
  if(-not $entries -and $pfReg){
    foreach($line in $pfReg){
      $parts=$line -split '\s+'
      if($parts.Length -ge 1){
        $name=$parts[0]; $min= if($parts.Length -ge 2){ [int]$parts[1] } else { 0 }
        $entries += [pscustomobject]@{Name=$name;AllocMB=$min;CurrMB=$null}
      }
    }
  }

  if(-not $entries){
    Write-Warning "[failure] $("No pagefile detected")`n$(("AutomaticManagedPagefile="+[int]$auto))"
    return
  }

  $sumAlloc=($entries | Measure-Object AllocMB -Sum).Sum
  $okSize = ($sumAlloc -ge $MinMB)
  $okSys  = $true
  if($RequireOnSystemDrive){
    $sys = $env:SystemDrive  # Typically 'C:'
    $okSys = (($entries | Where-Object {$_.Name -like "$sys\*"}).Count -gt 0)
    if(-not $okSys){ Write-Warning "[failure] No pagefile on system drive`nSystemDrive=$sys; Entries="+(($entries | ForEach-Object {"$($_.Name):$($_.AllocMB)MB"}) -join ', ') }
  }
  if(-not $okSize){ Write-Warning "[failure] Total pagefile size below threshold`nTotalAllocMB=$sumAlloc; MinMB=$MinMB" }

  if($okSize -and $okSys){
    Write-Warning ("[pass] Paging file configured sensibly`n" + ("Auto="+[int]$auto+"; TotalAllocMB=$sumAlloc; Entries="+(($entries | ForEach-Object {"$($_.Name):$($_.AllocMB)MB"}) -join ', ')))
  }
}


function HealthTest-Storage {
    [CmdletBinding()]
    param([int]$MaxTemperatureC = 70,[int]$MaxPercentUsed = 95)

    $allHealthy = $true
    $disks = Get-PhysicalDisk -ErrorAction SilentlyContinue
    if (-not $disks) { Write-Warning "[failure] No disks visible via Get-PhysicalDisk"; return }

    foreach ($d in $disks) {
        # 1) Explicit predictive failure
        $predFail = $false
        if ($d.PSObject.Properties.Name -contains 'OperationalStatus') {
            $os = $d.OperationalStatus
            if ($os -is [array]) { foreach($s in $os){ if ($s -eq 'Predictive Failure') { $predFail=$true; break } } }
            else { if ($os -eq 'Predictive Failure') { $predFail=$true } }
        }
        if ($predFail) {
            Write-Warning "[failure] $(("OperationalStatus=Predictive Failure for disk '{0}'" -f $d.FriendlyName))"
            $allHealthy = $false
        }

        # 2) HealthStatus
        if ($d.PSObject.Properties.Name -contains 'HealthStatus') {
            if ($d.HealthStatus -ne 'Healthy') {
                Write-Warning "[failure] $(("HealthStatus={0} for disk '{1}'" -f $d.HealthStatus,$d.FriendlyName))"
                $allHealthy = $false
            }
        }

        # 3) Reliability counters (temp, errors, wear)
        try {
            $c = $d | Get-StorageReliabilityCounter -ErrorAction Stop
            if ($c) {
                if ($c.PSObject.Properties.Name -contains 'Temperature') {
                    if ([double]$c.Temperature -gt $MaxTemperatureC) {
                        Write-Warning "[failure] $(("Temperature({0}) exceeds max for disk '{1}'" -f $c.Temperature,$d.FriendlyName))"
                        $allHealthy = $false
                    }
                }

                $uncorr = 0
                foreach ($p in 'ReadErrorsUncorrected','WriteErrorsUncorrected','MediaErrors','UncorrectableErrors') {
                    if ($c.PSObject.Properties.Name -contains $p) { $uncorr += [int64]$c.$p }
                }
                if ($uncorr -gt 0) {
                    Write-Warning "[failure] $(("Uncorrectable error counter not zero for disk '{0}'" -f $d.FriendlyName))"
                    $allHealthy = $false
                }

                $percentUsed = $null; $propName='(UNKNOWN)'
                foreach ($name in 'PercentageUsed','PercentUsed','Wear','WearPercentage','LifeRemaining','PercentLifeRemaining','LifeLeftPercent') {
                    if ($c.PSObject.Properties.Name -contains $name) {
                        $val = [double]$c.$name
                        if ($name -in 'LifeRemaining','PercentLifeRemaining','LifeLeftPercent') { $percentUsed = 100 - $val } else { $percentUsed = $val }
                        $propName = $name; break
                    }
                }
                if ($percentUsed -ne $null -and $percentUsed -ge $MaxPercentUsed) {
                    Write-Warning "[failure] $(("{0} >= {1} for disk '{2}'" -f $propName,$MaxPercentUsed,$d.FriendlyName))"
                    $allHealthy = $false
                }
            }
        } catch { }
    }

    if ($allHealthy) { Write-Warning "[pass] HealthTest-Storage passed for all disks" }
}


function HealthTest-NtfsDirtyBit {
    $dirty = @()
    $drives = Get-Volume -FileSystem NTFS -ErrorAction SilentlyContinue
    foreach ($d in $drives) {
      $out = (& fsutil dirty query $d.DriveLetter`: 2>$null)
      if ($out -and ($out -match 'is dirty')) { $dirty += $d.DriveLetter }
    }
    if ($dirty.Count -gt 0) { Write-Warning "[warning] NTFS dirty bit set on: $($dirty -join ', ')"; return }
    Write-Warning "[pass] No NTFS dirty volumes"
}


function HealthTest-NtdsLogVolumeFree{
  [CmdletBinding()] param([int]$MinFreeGB=5)
  $p='HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
  $logPath=(Get-ItemProperty $p -Name 'Database log files path').'Database log files path'
  $drive=(Get-Item $logPath).PSDrive.Name+':'
  $d=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive'"
  $freeGB=[math]::Round($d.FreeSpace/1GB,2)
  if($freeGB -ge $MinFreeGB){ Write-Warning "[pass] NTDS log volume free space OK ($freeGB GB >= $MinFreeGB GB)" } else { Write-Warning "[failure] NTDS log volume low free space ($freeGB GB < $MinFreeGB GB)`nLog path: $logPath" }
}


function HealthTest-RecentDiskErrors {
    param([int]$Hours = 48)

    $pass = $true
    if ($Hours -lt 1) { $Hours = 1 }

    $start     = (Get-Date).AddHours(-$Hours)
    $providers = @('disk','ntfs','stornvme')
    $events    = @()

    foreach ($p in $providers) {
        try {
            Get-WinEvent -FilterHashtable @{
                    LogName      = 'System'
                    ProviderName = $p
                    Level        = 2     # Error
                    StartTime    = $start
            } -ErrorAction SilentlyContinue | %{
                Write-Warning "[failure] Storage($p) error in last N hours`nN=$Hours hours; Event: $($_.TimeCreated), $($_.LevelDisplayName), $($_.Message)"
                $pass = $false
            }
        } catch {
            if ($_.Exception.Message -notlike '*There is not an event provider*') {
                Write-Warning "[warning] Failed reading System log for provider '$p': $($_.Exception.Message)"
            }
        }
    }

    if ($pass) {
        Write-Warning "[pass] No disk/NTFS/storage errors in last $Hours h"
    }

}


function HealthTest-CrashDumpSignals {
    param([int]$Hours = 48)

    $pass = $true
    if ($Hours -lt 1) { $Hours = 1 }
    $cutoff = (Get-Date).AddHours(-$Hours)

    Get-ChildItem "$env:SystemRoot\Minidump" -Filter *.dmp -ErrorAction SilentlyContinue | ?{ $_.LastWriteTime -gt $cutoff } | %{
        Write-Warning "[failure] Found $env:SystemRoot\Minidump\ file(s) within the last N hours`nN=$Hours hours. File: $env:SystemRoot\Minidump\$($_.name))"
    }
    if ($pass) {
        Write-Warning "[pass] No recent minidumps"
    }

    $pass = $true
    Get-WinEvent -FilterHashtable @{
            LogName   = 'System'
            Id        = 1001  # BugCheck
            StartTime = $cutoff
    } -ErrorAction SilentlyContinue | %{
        Write-Warning "[failure] Found System Event #1001 within the last N hours (this event often indicates a crash)`nN=$Hours hours. Event: $($_.TimeCreated), $($_.LevelDisplayName), $($_.Message)"
    }

    if ($pass) {
        Write-Warning "[pass] No recent System #1001 events"
    }
}


function HealthTest-EventLogMaxSizes{
  [CmdletBinding()]
  param([hashtable]$OverrideMinSizesMB)

  $role = (Get-CimInstance Win32_ComputerSystem).DomainRole
  $MinSizesMB = switch ($role) {
    0 { @{Security=20; System=20;  Application=20} }     # Workstation, non-domain
    1 { @{Security=20; System=20;  Application=20} }     # Workstation, domain-joined
    2 { @{Security=512; System=256; Application=256} }    # Server, non-domain
    3 { @{Security=512; System=256; Application=256} }    # Server, domain-joined
    4 { @{Security=1024;System=256; Application=256} }    # DC (non-FSMO)
    5 { @{Security=1024;System=256; Application=256} }    # DC (PDC Emulator)
    Default { @{Security=512; System=256; Application=256} }
  }
  if ($OverrideMinSizesMB) {
    foreach($k in $OverrideMinSizesMB.Keys){ $MinSizesMB[$k] = [int]$OverrideMinSizesMB[$k] }
  }

  $bad=$false
  foreach($name in $MinSizesMB.Keys){
    $sz=[int64]0
    try{
      $log=Get-WinEvent -ListLog $name -ErrorAction Stop
      $sz=[int64]$log.MaximumSizeInBytes
    }catch{
      $out=& wevtutil gl $name 2>&1
      $line=($out | Select-String -Pattern 'maximum size:' -SimpleMatch | Select-Object -First 1).Line
      if($line -and ($line -match 'maximum size:\s*(\d+)')){ $sz=[int64]$Matches[1] }
    }
    if(-not $sz){ Write-Warning "[warning] $name log size could not be determined"; $bad=$true; continue }

    $minMB=[int]$MinSizesMB[$name]
    $minBytes=[int64]$minMB*1MB
    if($sz -lt $minBytes){
      $bad=$true
      $currentMB=[math]::Round($sz/1MB)
      Write-Warning "[failure] $name log maximum size too small`nIt's ${currentMB}MB < ${minMB}MB`nFix: Run  wevtutil sl $name /ms:$minBytes"
    }
  }

  if(-not $bad){ Write-Warning "[pass] Event log maximum sizes meet or exceed baseline" }
}


function Get-FreeGB {
    param([Parameter(Mandatory)][string]$PathOrDrive)

    # Resolve to a drive root like 'C:\'
    $root = $null
    if ($PathOrDrive -match '^[A-Za-z]:\\?$' -or $PathOrDrive -match '^[A-Za-z]:$') {
        $root = ($PathOrDrive.Substring(0,2) + '\')
    } else {
        try {
            $resolved = Resolve-Path -LiteralPath $PathOrDrive -ErrorAction Stop
            $root = [System.IO.Path]::GetPathRoot($resolved.Path)
        } catch { return $null }
    }

    # Try PSDrive first
    try {
        $name = $root.TrimEnd('\').TrimEnd(':')
        $psd  = Get-PSDrive -Name $name -PSProvider FileSystem -ErrorAction Stop
        if ($null -ne $psd.Free) { return [math]::Round(([double]$psd.Free)/1GB,2) }
    } catch {}

    # Fallback to .NET DriveInfo
    try {
        $di = [System.IO.DriveInfo]::new($root)
        if ($di.IsReady) { return [math]::Round($di.AvailableFreeSpace/1GB,2) }
    } catch {}

    return $null
}


function Test-DiskHasFreeSpace {
    param(
        [Parameter(Mandatory)][string]$PathOrDrive,
        [double]$WarnPct = 10,
        [double]$ErrorPct = 5
    )

    $root = $null
    if ($PathOrDrive -match '^[A-Za-z]:\\?$' -or $PathOrDrive -match '^[A-Za-z]:$') {
        $root = ($PathOrDrive.Substring(0,2) + '\')
    } else {
        try {
            $resolved = Resolve-Path -LiteralPath $PathOrDrive -ErrorAction Stop
            $root = [System.IO.Path]::GetPathRoot($resolved.Path)
        } catch { return }
    }

    try {
        $di = [System.IO.DriveInfo]::new($root)
    } catch { return }

    if (-not $di.IsReady) { return }

    $freeGB  = Get-FreeGB -PathOrDrive $root
    $totalGB = [math]::Round($di.TotalSize/1GB, 2)
    if ($di.TotalSize -le 0) { return }

    $pctFree = [math]::Round(($di.AvailableFreeSpace / $di.TotalSize) * 100, 2)
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
        FreeGB       = $freeGB
        TotalGB      = $totalGB
        PercentFree  = $pctFree
        Level        = $level
    }
}
