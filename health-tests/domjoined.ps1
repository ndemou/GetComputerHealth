<#
Tests only for domain joined servers (including DC/PDC)
#>

function HealthTest-DnsSuffixBaseline {
<#
Description: Checks whether DNS suffix search settings match the expected domain baseline.
AppliesTo: DomainJoined
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network), Medium(Time)
Tags: Essential
Uses: Get-DnsClientGlobalSetting, Get-DnsClient.

Checks the DNS client suffix baseline for a domain-joined computer. It collects the
computer's AD domain name, the primary DNS suffix from IP global properties, global
DNS client devolution settings, and per-interface DNS client settings for active
interfaces. It detects an empty or mismatched primary DNS suffix, disabled DNS
devolution, inability to query DNS client settings, NICs that do not register their
address or suffix in DNS, and connection-specific suffixes that unexpectedly differ
from the AD DNS name.
#>
    $DomainName=(Get-CimInstance Win32_ComputerSystem).Domain

    # 1) Primary DNS suffix equals the AD DNS name
    $ipg = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    $primarySuffix = $ipg.DomainName

    if ([string]::IsNullOrWhiteSpace($primarySuffix)) {
        Write-Warning "[FAILURE] Primary DNS suffix: Current is empty`nEnsure the system has a primary DNS suffix (normally set by domain join)."
    } elseif ($primarySuffix -ieq $DomainName) {
        Write-Warning "[PASS] Primary DNS suffix`n$primarySuffix"
    } else {
        Write-Warning "[FAILURE] Primary DNS suffix"("Current='{0}' Expected='{1}'" -f $primarySuffix,$DomainName) "Ensure primary DNS suffix equals the AD DNS name (normally set by domain join)."
    }

    # 2) DNS devolution is enabled (boolean only)
    try {
        $g = Get-DnsClientGlobalSetting -ErrorAction Stop
        if ($g.UseDevolution -eq $true) {
            Write-Warning "[PASS] DNS devolution enabled`nUseDevolution=True"
        } else {
            Write-Warning "[FAILURE] DNS devolution enabled`nUseDevolution=False`nEnable devolution (GPO: Computer Configuration/Administrative Templates/Network/DNS Client/Turn off DNS devolution = Disabled)."
        }
    } catch {
        $err = $_
        $comment = ("Unable to query global DNS client settings: {0}" -f $err.Exception.Message) + "`nCheck OS support for Get-DnsClientGlobalSetting and that the DNS Client service is running."
        Write-Warning "[FAILURE] DNS devolution enabled`n$comment"
    }

    # 3) Per-NIC checks (only PASS/FAIL; no discovery warning if none found)
    $nics = @()
    try {
        $allNics = Get-DnsClient -ErrorAction Stop
    } catch {
        $err = $_
        $comment = "$($err.Exception.Message)"
        Write-Warning "[WARNING] Unable to test if DNS registration is OK (RegisterThisConnectionsAddress=True and UseSuffixWhenRegistering=True)`nGet-DnsClient exception:`n$comment"
        $allNics = @()
    }
    try {
        $nics = $allNics |
                Where-Object { $_.InterfaceOperationalStatus -eq "Up" -and $_.ConnectionSpecificSuffix -ne "localdomain" }
    } catch {
        $err = $_
        $comment = "$($err.Exception.Message)"
        Write-Warning "[WARNING] Unable to test if DNS registration is OK (RegisterThisConnectionsAddress=True and UseSuffixWhenRegistering=True)`nUnable to filter DNS client interfaces based on InterfaceOperationalStatus & ConnectionSpecificSuffix`n$comment"
        $nics = @()
    }

    foreach ($n in $nics) {
        $nicName = $n.InterfaceAlias

        # 3a) Registration flags must both be True
        if ($n.RegisterThisConnectionsAddress -and $n.UseSuffixWhenRegistering) {
            Write-Warning ("[PASS] NIC '{0}' DNS registration`nRegisterThisConnectionsAddress=True, UseSuffixWhenRegistering=True" -f $nicName)
        } else {
            Write-Warning ("[FAILURE] NIC '{0}' DNS registration`nRegisterThisConnectionsAddress={1}, UseSuffixWhenRegistering={2}`nEnable both flags on important interfaces." -f $nicName, $n.RegisterThisConnectionsAddress, $n.UseSuffixWhenRegistering)
        }

        # 3b) Connection-specific suffix: must be Empty OR exactly the domain
        $css = $n.ConnectionSpecificSuffix
        if ([string]::IsNullOrWhiteSpace($css)) {
            Write-Warning ("[PASS] NIC '{0}' Conn.-specific suffix`nEmpty" -f $nicName)
        } elseif ($css -ieq $DomainName) {
            Write-Warning ("[PASS] NIC '{0}' Conn.-specific suffix`nEquals {1}" -f $nicName,$DomainName)
        } else {
            Write-Warning ("[FAILURE] NIC '{0}' Conn.-specific suffix`nSet to '{1}'`nLeave blank for single-domain setups unless a specific suffix is required." -f $nicName, $css)
        }
    }
}

function HealthTest-ConnectivityToDCs {
<#
Description: Checks DNS resolution and TCP connectivity to discovered domain controllers.
AppliesTo: DomainJoined
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Network)
Tags: Essential
Uses: Resolve-DnsName, Test-NetConnectionFast.
#>
  $dcs  = Get-DomainControllers

  foreach ($s in $dcs) {
    $fqdn = $s.ToLower()
    # 1) DNS resolution
    try {
      [System.Net.Dns]::GetHostAddresses($fqdn) | Out-Null
      Write-Warning "[PASS] DNS resolved for $fqdn"
    } catch {
      Write-Warning "[FAILURE] DNS resolution failed for $fqdn`nCheck forward/reverse lookup zones and _msdcs records. Command: nslookup $fqdn"
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
        Write-Warning "[PASS] $($p.Name) port open on $fqdn"
      } else {
        Write-Warning "[FAILURE] TCP port $($p.Port)($($p.Name)) unreachable on $fqdn`nPort $($p.Port)/$($p.Proto) blocked or service down. Check firewall and service status."
      }
    }

    # 3) SRV records check for LDAP
    $domainName=(Get-CimInstance Win32_ComputerSystem).Domain
    try {
      $srv = Resolve-DnsName -Type SRV "_ldap._tcp.dc._msdcs.$domainName" -ErrorAction Stop
      if ($srv.Name -contains $fqdn) {
        Write-Warning "[PASS] SRV record present for $fqdn"
      } else {
        Write-Warning "[FAILURE] Missing SRV record for $fqdn`nDC not registered in _ldap._tcp.dc._msdcs. Run ipconfig /registerdns on $fqdn."
      }
    } catch {
      Write-Warning "[FAILURE] Could not query SRV records.`nCheck DNS service and replication for zone _msdcs.$((Get-ADForest).RootDomain)."
    }
  }
}

function HealthTest-RequiredSrvRecords{
<#
Description: Checks whether required AD DNS SRV records resolve successfully.
AppliesTo: DomainJoined
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Tags: Essential
Uses: Resolve-DnsName.
#>
  $dom=(Get-CimInstance Win32_ComputerSystem).Domain
  $labels=@("_ldap._tcp.dc._msdcs.$dom","_kerberos._tcp.$dom","_kerberos._udp.$dom")
  $missing=$false
  foreach($q in $labels){
    try{ $r=Resolve-DnsName -Type SRV $q -ErrorAction Stop }catch{$r=$null}
    if(-not $r){ $missing=$true; Write-Warning "[FAILURE] Required SRV record missing: $q" }
  }
  if(-not $missing){ Write-Warning "[PASS] Required AD SRV records present" }
}


function HealthTest-EfsRecoveryAgents{
<#
Description: Checks whether EFS recovery agents are configured.
AppliesTo: DomainJoined
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Tags: Essential
Uses: None.
#>
  $out=& certutil -recoveryagent 2>&1
  $has=($out | Select-String -Pattern 'Recovery Agent' -SimpleMatch)
  if($has){ Write-Warning "[PASS] EFS Data Recovery Agents are configured"} else { Write-Warning "[NOTICE] No EFS Data Recovery Agents configured.`n*IF* EFS (NTFS file encryption) is used, there's no domain recovery agent to decrypt data if the user's key is lost." }
}


function HealthTest-GpWmiFilterNamespacesOnLocalHost{
<#
Description: Checks whether Group Policy WMI filter namespaces are accessible on the local host.
AppliesTo: DomainJoined
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Tags: Essential
Uses: None.
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
    Write-Warning "[WARNING] This machine cannot read LDAP RootDSE. Is it domain-joined and can it reach a DC?"; return
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
        Write-Warning "[PASS] No GPO WMI filters defined (CN=WMIPolicy container not found)."; return
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
      Write-Warning "[WARNING] Cannot enumerate WMI filters via GPMC or LDAP. Check: domain join, DC reachability/DNS, and GPMC installation."; return
    }
  }

  if(-not $items){ Write-Warning "[PASS] No GPO WMI filters defined"; return }

  $unique = $items | Sort-Object Filter,Namespace -Unique
  foreach($i in $unique){
    try{
      $null=Get-CimInstance -Namespace $i.Namespace -ClassName __NAMESPACE -ErrorAction Stop
    } catch {
      $bad=$true
      Write-Warning "[FAILURE] WMI namespace missing for filter '$($i.Filter)': $($i.Namespace)"
    }
  }  

  if(-not $bad){ Write-Warning "[PASS] All WMI namespaces referenced by GPO WMI filters exist on this host"}
  else{ Write-Warning "[WARNING] One or more GPO WMI filter namespaces are missing on this host"}
}
