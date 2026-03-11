<#
System Configuration & Feature Discovery
#>

function HealthTest-InstalledRolesFeatures {
  [CmdletBinding()]
  param([string[]]$DisallowedRoles = @('Web-Server','DHCP','WDS'))

  $roles = $null
  try { $roles = Get-WindowsFeature -ErrorAction Stop | Where-Object { $_.Installed } }
  catch {
    Write-Output "Get-WindowsFeature not available on this OS; skipping role/feature check"
    return
  }

  $hit = @($roles | Where-Object { $DisallowedRoles -contains $_.Name })
  if ($hit.Count -gt 0) {
    foreach ($h in $hit) { Write-Warning "[failure] Unintended role/feature installed: $($h.Name)" }
  } else {
    Write-Warning "[pass] No unintended roles/features installed"
  }
}
<#
.SYNOPSIS
Checks if there are any non-default file or print shares on this machine.

.DESCRIPTION
Warns if any non-hidden shares (not ending in $) exist besides SYSVOL.
If none exist, outputs a good status. Also suggests disabling the LanmanServer
service if file and print sharing is not needed on non-domain controllers.
#>
<#
.SYNOPSIS
Checks for services set to start automatically but are not currently running.

.DESCRIPTION
Warns about any services with StartType=Automatic that are stopped (excluding a few known exceptions).
Reports success if all automatic services are running.
#>

<#
.SYNOPSIS
Checks if the system default locale (ACP/OEMCP) matches expected values.

.DESCRIPTION
Validates the system's ANSI (ACP) and OEM code pages. Warns if they are not the usual Greek (1253/737) or English (1252/437) combinations.
#>

<#
.SYNOPSIS
Checks if any local user accounts have PasswordRequired set to False.

.DESCRIPTION
Finds enabled local accounts without required passwords and reports them as failures.
#>

<#
.SYNOPSIS
Checks if any fixed, removable, or network drives are low on free space.

.NOTES
Relies on Test-DiskHasFreeSpace to perform the actual threshold check.
#>
<#
.SYNOPSIS
Warns for every directory that has more than 10,000 immediate child items.

.DESCRIPTION
Uses Find-LargeDirectory to locate directories with high item counts under C:\.
Each matching directory is logged as a warning with the item count in -Comment.
#>
<#
.SYNOPSIS
Reports a warning for any non Microsoft service it finds
#>
<#
.SYNOPSIS
Checks if any Hyper-V VMs that should auto-start are not currently running.

.DESCRIPTION
Lists all VMs where AutomaticStartAction is "Start" but their state is not "Running" and reports them as failures.
#>
<#
.SYNOPSIS
Checks running Hyper-V VMs for unexpected property values.

.DESCRIPTION
Iterates through running VMs and compares selected properties against the expected values stored in $EXPECTED_VALUES_FOR_VM_PROPERTIES.
Warns if any property value does not match the expected value.
#>
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
<#
.SYNOPSIS
Checks if Windows Defender performed a quick scan recently
#>
<#
.SYNOPSIS
Tests SYSVOL/NETLOGON accessibility across DCs.
.DESCRIPTION
Checks UNC reachability for \\<DC>\SYSVOL and \\<DC>\NETLOGON.
#>
<#
.SYNOPSIS
Ensures AD schema objectVersion matches across all DCs.

.DESCRIPTION
Reads objectVersion from the Schema NC via each DC and normalizes to [int].
Passes if there is exactly one distinct version. Returns details per-DC and a summary.
#>
<#
.SYNOPSIS
Verifies NTDS.dit and log paths are on intended volumes.
.DESCRIPTION
Reads NTDS parameters and returns their current locations.
#>
<#
.SYNOPSIS
Checks tombstoneLifetime and links interval sanity.
#>
<#
.SYNOPSIS
Confirms AD Recycle Bin is enabled.
#>
<#
.SYNOPSIS
Verifies domain trusts and performs netdom /verify.
#>
<#
.SYNOPSIS
Checks replication latency on schema/config partitions.
#>
<#
.SYNOPSIS
Validates DNS zone replication scope for AD-integrated zones.
#>
<#
.SYNOPSIS
Confirms some important SRV records exist:
_ldap._tcp.dc._msdcs.<domain> = where are the Domain Controllers (LDAP over TCP)?
_kerberos._tcp.<domain> = where are Kerberos KDCs over TCP?
_kerberos._udp.<domain> = where are Kerberos KDCs over UDP?
#>
<#
.SYNOPSIS
Checks DNS scavenging/aging configuration (server + per-zone).
.DESCRIPTION
Returns Pass=$true only if server scavenging is enabled AND all AD-integrated primary zones have AgingEnabled=$true.
Details list server state and zones with/without aging.
#>
<#
.SYNOPSIS
Validates DNS forwarders reachability and forbids loopback.
#>
<#
.SYNOPSIS
Ensures LDAP signing and channel binding settings are enforced.
#>
<#
.SYNOPSIS
Requires SMB signing on the server.
#>
# TODO this test is repeated in HealthTest-ShareReasonableness
<#
.SYNOPSIS
Verifies SMBv1 is disabled.
#>

<#
.SYNOPSIS
Finds accounts with unconstrained delegation (excludes DCs by default).

.DESCRIPTION
Flags user/computer objects where userAccountControl has TRUSTED_FOR_DELEGATION (0x80000).
By default excludes Domain Controllers (SERVER_TRUST_ACCOUNT 0x2000), since DCs are inherently trusted.
Use -IncludeDomainControllers to include them in the results.
#>
<#
.SYNOPSIS
Flags service accounts with PasswordNeverExpires.
#>
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
<#
.SYNOPSIS
Checks that a pagefile exists and meets a minimum size.

.DESCRIPTION
Handles both explicit and system-managed pagefiles.
- Primary source: Win32_PageFileUsage (current allocated size).
- Fallback: 'PagingFiles' registry (C:\pagefile.sys 0 0 means system-managed).
Pass=$true when total AllocMB >= MinMB, and (optionally) one pagefile is on the system drive.
#>
<#
.SYNOPSIS
Confirms WinRM is running and responsive.
#>
<#
.SYNOPSIS
Verifies IPv6 binding state per policy (PS5.1-safe).
#>
<#
.SYNOPSIS
Verifies DNS Client service is running.
#>
<#
.SYNOPSIS
Verifies WMI repository consistency.
#>
<#
.SYNOPSIS
Lists VSS writers and flags non-stable states.
#>
<#
.SYNOPSIS
Checks shadow storage presence and size info.
#>
<#
.SYNOPSIS
Scrapes common auto-start locations for rogues.
#>

<#
.SYNOPSIS
Detects duplicate SPNs by querying AD directly (no setspn parsing).

.DESCRIPTION
Enumerates all directory objects that have servicePrincipalName, groups by SPN,
and flags any SPN that appears on more than one distinct object.

RETURNS
[pscustomobject]@{ Pass=bool; Details=string }
#>
<#
.SYNOPSIS
Ensures the host does not have multiple default gateways.

.DESCRIPTION
Collects IPv4/IPv6 default gateways from Get-NetIPConfiguration. By default Pass=$true only if the
total count of default gateways (v4+v6) <= 1. Use -AllowOnePerFamily to permit up to one v4 and one v6.
#>
<#
.SYNOPSIS
Checks for stale/mismatched DC DNS A records vs. AD DC IPs. OnlyForDCs
#>
<#
.SYNOPSIS
Validates DNS recursion configuration (enabled/forwarders/EDNS). OnlyForDCs
#>

<#
.SYNOPSIS
Confirms reverse lookup zones exist for known subnets. OnlyForDCs
#>
<#
.SYNOPSIS
Checks GC placement (at least one per site or per-domain policy). OnlyForDCs
#>
<#
.SYNOPSIS
Checks AdminSDHolder applied to protected groups reasonably. OnlyForDomainServers
#>
<#
.SYNOPSIS
DFSR backlog for SYSVOL within threshold. OnlyForDCs
.NOTES Stesses Network: Potentially noticeable on the WAN if run frequently or in parallel
#>
<#
.SYNOPSIS
Flags unsigned PnP drivers, ignoring common false positives from core system components.
  OnlyForDomainServers
#>
<#
.SYNOPSIS
Flags unexpected listening TCP ports; ignores 49152-65535 and notes optional baseline ports (3389, 47001, 593). OnlyForDomainServers
.DESCRIPTION
Filters out ports listening only on the loopback addresses (127.0.0.1 and ::1) before checking against allowed ports.
#>
function Test-IsRdsLicensingServer {
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
    Write-Warning "[pass] No startup items found in standard keys"}
}
