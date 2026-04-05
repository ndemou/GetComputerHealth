<#
DNS & DHCP Services
#>

function HealthTest-DnsScavenging{
<#
Description: Checks whether DNS scavenging and zone aging are enabled and configured sensibly.
AppliesTo: Server
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Get-DnsServerScavenging, Get-DnsServerZone, Get-DnsServerZoneAging.
#>
  $sv = Get-DnsServerScavenging -ErrorAction Stop
  $zones = Get-DnsServerZone -ErrorAction Stop | Where-Object { $_.IsDsIntegrated -and $_.ZoneType -eq 'Primary' }
  $comment = "Severity: Medium.`nWhat it means: Server-level scavenging is off, so stale dynamic records never age out.`nRisk: Stale A/PTR clutter, service discovery problems, and opportunities for name re-use confusion. In secure-updates AD zones, outright hijack is harder, but operational pain is real."

  $flagged=$false
  if(-not $sv.ScavengingState){ $flagged=$true; Write-Warning "[WARNING] $("DNS server scavenging is disabled")`n$($comment)" }

  foreach($z in $zones){
    $ai = $null; try { $ai = Get-DnsServerZoneAging -Name $z.ZoneName -ErrorAction Stop } catch {}
    if(-not ($ai -and $ai.AgingEnabled)){ $flagged=$true; Write-Warning "[WARNING] DNS zone aging is disabled`nzone: $($z.ZoneName) `nNote that scavenging must be enabled both at the server level and at the zone`n$comment"}
  }

  if(-not $flagged){
    $on=@($zones | ForEach-Object { $_.ZoneName })
    Write-Warning "[PASS] $("DNS scavenging configured on server and zones")`n$(("Zones: " + ($on -join ', ')))"
  }
}


function HealthTest-DnsZoneReplicationScope{
<#
Description: Checks whether AD-integrated DNS zones use the expected replication scope.
AppliesTo: Server
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network), Medium(Time)
Uses: Get-DnsServerZone.
#>
  $zones = Get-DnsServerZone -ErrorAction Stop | Where-Object { $_.IsDsIntegrated }
  if(-not $zones){ Write-Warning "[PASS] No AD-integrated zones present"; return }
  $lines = ($zones | ForEach-Object { "{0}:{1}" -f $_.ZoneName, $_.ReplicationScope })
  Write-Warning ("[PASS] DNS zone replication scope reviewed`n" + ($lines -join '; '))
}


function HealthTest-DnsZoneTransfers{
<#
Description: Checks whether DNS zone transfers are disabled or restricted as expected.
AppliesTo: Server
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Network)
Uses: Get-DnsServerZone.
#>
  $zones=Get-DnsServerZone | Where-Object { -not $_.IsAutoCreated }
  $bad=$false
  foreach($z in $zones){
    if($z.SecureSecondaries -eq 'Any'){ $bad=$true; Write-Warning "[FAILURE] DNS zone transfer open to Any: $($z.ZoneName)" }
  }
  if(-not $bad){ Write-Warning "[PASS] DNS zone transfers are restricted (not 'Any')" }
}


function HealthTest-ReverseZonesPresent{
<#
Description: Checks whether required reverse lookup zones exist.
AppliesTo: Server
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: Get-DnsServerZone.
#>
  [CmdletBinding()] param([string[]]$ExpectedReverseZones)
  $zones=Get-DnsServerZone | Where-Object {$_.IsReverseLookupZone} | Select-Object -ExpandProperty ZoneName
  if(-not $ExpectedReverseZones){ Write-Warning "[PASS] $(("Reverse zones present: "+(($zones -join ', ')-replace '^$','<none>')))"; return }
  $missing=@()
  foreach($z in $ExpectedReverseZones){
    if($zones -notcontains $z){ $missing+=$z; Write-Warning "[FAILURE] Reverse zone missing: $z" }
  }
  if($missing.Count -eq 0){ Write-Warning "[PASS] All expected reverse zones are present" }
}


function HealthTest-DcDnsServerForwarder {
<#
Description: Checks whether a domain controller DNS server has appropriate forwarders configured.
AppliesTo: Server
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Network)
Uses: Get-DnsServerForwarder.
#>
  [CmdletBinding()]
  [OutputType([bool])]
  param()

  $forwarders = Get-DnsServerForwarder
  # ($forwarders | Format-List * -Force | Out-String).Trim()|write-host -f green
  if(-not $forwarders){
    Write-Warning "[PASS] No DNS forwarders configured"; # return $true
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
    Write-Warning "[NOTICE] The DNS service on this DC, will forward queries for non-local zones to specific DNS servers`nThis means that these DNS servers (view them with Get-DnsServerForwarder) can inspect and log the domains your domain contact. For extra privacy, you may wish to configure the DNS service to rely on root hints instead of DNS forwarders."
    return
  } else {
    Write-Warning "[PASS] All DNS forwarders are private/internal: $($ipAddresses -join ', ')"
  }
}


function HealthTest-DnsForwarders{
<#
Description: Checks whether DNS forwarders are configured and reachable.
AppliesTo: Server
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Network)
Uses: Get-DnsServerForwarder, Test-Connection.
#>
  $f=Get-DnsServerForwarder -ErrorAction Stop
  if(-not $f -or -not $f.IPAddress){ Write-Warning "[PASS] No DNS forwarders configured"; return }
  $ips=$f.IPAddress
  $bad=$false
  foreach($ip in $ips){
    if(($ip -eq '127.0.0.1') -or ($ip -eq '::1')){ $bad=$true; Write-Warning "[FAILURE] $("Loopback address is configured as a DNS forwarder")`n$($ip)"; continue }
    $ok=(Test-Connection -ComputerName $ip -Count 1 -Quiet)
    if(-not $ok){ $bad=$true; Write-Warning "[FAILURE] $("DNS forwarder not reachable")`n$($ip)" }
  }
  if(-not $bad){ Write-Warning "[PASS] $("DNS forwarders sane & reachable")`n$(("Forwarders: " + ($ips -join ', ')))" }
}


function HealthTest-DnsRecursionConfig {
<#
Description: Checks whether DNS recursion settings follow the expected baseline.
AppliesTo: Server
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Get-Command, Get-DnsServerRecursion, Get-DnsServerCache.
#>
    if (-not (Get-Command Get-DnsServerRecursion -ErrorAction SilentlyContinue)) {
        Write-Warning "[NOTICE] DNS Server tools not available`nDNS role/RSAT missing?"
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
        Write-Warning (("[PASS] No issues found in the DNS recursion configuration`nEnableRecursion={0}; MaxTTL={1}; EDNS-ECS={2}" `
                    -f $recText, $ttlText, $ecsText))
    } else {
        Write-Warning "[NOTICE] Unable to read DNS recursion configuration on this host`nHost is probably not a DNS server"
    }
}

function HealthTest-DcDnsARecords{
<#
Description: Checks whether domain controller hostnames resolve to expected A records.
AppliesTo: Server
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Get-ADDomainController, Resolve-DnsName.
#>
  $bad=@()
  foreach($dc in (Get-ADDomainController -Filter *)){
    $hn=$dc.HostName; $ip=$dc.IPv4Address
    if(-not $hn -or -not $ip){ continue }
    $ares=(Resolve-DnsName -Name $hn -Type A -ErrorAction SilentlyContinue).IPAddress
    if(-not $ares){ $msg="$hn has no A records in DNS"; $bad+=$msg; Write-Warning "[FAILURE] $($msg)"; continue }
    if($ares -notcontains $ip){ $msg="$hn A record mismatch: AD IP=$ip, DNS IPs="+($ares -join ','); $bad+=$msg; Write-Warning "[FAILURE] $($msg)" }
  }
  if($bad.Count -eq 0){ Write-Warning "[PASS] DC DNS A records match AD IPs for all DCs" }
}

function HealthTest-DcDnsRegistration {
<#
Description: Checks whether this domain controller has registered its expected DNS records.
AppliesTo: Server
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Resolve-DnsName.
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
            Write-Warning ("[NOTICE] " + $synopsis + $details)
            continue
        }

        if (-not $result) {
            $issueFound = $true
            $synopsis = "DNS record $($check.Name) for this domain controller is missing"
            $details = "`nQuery: $($check.QueryName)`nType: $($check.Type)`nExpected target: $dcFqdn"
            Write-Warning ("[NOTICE] " + $synopsis + $details)
            continue
        }

        $synopsis = "DNS record $($check.Name) for this domain controller exists"
        $details = "`nQuery: $($check.QueryName)`nType: $($check.Type)`nValue: $(& $check.Detail $result)"
        Write-Warning ("[debug] " + $synopsis + $details)
    }

    if (-not $issueFound) {
        $synopsis = "All tested DNS records for this domain controller exist"
        $details = "`nDomain controller: $dcFqdn"
        Write-Warning ("[PASS] " + $synopsis + $details)
    }
}
