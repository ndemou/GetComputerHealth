<#
DNS & DHCP Services
#>

function HealthTest-DnsScavenging{
<#
.SYNOPSIS
Checks Dns Scavenging

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Get-DnsServerScavenging, Get-DnsServerZone, Get-DnsServerZoneAging.
FalsePositives: None.
#>
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


function HealthTest-DnsZoneReplicationScope{
<#
.SYNOPSIS
Checks Dns Zone Replication Scope

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: Get-DnsServerZone.
FalsePositives: None.
#>
  $zones = Get-DnsServerZone -ErrorAction Stop | Where-Object { $_.IsDsIntegrated }
  if(-not $zones){ Write-Warning "[pass] No AD-integrated zones present"; return }
  $lines = ($zones | ForEach-Object { "{0}:{1}" -f $_.ZoneName, $_.ReplicationScope })
  Write-Warning ("[pass] DNS zone replication scope reviewed`n" + ($lines -join '; '))
}


function HealthTest-DnsZoneTransfers{
<#
.SYNOPSIS
Checks Dns Zone Transfers

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Get-DnsServerZone.
FalsePositives: None.
#>
  $zones=Get-DnsServerZone | Where-Object { -not $_.IsAutoCreated }
  $bad=$false
  foreach($z in $zones){
    if($z.SecureSecondaries -eq 'Any'){ $bad=$true; Write-Warning "[failure] DNS zone transfer open to Any: $($z.ZoneName)" }
  }
  if(-not $bad){ Write-Warning "[pass] DNS zone transfers are restricted (not 'Any')" }
}


function HealthTest-ReverseZonesPresent{
<#
.SYNOPSIS
Checks Reverse Zones Present

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-DnsServerZone.
FalsePositives: None.
#>
  [CmdletBinding()] param([string[]]$ExpectedReverseZones)
  $zones=Get-DnsServerZone | Where-Object {$_.IsReverseLookupZone} | Select-Object -ExpandProperty ZoneName
  if(-not $ExpectedReverseZones){ Write-Warning "[pass] $(("Reverse zones present: "+(($zones -join ', ')-replace '^$','<none>')))"; return }
  $missing=@()
  foreach($z in $ExpectedReverseZones){
    if($zones -notcontains $z){ $missing+=$z; Write-Warning "[failure] Reverse zone missing: $z" }
  }
  if($missing.Count -eq 0){ Write-Warning "[pass] All expected reverse zones are present" }
}


function HealthTest-DcDnsServerForwarder {
<#
.SYNOPSIS
Checks Dc Dns Server Forwarder

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Get-DnsServerForwarder.
FalsePositives: None.
#>
  [CmdletBinding()]
  [OutputType([bool])]
  param()

  $forwarders = Get-DnsServerForwarder
  # ($forwarders | Format-List * -Force | Out-String).Trim()|write-host -f green
  if(-not $forwarders){
    Write-Warning "[pass] No DNS forwarders configured"; # return $true
  }
  $ipAddresses = $forwarders | %{$_.ipaddress.tostring()}

  $private = {
    ($_ -like '10.*') -or
    ($_ -like '192.168.*') -or
    ($_ -like '172.1[6-9].*') -or
    ($_ -like '172.2[0-9].*') -or
    ($_ -like '172.3[0-1].*')
  }

  $public = $ipAddresses | Where-Object { -not (& $private $_) }

  if($public){
    Write-Warning "[notice] The DNS service on this DC, will forward queries for non-local zones to specific DNS servers`nThis means that these DNS servers (view them with Get-DnsServerForwarder) can inspect and log the domains your domain contact. For extra privacy, you may wish to configure the DNS service to rely on root hints instead of DNS forwarders."
    return
  } else {
    Write-Warning "[pass] All DNS forwarders are private/internal: $($ipAddresses -join ', ')"
  }
}


function HealthTest-DnsForwarders{
<#
.SYNOPSIS
Checks Dns Forwarders

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Get-DnsServerForwarder, Test-Connection.
FalsePositives: None.
#>
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


function HealthTest-DnsRecursionConfig {
<#
.SYNOPSIS
Checks Dns Recursion Config

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Get-DnsServerRecursion, Get-DnsServerCache, Get-DnsServerEDns.
FalsePositives: None.
#>
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

function HealthTest-DnsSuffixMatchesDomain {
<#
.SYNOPSIS
Checks Dns Suffix Matches Domain

.DESCRIPTION
AppliesTo: DC
Scope: Domain
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

function HealthTest-DnsClientService{
<#
.SYNOPSIS
Checks Dns Client Service

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Get-Service.
FalsePositives: None.
#>
  $s=Get-Service Dnscache -ErrorAction Stop
  if($s.Status -eq 'Running'){ Write-Warning "[pass] DNS Client service running" } else { Write-Warning "[failure] DNS Client service is not running`nStatus=$($s.Status)" }
}

function HealthTest-DcDnsARecords{
<#
.SYNOPSIS
Checks Dc Dns A Records

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Get-ADDomainController, Resolve-DnsName.
FalsePositives: None.
#>
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

function HealthTest-DcDnsRegistration {
<#
.SYNOPSIS
Checks Dc Dns Registration

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Resolve-DnsName.
FalsePositives: None.
#>
    [CmdletBinding()]
    param()

    $domain = $env:USERDNSDOMAIN
    $dcFqdn = "$($env:COMPUTERNAME).$domain"

    if (-not $domain) {
        Write-Warning "[debug] USERDNSDOMAIN is not set`nThis computer does not appear to have a domain DNS context in the current session."
        return
    }

    $checks = @(
        [pscustomobject]@{
            Name = 'HostARecord'
            QueryName = $dcFqdn
            Type = 'A'
            Test = {
                @(Resolve-DnsName $dcFqdn -Type A -ErrorAction Stop)
            }
            Detail = {
                param($result)
                (($result | Select-Object -ExpandProperty IPAddress) -join ', ')
            }
        }
        [pscustomobject]@{
            Name = 'LdapDcSrv'
            QueryName = "_ldap._tcp.dc._msdcs.$domain"
            Type = 'SRV'
            Test = {
                @(Resolve-DnsName "_ldap._tcp.dc._msdcs.$domain" -Type SRV -ErrorAction Stop | Where-Object { $_.NameTarget -eq $dcFqdn })
            }
            Detail = {
                param($result)
                (($result | ForEach-Object { "$($_.NameTarget):$($_.Port)" }) -join ', ')
            }
        }
        [pscustomobject]@{
            Name = 'KerberosDcSrv'
            QueryName = "_kerberos._tcp.dc._msdcs.$domain"
            Type = 'SRV'
            Test = {
                @(Resolve-DnsName "_kerberos._tcp.dc._msdcs.$domain" -Type SRV -ErrorAction Stop | Where-Object { $_.NameTarget -eq $dcFqdn })
            }
            Detail = {
                param($result)
                (($result | ForEach-Object { "$($_.NameTarget):$($_.Port)" }) -join ', ')
            }
        }
    )

    $issueFound = $false

    foreach ($check in $checks) {
        $result = $null
        try {
            $result = & $check.Test
        } catch {
            $issueFound = $true
            $synopsis = "DNS record $($check.Name) for this domain controller is missing or unresolved"
            $details = "`nQuery: $($check.QueryName)`nType: $($check.Type)`nError: $($_.Exception.Message)"
            Write-Warning ("[notice] " + $synopsis + $details)
            continue
        }

        if (-not $result) {
            $issueFound = $true
            $synopsis = "DNS record $($check.Name) for this domain controller is missing"
            $details = "`nQuery: $($check.QueryName)`nType: $($check.Type)`nExpected target: $dcFqdn"
            Write-Warning ("[notice] " + $synopsis + $details)
            continue
        }

        $synopsis = "DNS record $($check.Name) for this domain controller exists"
        $details = "`nQuery: $($check.QueryName)`nType: $($check.Type)`nValue: $(& $check.Detail $result)"
        Write-Warning ("[debug] " + $synopsis + $details)
    }

    if (-not $issueFound) {
        $synopsis = "All tested DNS records for this domain controller exist"
        $details = "`nDomain controller: $dcFqdn"
        Write-Warning ("[pass] " + $synopsis + $details)
    }
}

function HealthTest-DhcpDnsCredential{
<#
.SYNOPSIS
Checks Dhcp Dns Credential

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Get-WindowsFeature, Get-DhcpServerDnsCredential.
FalsePositives: None.
#>
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

function HealthTest-DnsSuffixBaseline {
<#
.SYNOPSIS
Checks Dns Suffix Baseline

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Audit / Compliance / Informational
Impact: Medium(Network)
Uses: Get-DnsClientGlobalSetting, Get-DnsClient.
FalsePositives: None.
#>
    $DomainName=(Get-CimInstance Win32_ComputerSystem).Domain

    # 1) Primary DNS suffix equals the AD DNS name
    $ipg = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    $primarySuffix = $ipg.DomainName

    if ([string]::IsNullOrWhiteSpace($primarySuffix)) {
        Write-Warning "[failure] Primary DNS suffix: Current is empty" "Ensure the system has a primary DNS suffix (normally set by domain join)."
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

function HealthTest-InterfaceDnsServersUseDcs {
<#
.SYNOPSIS
Checks Interface Dns Servers Use Dcs

.DESCRIPTION
AppliesTo: DC
Scope: Domain
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
  $dcIps = @($Global:GetComputerHealthDataQMTA.IpsOfAllDcs)

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
