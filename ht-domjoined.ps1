<#
Tests only for domain joined servers (including DC/PDC)
#>

function HealthTest-InterfaceDnsServersUseDcs {
<#
.SYNOPSIS
Checks Interface Dns Servers Use Dcs

.DESCRIPTION
AppliesTo: DomainJoined
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Get-CimInstance.
FalsePositives: None.
#>
  $cs = Get-CimInstance Win32_ComputerSystem
  $role = $cs.DomainRole
  $fn = $MyInvocation.MyCommand.Name
  if ($role -in 0,2) { Write-Warning "[notice] This test ($fn) is not applicable to non-domain joined hosts"; return }
  if ($role -in 4,5) { Write-Warning "[notice] This test ($fn) is not applicable to Domain Controllers"; return }
  $dcIps = @($Global:GCHDQMTA.IpsOfAllDcs)

  $nets = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=TRUE"
  if (-not $nets) {
    Write-Warning "[failure] No IP-enabled network adapters found."; return
  }

  $anyClean = $false
  $anyBad   = $false

  foreach ($net in $nets) {
    $dns  = $net.DNSServerSearchOrder
    $desc = $net.Description
    if (-not $dns -or $dns.Count -eq 0) {
      Write-Warning "[notice] Interface has no DNS servers configured.`n$desc"
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
      Write-Warning "[pass] Interface has only DCs as DNS servers.`nInterface: $desc; DNS=$dnsList"
    } elseif ($allNonDomain) {
      # Ignoring this interface that only has non-domain DNS servers
    } else {
      $anyBad = $true
      Write-Warning "[failure] Interface DNS servers include non-DC addresses.`nInterface: $desc; DNS=$dnsList; DC IPs=$($dcIps -join ', ')"
    }
  }

  if (-not $anyClean) {
    Write-Warning "[failure] No interface found where all DNS servers are DC IPs."} elseif (-not $anyBad) {
    Write-Warning "[pass] All interfaces with DNS configured use only DC IPs."}
}


function HealthTest-DnsSuffixMatchesDomain {
<#
.SYNOPSIS
Checks Dns Suffix Matches Domain

.DESCRIPTION
AppliesTo: DomainJoined
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Select-String.
FalsePositives: None.
#>
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

function HealthTest-DnsSuffixBaseline {
<#
.SYNOPSIS
Checks Dns Suffix Baseline

.DESCRIPTION
AppliesTo: DomainJoined
Scope: Computer
Category: Audit / Compliance / Informational
Impact: Medium(Network)
Uses: Get-DnsClientGlobalSetting, Get-DnsClient.
FalsePositives: None.

TODO: maybe part of these tests are for non-domain joined Computers also
#>
    $DomainName=(Get-CimInstance Win32_ComputerSystem).Domain

    # 1) Primary DNS suffix equals the AD DNS name
    $ipg = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    $primarySuffix = $ipg.DomainName

    if ([string]::IsNullOrWhiteSpace($primarySuffix)) {
        Write-Warning ("[failure] Primary DNS suffix: Current is empty" + "`n" + "Ensure the system has a primary DNS suffix (normally set by domain join).")
    } elseif ($primarySuffix -ieq $DomainName) {
        Write-Warning "[pass] Primary DNS suffix`n$primarySuffix"
    } else {
        Write-Warning "[failure] Primary DNS suffix"("Current='{0}' Expected='{1}'" -f $primarySuffix,$DomainName) "Ensure primary DNS suffix equals the AD DNS name (normally set by domain join)."
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
        $comment = ("Unable to query global DNS client settings: {0}" -f $err.Exception.Message) + "`nCheck OS support for Get-DnsClientGlobalSetting and that the DNS Client service is running."
        Write-Warning "[failure] DNS devolution enabled`n$comment"
    }

    # 3) Per-NIC checks (only PASS/FAIL; no discovery warning if none found)
    $nics = @()
    try {
        $nics = Get-DnsClient -ErrorAction Stop |
                Where-Object { $_.InterfaceOperationalStatus -eq "Up" -and $_.ConnectionSpecificSuffix -ne "localdomain" }
    } catch {
        $err = $_
        $comment = "Unable to query DNS client interfaces: $($err.Exception.Message)`nConfirm OS supports Get-DnsClient and you have sufficient privileges."
        Write-Warning "[failure] NIC DNS settings`n$comment"
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

function HealthTest-ConnectivityToDCs {
<#
.SYNOPSIS
Checks Connectivity To D Cs

.DESCRIPTION
AppliesTo: DomainJoined
Scope: Computer
Category: Availability / Server Down Signals
Impact: Medium(Network)
Uses: Resolve-DnsName, Get-ADForest.
FalsePositives: None.
#>
  $dcs  = Get-DomainControllers

  foreach ($s in $dcs) {
    $fqdn = $s.ToLower()
    # 1) DNS resolution
    try {
      [System.Net.Dns]::GetHostAddresses($fqdn) | Out-Null
      Write-Warning "[pass] DNS resolved for $fqdn"
    } catch {
      Write-Warning "[failure] DNS resolution failed for $fqdn`nCheck forward/reverse lookup zones and _msdcs records. Command: nslookup $fqdn"
      continue
    }

    # 2) Core ports
    $ports =  @(
      @{Port=53;  Proto='TCP'; Name='DNS'},
      @{Port=389; Proto='TCP'; Name='LDAP'},
      @{Port=636; Proto='TCP'; Name='LDAPS'},
      @{Port=88;  Proto='TCP'; Name='Kerberos'},
      @{Port=135; Proto='TCP'; Name='RPC endpoint mapper'},
      @{Port=9389;Proto='TCP'; Name='AD Web Services'}
    )
    foreach ($p in $ports) {
      $res = Test-NetConnectionFast -ComputerName $fqdn -Port $p.Port -WarningAction SilentlyContinue
      if ($res.TcpTestSucceeded) {
        Write-Warning "[pass] $($p.Name) port open on $fqdn"
      } else {
        Write-Warning "[failure] TCP port $($p.Port)($($p.Name)) unreachable on $fqdn`nPort $($p.Port)/$($p.Proto) blocked or service down. Check firewall and service status."
      }
    }

    # 3) SRV records check for LDAP
    $domainName=(Get-CimInstance Win32_ComputerSystem).Domain
    try {
      $srv = Resolve-DnsName -Type SRV "_ldap._tcp.dc._msdcs.$domainName" -ErrorAction Stop
      if ($srv.Name -contains $fqdn) {
        Write-Warning "[pass] SRV record present for $fqdn"
      } else {
        Write-Warning "[failure] Missing SRV record for $fqdn`nDC not registered in _ldap._tcp.dc._msdcs. Run ipconfig /registerdns on $fqdn."
      }
    } catch {
      Write-Warning "[failure] Could not query SRV records.`nCheck DNS service and replication for zone _msdcs.$((Get-ADForest).RootDomain)."
    }
  }
}


function HealthTest-EfsRecoveryAgents{
<#
.SYNOPSIS
Checks Efs Recovery Agents

.DESCRIPTION
AppliesTo: DomainJoined
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Select-String.
FalsePositives: None.
#>
  $out=& certutil -recoveryagent 2>&1
  $has=($out | Select-String -Pattern 'Recovery Agent' -SimpleMatch)
  if($has){ Write-Warning "[pass] EFS Data Recovery Agents are configured"} else { Write-Warning "[notice] No EFS Data Recovery Agents configured.`n*IF* EFS (NTFS file encryption) is used, there's no domain recovery agent to decrypt data if the user's key is lost." }
}


function HealthTest-GpWmiFilterNamespacesOnLocalHost{
<#
.SYNOPSIS
Checks Gp Wmi Filters Namespaces

.DESCRIPTION
AppliesTo: DomainJoined
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: New-Object.
FalsePositives: None.
#>
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


