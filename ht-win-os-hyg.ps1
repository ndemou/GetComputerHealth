<#
Windows OS Hygiene
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
        Write-Warning ("[pass] Did windows defender perform a quick scan recently?`n$comment")
    } elseif ($days -lt $MAX_FAILURE_DAYS) {
        Write-Warning ("[warning] Did windows defender perform a quick scan recently?`n$comment")
    } else {
        Write-Warning ("[failure] Did windows defender perform a quick scan recently?`n$comment")
    }
}


function HealthTest-SchanelBaseline{
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
    $why="LDAP over TLS, WinRM, ADWS, and other Schannel consumers may negotiate legacy handshakes/ciphers if enabled."
    $comment = ("Detected mismatches:`n"+($bad | ForEach-Object { "  - {0}: Current={1}, Recommended={2}" -f $_.Protocol,$_.CurrentState,$should[$_.Protocol] } | Out-String) + "`nRegistry snapshot:`n"+$det+$why)
    Write-Warning "[failure] Schannel baseline not hardened`n$comment"
  }
}

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
      Write-Warning "[pass] Defender signatures fresh (AV=$($s.AntivirusSignatureVersion))"} else {
    }
}

function HealthTest-FirewallEnabled {
    Write-BasedOnTestResult "Is mpssvc (the firewall service) enabled?" -Test ((Get-Service -name mpssvc).status -eq 'Running')
    Get-NetFirewallProfile | ForEach-Object {
        Write-BasedOnTestResult "Is firewall enabled for the $($_.Name) profile?" -Test ($_.Enabled -eq 1) -comment "To enable firewall for *ALL* profiles run this:`nSet-NetFirewallProfile -Profile Domain,Private,Public -Enabled True"
    }
}


function HealthTest-Smb1Disabled{
  $f=Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -ErrorAction SilentlyContinue
  $state=$f.State
  $disabled=($state -eq 'Disabled' -or -not $f -or $state -eq 'DisabledWithPayloadRemoved')
  if($disabled){ Write-Warning "[pass] SMBv1 is disabled"} else { Write-Warning "[warning] SMBv1 is enabled`nState=$state" }
}

function HealthTest-WmiRepository{
  $out=& winmgmt /verifyrepository 2>&1
  $ok=($out -match 'consistent')
  if($ok){ Write-Warning "[pass] WMI repository consistent"} else { Write-Warning ("[failure] WMI repository inconsistent`n" + ($out -join ' ')) }
}


function HealthTest-VssWriters{
  $out=& vssadmin list writers 2>&1
  $bad=($out | Select-String -Pattern 'State: \d+ \((?i:Retryable error|Waiting for completion|Failed)\)')
  if($bad){
    foreach($b in $bad){ Write-Warning "[failure] VSS writer not healthy`n$($b.Line)" }
  } else {
    Write-Warning "[pass] All VSS writers report stable states"}
}

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
      Write-Warning ("[notice] " + ("Unsigned device instance treated as benign: {0}{1}{2}" -f $manText,$d.DeviceName,$provText))
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
    Write-Warning ("[failure] " + ("Unsigned 3rd-party driver detected: {0}{1} ver [{2}]" -f ($(if($man){"$man, "}), $d.DeviceName, $ver)) + "`n" + ("Details: {0}" -f $detail))
  }

  if(-not $bad){ Write-Warning "[pass] All non-Microsoft PnP drivers appear signed (benign logical/child nodes and whitelisted instances excluded)."}
}

<#
.SYNOPSIS
Flags unexpected listening TCP ports; ignores 49152-65535 and notes optional baseline ports (3389, 47001, 593). OnlyForDomainServers
.DESCRIPTION
Filters out ports listening only on the loopback addresses (127.0.0.1 and ::1) before checking against allowed ports.
#>

<#
.SYNOPSIS
Verifies DFS Namespace (domain-based) objects enumerate without error. OnlyForDomainServers
#>
<#
.SYNOPSIS
Lists SYSTEM-scheduled tasks that are disabled, stale, or failing.
#>

<#
.SYNOPSIS
Checks SYSVOL NTFS ACLs do not grant write to broad principals. OnlyForDCs
#>

<#
.SYNOPSIS
Reports accounts permitting RC4 via msDS-SupportedEncryptionTypes. OnlyForDomainServers
#>

<#
.SYNOPSIS
Ensures DHCP server presence/authorization sane if role installed. OnlyForDomainServers
#>

<#
.SYNOPSIS
Flags enabled NICs that are disconnected (cleanup). OnlyForDomainServers
#>

<#
.SYNOPSIS
Checks active interface metrics for sane binding preference. OnlyForDomainServers
#>

<#
.SYNOPSIS
Detects disabled GPO links at domain root (policy choice). OnlyForDCs
#>

<#
.SYNOPSIS
Ensures event log max sizes meet baseline without reading events. OnlyForDomainServers
#>

<#
.SYNOPSIS
Runs DCDIAG RIDManager and checks for failures or low pool signals. OnlyForDCs
#>

<#
.SYNOPSIS
Checks presence of EFS Data Recovery Agents policy/certs. OnlyForDomainServers
#>
<#
.SYNOPSIS
Verifies DNS zone transfers are restricted. OnlyForDCs
#>

<#
.SYNOPSIS
Flags stale krbtgt (pwdLastSet age above threshold). OnlyForDomainServers
.NOTES
What a failure means: The KRBTGT account key hasn't been rotated for years. Windows keeps the previous KRBTGT key to validate existing TGTs; never rotating extends the window for 'golden ticket' persistence if the key ever leaked.
Risk: If an attacker ever accessed the KRBTGT key, they can mint TGTs and persist. Rotating twice (with replication time in between) is the standard mitigation.
Severity: Critical.
#>

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
  if($freeGB -ge $MinFreeGB){
    Write-Warning "[pass] NTDS log volume free space OK ($freeGB GB >= $MinFreeGB GB)"
  } else {
    Write-Warning (
      "[failure] " +
      "NTDS log volume low free space ($freeGB GB < $MinFreeGB GB)" +
      "`n" +
      "Log path: $logPath"
    )
  }
}

<#
.SYNOPSIS
Verifies required hotfix baseline is present. OnlyForDomainServers
#>
<#
.SYNOPSIS
Validates DHCP DNS update credential account health. OnlyForDomainServers
#>

<#
.SYNOPSIS
Validates GPT vs GPC version numbers for GPO consistency. OnlyForDomainServers
#>

<#
.SYNOPSIS
Compares SYSVOL policy tree manifest across DCs (count+hash). OnlyForDCs
.NOTES 
Stresses Network: SMB directory tree walks to each DC's SYSVOL\Policies across sites.
#>

<#
.SYNOPSIS
Reviews RODC PRP (allow/deny) presence where RODCs exist. OnlyForDomainServers
#>

<#
.SYNOPSIS
Reports members of 'Pre-Windows 2000 Compatible Access' (should be empty). OnlyForDomainServers
#>

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
    Write-Warning "[warning] This machine cannot read LDAP RootDSE. Is it domain-joined and can it reach a DC?"; return
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
        Write-Warning "[pass] No GPO WMI filters defined (CN=WMIPolicy container not found)."; return
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
      Write-Warning "[warning] Cannot enumerate WMI filters via GPMC or LDAP. Check: domain join, DC reachability/DNS, and GPMC installation."; return
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

  if(-not $bad){ Write-Warning "[pass] All WMI namespaces referenced by GPO WMI filters exist on this host"}
  else{ Write-Warning "[warning] One or more GPO WMI filter namespaces are missing on this host"}
}
<#
.SYNOPSIS
Verifies Windows are Licensed.
#>
<#
.SYNOPSIS
Checks if TPM is activated. OnlyForMobile
#>



<#
.SYNOPSIS
Checks DNS suffix for the AD domain. OnlyForDomain,NotForDCs
#>
<#
.SYNOPSIS
Checks that the domain DNS name A record points to at least one DC IP. OnlyForDomain,NotForDCs

IMPORTANT: Invoke-GetHealthDomainComputers.ps1 must pass all DC IPs via
	`-IpsOfAllDcs`. E.g:
	@("192.168.0.1","192.168.0.2")
#>
function HealthTest-DomainARecordPointsToDcIp {
  $cs = Get-CimInstance Win32_ComputerSystem
  $role = $cs.DomainRole
  $fn = $MyInvocation.MyCommand.Name
  if ($role -in 0,2) { Write-Warning "[notice] This test ($fn) is not applicable to non-domain joined hosts"; return }
  if ($role -in 4,5) { Write-Warning "[notice] This test ($fn) is not applicable to Domain Controllers"; return }
  $dcIps = @($Global:GetComputerHealthDataQMTA.IpsOfAllDcs)

  $domain = $cs.Domain
  $ares = $null
  try { $ares = Resolve-DnsName -Name $domain -Type A -ErrorAction Stop } catch {}
  if (-not $ares) {
    Write-Warning "[failure] No A records found for domain DNS name.`n$domain"
    return
  }

  $aIps = @($ares | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
  $intersection = @()
  foreach ($ip in $aIps) { if ($dcIps -contains $ip) { $intersection += $ip } }

  $comment = "Domain=$domain; DC IPs=" + ($dcIps -join ', ') + "; Domain A IPs=" + ($aIps -join ', ')
  if ($intersection.Count -gt 0) {
    Write-Warning ("[pass] Domain DNS name resolves to at least one DC IP.`n$comment")
  } else {
    Write-Warning ("[failure] Domain DNS name does not resolve to any known DC IPv4 address.`n$comment")
  }
}

<#
.SYNOPSIS
Ensures each interface DNS server list contains only DC IPs. OnlyForDomain,NotForDCs

IMPORTANT: Invoke-GetHealthDomainComputers.ps1 must pass all DC IPs via
	`-IpsOfAllDcs`. E.g:
	@("192.168.0.1","192.168.0.2")
#>

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
    Write-Warning "[pass] NLTEST /dsgetsite succeeded.`nSite: $site"
  } else {
    $hex = '0x{0:X}' -f ($exit -band 0xFFFFFFFF)
    Write-Warning "[failure] NLTEST /dsgetsite failed.`nExitCode=$hex; Output=`n$txt"
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
    Write-Warning "[pass] Computer and user policy updates completed successfully (gpupdate)."; return
  }

  if ($compOk) {
    Write-Warning "[pass] Computer policy update completed successfully (gpupdate)."
  } else {
    Write-Warning ("[failure] Computer policy update did not report success.`ngpupdate output:`n" + $text)
  }

  if (-not $userOk) {
    if ($isSystem) {
      Write-Warning ("[notice] User policy update did not report success (gpupdate running under SYSTEM/non-interactive).`nThis can be expected when no interactive user is logged on.`nRaw gpupdate output:`n" + $text)
    } else {
      Write-Warning ("[failure] User policy update did not report success.`nExpected success for interactive user.`nRaw gpupdate output:`n" + $text)
    }
  } else {
    Write-Warning "[pass] User policy update completed successfully (gpupdate)."
  }
}

#--------------------------------------------------------
# xxx new tests 20205-11-26

<# .SYNOPSIS Checks recent critical disk/NTFS/storage errors in the System event log. #>

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
        Write-Warning "[pass] No recent minidumps"}

    $pass = $true
    Get-WinEvent -FilterHashtable @{
            LogName   = 'System'
            Id        = 1001  # BugCheck
            StartTime = $cutoff
    } -ErrorAction SilentlyContinue | %{
        Write-Warning "[failure] Found System Event #1001 within the last N hours (this event often indicates a crash)`nN=$Hours hours. Event: $($_.TimeCreated), $($_.LevelDisplayName), $($_.Message)"
    }

    if ($pass) {
        Write-Warning "[pass] No recent System #1001 events"}
}

<# .SYNOPSIS Detects unexpected members in the local Administrators group. #>
<# .SYNOPSIS Checks physical NICs for link problems and significant error rates. #>

<# .SYNOPSIS Summarizes BitLocker protection status for local volumes. #>
<# .SYNOPSIS Detects DHCP scopes whose utilization is close to exhaustion. #>

<#
.SYNOPSIS
  Verifies key DNS suffix/devolution/registration settings for a small, single-domain AD.
#>

<#
.SYNOPSIS
HealthTest-ADReplicationDomainRepadmin: Domain-wide AD replication health using repadmin.exe (replsum + showreps). DC-only; fails if repadmin or AD DS prerequisites are missing.
#>

<#
.SYNOPSIS
HealthTest-ADReplicationLocalRSAT: Local DC AD replication partner health using RSAT AD cmdlets (Get-ADReplicationPartnerMetadata). DC-only; fails if AD module/ADWS prerequisites are missing.
#>

function HealthTest-HotfixBaseline{
  [CmdletBinding()] param([string[]]$RequiredKBs)
  if(-not $RequiredKBs -or $RequiredKBs.Count -eq 0){ Write-Warning "[pass] No hotfix baseline provided"; return }
  $have=(Get-HotFix | Select-Object -ExpandProperty HotFixID)
  $miss=@()
  foreach($kb in $RequiredKBs){
    if($have -notcontains $kb){ $miss += $kb; Write-Warning "[failure] Missing required hotfix: $kb"}
  }
  if($miss.Count -eq 0){ Write-Warning "[pass] All required hotfixes are installed"}
}

function HealthTest-BitLockerStatus {
    if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        Write-Warning "[warning] BitLocker PowerShell cmdlets not available; skipping BitLocker status check"; return
    }

    $pass = $true

    $vols = Get-BitLockerVolume -ErrorAction SilentlyContinue
    if (-not $vols) {
        Write-Warning "[notice] No BitLocker-capable volumes found"}
    $vols | Where-Object { $_.ProtectionStatus -ne 'On' } | %{
        Write-Warning "[failure] Volume not protected by BitLocker: $($_.MountPoint)"
        $pass = $false
    }
    if ($pass) {
        Write-Warning "[pass] BitLocker protection is ON for all detected volumes"}
}


function HealthTest-EfsRecoveryAgents{
  $out=& certutil -recoveryagent 2>&1
  $has=($out | Select-String -Pattern 'Recovery Agent' -SimpleMatch)
  if($has){ Write-Warning "[pass] EFS Data Recovery Agents are configured"} else { Write-Warning "[notice] No EFS Data Recovery Agents configured.`nIf anyone uses EFS (NTFS file encryption), there's no domain recovery agent to decrypt data if the user's key is lost." }
}


function HealthTest-NtlmHardening {
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


function HealthTest-RdpHardening {
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


function HealthTest-LocalAcntRequirePass {
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


function HealthTest-RestrictAnonymous {
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

function HealthTest-PendingReboot {
    $pending = $false
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending = $true }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending = $true }
    $pfr = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
    if ($pfr -and $pfr.PendingFileRenameOperations) {write-debug "Found entries in HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations (if you are not sure what this means, you can safely ignore it)"}
    if ($pending) { Write-Warning "[notice] Windows need a reboot to apply some changes"; return}
    Write-Warning "[pass] No pending reboot indicators"
}

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
