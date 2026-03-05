<#
DNS & DHCP Services
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


function HealthTest-DnsZoneReplicationScope{
  $zones = Get-DnsServerZone -ErrorAction Stop | Where-Object { $_.IsDsIntegrated }
  if(-not $zones){ Write-Warning "[pass] No AD-integrated zones present"; return }
  $lines = ($zones | ForEach-Object { "{0}:{1}" -f $_.ZoneName, $_.ReplicationScope })
  Write-Warning ("[pass] DNS zone replication scope reviewed`n" + ($lines -join '; '))
}


function HealthTest-DnsZoneTransfers{
  $zones=Get-DnsServerZone | Where-Object { -not $_.IsAutoCreated }
  $bad=$false
  foreach($z in $zones){
    if($z.SecureSecondaries -eq 'Any'){ $bad=$true; Write-Warning "[failure] DNS zone transfer open to Any: $($z.ZoneName)" }
  }
  if(-not $bad){ Write-Warning "[pass] DNS zone transfers are restricted (not 'Any')" }
}


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


function HealthTest-DcDnsServerForwarder {
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


function HealthTest-DnsSuffixBaseline {
    $DomainName=(Get-CimInstance Win32_ComputerSystem).Domain

    # 1) Primary DNS suffix equals the AD DNS name
    $ipg = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    $primarySuffix = $ipg.DomainName

    if ([string]::IsNullOrWhiteSpace($primarySuffix)) {
        Write-Warning "[failure] Primary DNS suffix" "Current is empty" "Ensure the system has a primary DNS suffix (normally set by domain join)."
    } elseif ($primarySuffix -ieq $DomainName) {
        Write-Warning "[pass] Primary DNS suffix" $primarySuffix
    } else {
        Write-Warning "[failure] Primary DNS suffix" ("Current='{0}' Expected='{1}'" -f $primarySuffix,$DomainName) "Ensure primary DNS suffix equals the AD DNS name (normally set by domain join)."
    }

    # 2) DNS devolution is enabled (boolean only)
    try {
        $g = Get-DnsClientGlobalSetting -ErrorAction Stop
        if ($g.UseDevolution -eq $true) {
            Write-Warning "[pass] DNS devolution enabled" "UseDevolution=True"
        } else {
            Write-Warning "[failure] DNS devolution enabled" "UseDevolution=False" "Enable devolution (GPO: Computer Configuration/Administrative Templates/Network/DNS Client/Turn off DNS devolution = Disabled)."
        }
    } catch {
        $err = $_
        Write-Warning "[failure] DNS devolution enabled" ("Unable to query global DNS client settings: {0}" -f $err.Exception.Message) "Check OS support for Get-DnsClientGlobalSetting and that the DNS Client service is running."
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


function HealthTest-DnsClientService{
  $s=Get-Service Dnscache -ErrorAction Stop
  if($s.Status -eq 'Running'){ Write-Warning "[pass] DNS Client service running" } else { Write-Warning "[failure] DNS Client service is not running`nStatus=$($s.Status)" }
}
