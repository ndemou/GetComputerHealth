# HostRequirement: All

if (-not (Get-Command -Name 'Test-IsLaptopOrMobile' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helpers-for-healthtests.ps1')
}


function HealthTest-TimeSyncPolicy {
<#
Description: Checks whether Windows Time is configured against the expected time source policy.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time), Medium(Network)
Tags: Essential
Uses: Resolve-DnsName, w32tm.exe, Test-IsLaptopOrMobile.
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
        return @($names | Select-Object -Unique)
    }

    # --- Step 1: Role Detection ---
    $compSystem = Get-CimInstance Win32_ComputerSystem
    $domainRole = $compSystem.DomainRole
    $domainName = $compSystem.Domain

    $isHostDC = ($domainRole -in 4, 5)
    $IsHostInDomain = ($domainRole -in 1, 3, 4, 5)
    $isHostPDC = $false
    $dcNameSet = @()

    $msg = "Role Detection: DomainJoined=$IsHostInDomain, IsDC=$isHostDC (Role ID: $domainRole), Domain=$domainName"
    Write-Verbose $msg
    $evidences += $msg

    if ($IsHostInDomain -and $domainName) {
        $dcNameSet = @(Get-DnsDomainControllers -DomainName $domainName)
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
                Write-Warning "[WARNING] HealthTest-TimeSyncPolicy: Unable to determine PDC Role via DNS SRV record: $_"
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
    if ($IsHostInDomain -and (-not $isHostPDC)) {
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
          Write-Warning ("[FAILURE] Misconfiguration: syncing from myself.`n" + ($evidences -join "`r`n"))
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
            Write-Warning "[FAILURE] PDC time syncing type is NT5DS, this is only valid if this is a subdomain and you are syncing from the higher domain`n$evidenceString"
        }
        elseif ($timeSyncType -notin 'NTP', 'AllSync') {
            Write-Warning "[FAILURE] PDC time syncing type is '$timeSyncType' instead of 'NTP' or 'AllSync'.`n$evidenceString"
        }
        elseif ($isActiveCMOS) {
            Write-Warning "[FAILURE] PDC currently reports 'Local CMOS Clock'.`n$evidenceString"
        }
        elseif ($isActiveVMIC) {
            Write-Warning "[FAILURE] PDC is currently syncing from hypervisor (Source='$currentTimeSource').`n$evidenceString"
        }
        else {
            if ($vmicEnabled) {
                if ($isHostPDC) {
                    $comment = "Since this is a PDC consider disabling VM time sync for strict NTP-only behavior."
                }
                else {
                    $comment = ""
                }
                Write-Warning "[NOTICE] VMICTimeProvider is enabled, but not used.`n$comment"
            }
            if (Looks-ExternalNtp $currentTimeSource) {
                Write-Warning "[PASS] PDC emulator time syncing looks correct (Type=$timeSyncType, Source='$currentTimeSource')."
            }
            else {
                Write-Warning "[NOTICE] PDC emulator Type=$timeSyncType, Source='$currentTimeSource' (not sure if this is a good external NTP)."
            }
        }
    }
    elseif ($isHostDC) {
        # ---- CHECKS FOR DCs (except PDCs) ---
        if ($timeSyncType -ne 'NT5DS') {
            Write-Warning "[FAILURE] DC time syncing type is '$timeSyncType' (expected 'NT5DS').`n$evidenceString"
        }
        elseif ($isActiveVMIC) {
            Write-Warning "[FAILURE] DC is currently syncing from hypervisor (Source='$currentTimeSource').`n$evidenceString"
        }
        elseif ($isActiveCMOS) {
            Write-Warning "[FAILURE] DC reports 'Local CMOS Clock'.`n$evidenceString"
        }
        elseif (Looks-ExternalNtp $currentTimeSource) {
            Write-Warning "[FAILURE] DC appears to be using an external NTP source ('$currentTimeSource') instead of domain hierarchy (NT5DS).`n$evidenceString"
        }
        elseif ($isSourceDC) {
            Write-Warning "[PASS] DC time syncing is OK (Type=$timeSyncType, Source='$currentTimeSource')."
        }
        else {
            Write-Warning "[FAILURE] DC is not clearly syncing from domain hierarchy (Type=$timeSyncType, Source='$currentTimeSource').`n$evidenceString"
        }
    }
    elseif ($IsHostInDomain) {
        # ---- CHECKS FOR Domain Joined servers except DCs, PDCs ---
        if ($timeSyncType -ne 'NT5DS') {
            Write-Warning "[FAILURE] Domain member time syncing type is '$timeSyncType' instead of 'NT5DS'.`n$evidenceString"
        }
        elseif ($isActiveVMIC) {
            $domainMemberVmicRemediation = @'

To configure this member server to sync time from the domain execute these commands:
w32tm /config /syncfromflags:DOMHIER /reliable:NO /update; Restart-Service w32time; w32tm /resync /rediscover
'@
            Write-Warning "[FAILURE] Domain member is currently syncing from hypervisor (Source='$currentTimeSource').`n$evidenceString$domainMemberVmicRemediation"
        }
        elseif ($isActiveCMOS) {
            if (Test-IsLaptopOrMobile) {
                Write-Warning "[WARNING] This domain member (likely a laptop) is not syncing time from domain (Source='Local CMOS Clock')."
            }
            else {
                Write-Warning "[FAILURE] Domain member is not syncing time from domain (Source='Local CMOS Clock').`n$evidenceString"
            }
        }
        elseif (Looks-ExternalNtp $currentTimeSource) {
            Write-Warning "[FAILURE] Domain member appears to be using an external NTP source ('$currentTimeSource') instead of domain hierarchy.`n$evidenceString"
        }
        elseif ($isSourceDC) {
            Write-Warning "[PASS] Domain member is syncing via domain hierarchy (Type=$timeSyncType, Source='$currentTimeSource')."
        }
        else {
            Write-Warning "[FAILURE] Domain member is not clearly syncing via domain hierarchy (Type=$timeSyncType, Source='$currentTimeSource').`n$evidenceString"
        }
    }
    else {
        # ---- CHECKS FOR Standalone PCs ---
        if ($currentTimeSource -eq 'Local CMOS Clock' -or -not $currentTimeSource) {
            Write-Warning "[FAILURE] Standalone machine is not syncing time (Source='$currentTimeSource').`n$evidenceString"
        }
        elseif ($isActiveVMIC) {
            Write-Warning "[PASS] Standalone machine is syncing via Hypervisor/VM Tools."
        }
        else {
            # Assume anything else is a valid NTP server (IP or DNS name)
            Write-Warning "[PASS] Standalone machine is syncing from external source '$currentTimeSource'."
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-TimeSyncPolicy
}
