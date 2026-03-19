<#
OS Performance & Hardware
#>

function Get-PropValue {
# returns a default value if object does not have a property with that name.
# The default value for the default value returned is $null but you can Set
# $default to anything else.
    param($obj, [string]$name, $default=$null)
    if ($obj -and $obj.PSObject -and $obj.PSObject.Properties[$name]) {
        return $obj.PSObject.Properties[$name].Value
    }
    return $default
}

function Test-IsRdsLicensingServer {
<#
.SYNOPSIS
Flags unexpected listening TCP ports; ignores 49152-65535 and notes optional baseline ports (3389, 47001, 593). OnlyForDomainServers
.DESCRIPTION
Filters out ports listening only on the loopback addresses (127.0.0.1 and ::1) before checking against allowed ports.
#>

  [CmdletBinding()]
  [OutputType([bool])]
  param()

  # 1 = Workstation 2 = Domain Controller 3 = Windows Server
  $host_type = (Get-CimInstance Win32_OperatingSystem).ProductType
  if ($host_type -eq 1) { return $false }

  # Detect by service first (works on Server Core and PS7+)
  try {
    $svc = Get-Service -Name 'TermServLicensing' -ErrorAction SilentlyContinue
    if ($svc) { return $true }
  } catch {}

  # Fallback to ServerManager feature check (only works if ServerManager module exists)
  try {
    Import-Module ServerManager -ErrorAction Stop
    $feat = Get-WindowsFeature -Name RDS-Licensing -ErrorAction SilentlyContinue
    if ($feat -and $feat.Installed) { return $true }
  } catch {}

  return $false
}

function HealthTest-TimeSyncPolicy {
<#
.SYNOPSIS
Checks Time Sync Policy

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Resolve-DnsName, Test-IsLaptopOrMobile.
FalsePositives: None.
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


function HealthTest-UpdateAge {
<#
.SYNOPSIS
Checks Update Age

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-HotFix.
FalsePositives: None.
#>
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


function HealthTest-CertExpiry {
<#
.SYNOPSIS
Checks Cert Expiry

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: None.
FalsePositives: None.
#>
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


function HealthTest-IisBindings {
<#
.SYNOPSIS
Checks Iis Bindings

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-WindowsFeature, Get-Website, Get-WebBinding.
FalsePositives: None.
#>
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

function HealthTest-RamPressure {
<#
.SYNOPSIS
Checks Ram Pressure

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-Counter.
FalsePositives: None.
#>
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


function HealthTest-ShareReasonableness {
<#
.SYNOPSIS
Checks Share Reasonableness

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time), High(Time)
Uses: Set-SmbServerConfiguration, Get-SmbShare, Get-SmbShareAccess.
FalsePositives: None.
#>
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


function HealthTest-DisksHaveFreeSpace {
<#
.SYNOPSIS
Checks Disks Have Free Space

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: None.
FalsePositives: None.
#>
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



function HealthTest-NtdsPathsLocation{
<#
.SYNOPSIS
Checks Ntds Paths Location

.DESCRIPTION
AppliesTo: DC
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-ItemProperty.
FalsePositives: None.
#>
  [CmdletBinding()]
  param(
    [string[]]$ExpectedDbRoots,
    [string[]]$ExpectedLogRoots
  )
  $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
  $db = (Get-ItemProperty -Path $regPath -Name 'DSA Database file' -ErrorAction Stop).'DSA Database file'
  $lg = (Get-ItemProperty -Path $regPath -Name 'Database log files path' -ErrorAction Stop).'Database log files path'

  $dbOk = if($ExpectedDbRoots -and $ExpectedDbRoots.Count){
    ($ExpectedDbRoots | Where-Object { $db -like "$($_)*" -or ([IO.Path]::GetPathRoot($db) -eq $_) }).Count -gt 0
  } else { $true }
  if(-not $dbOk){ Write-Warning "[failure] NTDS database path not on an expected volume`nDB=$db; Expected roots: $($ExpectedDbRoots -join ', ')" }

  $lgOk = if($ExpectedLogRoots -and $ExpectedLogRoots.Count){
    ($ExpectedLogRoots | Where-Object { $lg -like "$($_)*" -or ([IO.Path]::GetPathRoot($lg) -eq $_) }).Count -gt 0
  } else { $true }
  if(-not $lgOk){ Write-Warning "[failure] NTDS log path not on an expected volume`nLOGS=$lg; Expected roots: $($ExpectedLogRoots -join ', ')" }

  if($dbOk -and $lgOk){ Write-Warning "[pass] NTDS database/log paths sane (DB=$db; LOGS=$lg)" }
}




function HealthTest-RequiredSrvRecords{
<#
.SYNOPSIS
Checks Required Srv Records

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Resolve-DnsName.
FalsePositives: None.
#>
  $dom=(Get-CimInstance Win32_ComputerSystem).Domain
  $labels=@("_ldap._tcp.dc._msdcs.$dom","_kerberos._tcp.$dom","_kerberos._udp.$dom")
  $missing=$false
  foreach($q in $labels){
    try{ $r=Resolve-DnsName -Type SRV $q -ErrorAction Stop }catch{$r=$null}
    if(-not $r){ $missing=$true; Write-Warning "[failure] $("Required SRV record missing")`n$($q)" }
  }
  if(-not $missing){ Write-Warning "[pass] Required AD SRV records present" }
}

function HealthTest-LdapSigningChannelBinding {
<#
.SYNOPSIS
Checks Ldap Signing Channel Binding

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-ItemProperty.
FalsePositives: None.
#>
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


# TODO this test is repeated in HealthTest-ShareReasonableness

function HealthTest-UnconstrainedDelegationAccounts{
<#
.SYNOPSIS
Checks Unconstrained Delegation Accounts

.DESCRIPTION
AppliesTo: DC
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-ADObject.
FalsePositives: None.
#>
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


function HealthTest-DuplicateSpn{
<#
.SYNOPSIS
Checks Duplicate Spn

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-ADObject.
FalsePositives: None.
#>
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


function HealthTest-GcPlacement{
<#
.SYNOPSIS
Checks Gc Placement

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-ADDomainController.
FalsePositives: None.
#>
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


function Get-SoftwareLicensing {
<#
.SYNOPSIS
Retrieves Windows software licensing product status for the local or remote host.

.DESCRIPTION
Queries `SoftwareLicensingProduct` over CIM, normalizes key properties,
and returns friendly licensing status fields for reporting.
#>

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

function HealthTest-SoftwareLicensing{
<#
.SYNOPSIS
Checks Software Licensing

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Audit / Compliance / Informational
Impact: Medium(Time), High(Time)
Uses: Write-BasedOnTestResult.
FalsePositives: None.
#>
    Get-SoftwareLicensing | %{
        # ($_ | Format-List * -Force | Out-String).Trim()|write-host -f green
        Write-BasedOnTestResult "Is $($_.ProductName) Licensed?" -Test $_.IsLicensed -comment "$_"
    }
}


function HealthTest-TimeSyncAccuracy {
<#
.SYNOPSIS
Checks Time Sync Accuracy

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: None.
FalsePositives: None.
#>
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
<#
.SYNOPSIS
Checks Pagefile Sanity

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-CimInstance.
FalsePositives: None.
#>
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
<#
.SYNOPSIS
Checks Storage

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: Get-PhysicalDisk, Get-StorageReliabilityCounter.
FalsePositives: None.
#>
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
<#
.SYNOPSIS
Checks Ntfs Dirty Bit

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-Volume.
FalsePositives: None.
#>
    $dirty = @()
    $drives = Get-Volume -FileSystem NTFS -ErrorAction SilentlyContinue
    foreach ($d in $drives) {
      $out = (& fsutil dirty query $d.DriveLetter`: 2>$null)
      if ($out -and ($out -match 'is dirty')) { $dirty += $d.DriveLetter }
    }
    if ($dirty.Count -gt 0) { Write-Warning "[warning] NTFS dirty bit set on: $($dirty -join ', ')"; return }
    Write-Warning "[pass] No NTFS dirty volumes"
}

function HealthTest-RecentDiskErrors {
<#
.SYNOPSIS
Checks Recent Disk Errors

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: Get-WinEvent.
FalsePositives: None.
#>
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

function HealthTest-EventLogMaxSizes{
<#
.SYNOPSIS
Checks Event Log Max Sizes

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Select-String.
FalsePositives: None.
#>
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
      $comment="Fix: Run  wevtutil sl $name /ms:$minBytes"
      Write-Warning ("[failure] $name log maximum size too small: ${currentMB}MB < ${minMB}MB`n$comment")
    }
  }

  if(-not $bad){ Write-Warning "[pass] Event log maximum sizes meet or exceed baseline"}
}
