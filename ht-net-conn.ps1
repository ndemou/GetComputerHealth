<#
Network & Connectivity
#>

function HealthTest-DomainARecordPointsToDcIp {
  $cs = Get-CimInstance Win32_ComputerSystem
  $role = $cs.DomainRole
  $fn = $MyInvocation.MyCommand.Name
  if ($role -in 0,2) { Log-Notice "This test ($fn) is not applicable to non-domain joined hosts"; return }
  if ($role -in 4,5) { Log-Notice "This test ($fn) is not applicable to Domain Controllers"; return }

  Log-debug "Reading C:\it\config\ips-of-all-DCs.conf to get the list of the IPs of all DCs"
  # will return a list of IPs or throw
  $dcIps = Get-AllDCIPs -Path 'C:\it\config\ips-of-all-DCs.conf'

  $domain = $cs.Domain
  $ares = $null
  try { $ares = Resolve-DnsName -Name $domain -Type A -ErrorAction Stop } catch {}
  if (-not $ares) {
    Log-failure "No A records found for domain DNS name." -Comment $domain
    return
  }

  $aIps = @($ares | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
  $intersection = @()
  foreach ($ip in $aIps) { if ($dcIps -contains $ip) { $intersection += $ip } }

  $comment = "Domain=$domain; DC IPs=" + ($dcIps -join ', ') + "; Domain A IPs=" + ($aIps -join ', ')
  if ($intersection.Count -gt 0) {
    Log-pass "Domain DNS name resolves to at least one DC IP." -Comment $comment
  } else {
    Log-failure "Domain DNS name does not resolve to any known DC IPv4 address." -Comment $comment
  }
}


function HealthTest-InterfaceDnsServersUseDcs {

  $cs = Get-CimInstance Win32_ComputerSystem
  $role = $cs.DomainRole
  $fn = $MyInvocation.MyCommand.Name
  if ($role -in 0,2) { Log-Notice "This test ($fn) is not applicable to non-domain joined hosts"; return }
  if ($role -in 4,5) { Log-Notice "This test ($fn) is not applicable to Domain Controllers"; return }

  Log-debug "Reading C:\it\config\ips-of-all-DCs.conf to get the list of the IPs of all DCs"
  # will return a list of IPs or throw
  $dcIps = Get-AllDCIPs -Path 'C:\it\config\ips-of-all-DCs.conf'

  $nets = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=TRUE"
  if (-not $nets) {
    Log-failure "No IP-enabled network adapters found."
    return
  }

  $anyClean = $false
  $anyBad   = $false

  foreach ($net in $nets) {
    $dns  = $net.DNSServerSearchOrder
    $desc = $net.Description
    if (-not $dns -or $dns.Count -eq 0) {
      Log-Notice "Interface has no DNS servers configured." -Comment $desc
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
      Log-pass "Interface has only DCs as DNS servers." -Comment ("Interface: " + $desc + "; DNS=" + $dnsList)
    } elseif ($allNonDomain) {
      # Ignoring this interface that only has non-domain DNS servers
    } else {
      $anyBad = $true
      Log-failure "Interface DNS servers include non-DC addresses." -Comment ("Interface: " + $desc + "; DNS=" + $dnsList + "; DC IPs=" + ($dcIps -join ', '))
    }
  }

  if (-not $anyClean) {
    Log-failure "No interface found where all DNS servers are DC IPs."
  } elseif (-not $anyBad) {
    Log-pass "All interfaces with DNS configured use only DC IPs."
  }
}


function HealthTest-ConnectivityToDCs {

  $dcs  = Get-DomainControllers

  foreach ($s in $dcs) {
    $fqdn = $s.ToLower()
    # 1) DNS resolution
    try {
      [System.Net.Dns]::GetHostAddresses($fqdn) | Out-Null
      Log-pass "DNS resolved for $fqdn"
    } catch {
      Log-failure "DNS resolution failed for $fqdn" -comment "Check forward/reverse lookup zones and _msdcs records. Command: nslookup $fqdn"
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
        Log-pass "$($p.Name) port open on $fqdn"
      } else {
        Log-failure "TCP port $($p.Port)($($p.Name)) unreachable on $fqdn" -comment "Port $($p.Port)/$($p.Proto) blocked or service down. Check firewall and service status."
      }
    }

    # 3) SRV records check for LDAP
    $domainName=(Get-CimInstance Win32_ComputerSystem).Domain
    try {
      $srv = Resolve-DnsName -Type SRV "_ldap._tcp.dc._msdcs.$domainName" -ErrorAction Stop
      if ($srv.Name -contains $fqdn) {
        Log-pass "SRV record present for $fqdn"
      } else {
        Log-failure "Missing SRV record for $fqdn" -comment "DC not registered in _ldap._tcp.dc._msdcs. Run ipconfig /registerdns on $fqdn."
      }
    } catch {
      Log-failure "Could not query SRV records." -comment "Check DNS service and replication for zone _msdcs.$((Get-ADForest).RootDomain)."
    }
  }
}


function HealthTest-SysvolNetlogonAccessible{
    $dcs = Get-DomainControllers
    $bad = @()
    foreach($dc in $dcs){
      $ok1 = Test-Path "\\$dc\SYSVOL"
      if (!$ok1) {Log-failure "'\\$dc\SYSVOL' not reachable"}
      $ok2 = Test-Path "\\$dc\NETLOGON"
      if (!$ok2) {Log-failure "'\\$dc\NETLOGON' not reachable"}
      if(-not($ok1 -and $ok2)){ $bad += $dc.HostName }
    }
    $pass = ($bad.Count -eq 0)
    if($pass){Log-pass "All DCs have reachable SYSVOL & NETLOGON"}
}


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
        Log-pass "Default gateways: at most one per IP family"
    } else {
        if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 2) { # server -- always considered a failure
            Log-failure "Multiple default gateways detected per IP family" -Comment "IPv4=$v4; IPv6=$v6; Gateways=$(($nextHops) -join ', ')"
        } else { # workstation
            Test-MultipleGatewayConfiguration
        }
    }
  } else {
    if($nextHops.Count -le 1){
      Log-pass "Default gateways: at most one overall"
    } else {
        if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 2) { # server -- always considered a failure
            Log-failure "Multiple default gateways configured" -Comment "Gateways=$(($nextHops) -join ', ')"
        } else { # workstation
            Test-MultipleGatewayConfiguration
        }
    }
  }
}


function HealthTest-UnusedEnabledAdapters{
  $nics=Get-NetAdapter | Where-Object {$_.AdminStatus -eq 'Up' -and $_.Status -ne 'Up'}
  foreach($n in $nics){ Log-Warning "Enabled network adapter is disconnected: $($n.Name) ($($n.Status))" }
  if(($nics | Measure-Object).Count -eq 0){ Log-pass "No enabled-but-disconnected network adapters detected" } else { Log-failure "There are enabled-but-disconnected network adapters present" }
}


function HealthTest-NetworkInterfaceMetrics{
  [CmdletBinding()] param([int]$MaxPreferredMetric=25)
  $ifs=Get-NetIPInterface -AddressFamily IPv4 | Where-Object {$_.ConnectionState -eq 'Connected'}
  $bad=$false
  foreach($i in $ifs){
    if($i.InterfaceMetric -gt $MaxPreferredMetric -and !($i.InterfaceAlias -like "Loopback*")){ $bad=$true; Log-Warning "Interface metric too high: $($i.InterfaceAlias) Metric=$($i.InterfaceMetric) (Max=$MaxPreferredMetric)" }
  }
  if(-not $bad){ Log-pass "All connected interfaces have acceptable metrics (<= $MaxPreferredMetric)" } else { Log-failure "One or more interfaces have metrics above the preferred threshold" }
}


function HealthTest-IPv6Binding{
  [CmdletBinding()] param([switch]$RequireEnabled)
  $rows = Get-NetAdapterBinding -ComponentID ms_tcpip6 | Select-Object Name,Enabled
  if(-not $rows){ Log-failure "No adapters returned for IPv6 binding (ms_tcpip6)"; return }
  $bad=$false
  if($RequireEnabled){
    foreach($r in $rows){
      if(-not $r.Enabled){ $bad=$true; Log-failure "IPv6 disabled on adapter" -Comment $r.Name }
    }
    if(-not $bad){ Log-pass "IPv6 enabled on all adapters" }
  } else {
    Log-pass "IPv6 binding state reported" -Comment (($rows | ForEach-Object { "$($_.Name)=$($_.Enabled)" }) -join '; ')
  }
}


function HealthTest-Nic {
    $nics = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
    if (-not $nics) {
        Log-debug "No physical NICs with Status=Up; skipping NIC health check"
        return
    }

    $pass = $true
    $minPackets = 100000

    foreach ($n in $nics) {
        $stat = Get-NetAdapterStatistics -Name $n.Name -ErrorAction SilentlyContinue
        if (-not $stat) {
            Log-debug "Network interface skipped due to missing stats ($($n.Name))"
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
            Log-Warning "Disconnected network interface ($($n.Name))" -Comment ""
            $pass = $false
            continue
        }

        if ($totalPackets -lt $minPackets) {
            Log-debug "Network interface skipped due to low traffic ($($n.Name))"
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
            Log-Warning "Network interface with plenty of errors ($($n.Name))" -Comment "errors=$pctStr ($errors/$totalPackets total packets)"
            $pass = $false
        } elseif ($errors -ge 100 -and $errorPct -ge 0.002) {
            $noticeList += "$($n.Name): errors=$pctStr ($errors/$totalPackets total)"
            Log-Notice "Network interface with some errors ($($n.Name))" -Comment "errors=$pctStr ($errors/$totalPackets total packets)"
            $pass = $false
        } else {
            # below 0.002%: considered OK, no log entry
            continue
        }
    }

    if ($pass) {
        Log-pass "Network interfaces healthy; no significant error rates or disconnected interfaces detected"
    }
}


function HealthTest-NltestSiteDiscovery {
  [CmdletBinding()] param()
  $cs = Get-CimInstance Win32_ComputerSystem
  $role = $cs.DomainRole
  $fn = $MyInvocation.MyCommand.Name
  if ($role -in 0,2) { Log-Notice "This test ($fn) is not applicable to non-domain joined hosts"; return }
  if ($role -in 4,5) { Log-Notice "This test ($fn) is not applicable to Domain Controllers"; return }

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
    Log-pass "NLTEST /dsgetsite succeeded." -Comment ("Site: " + $site)
  } else {
    $hex = '0x{0:X}' -f ($exit -band 0xFFFFFFFF)
    Log-failure "NLTEST /dsgetsite failed." -Comment ("ExitCode=" + $hex + "; Output=`n" + $txt)
  }
}


function Get-AllDCIPs {
<#
.SYNOPSIS
  Loads and validates the list of Domain Controller IPv4 addresses from a JSON config file.

.DESCRIPTION
  Expected file format:
    {"ips":["192.168.0.1","192.168.0.2"]}

.OUTPUTS
  [string[]]  List of validated IPv4 addresses
#>

  [CmdletBinding()]
  param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Path
  )

  function Test-IPv4 {
    param([Parameter(Mandatory)][string]$IP)

    $null -ne (
      $IP -as [ipaddress]
    ) -and (
      ([ipaddress]$IP).AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
    )
  }

  try { $null = Get-Item -LiteralPath $Path -ErrorAction Stop }
  catch {
    $e = New-Object System.Management.Automation.ErrorRecord(
      $_.Exception, "DcIpConfigNotAccessible", [System.Management.Automation.ErrorCategory]::OpenError, $Path
    )
    $e.ErrorDetails = New-Object System.Management.Automation.ErrorDetails(
      "DC IP config file not accessible: $Path. $($_.Exception.Message)"
    )
    throw $e
  }

  $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop

  if ([string]::IsNullOrWhiteSpace($text)) {
    throw "DC IP config file is empty: $Path --  File should contain the IPs of all DCs in json format. Example:`n{`"ips`":[`"192.168.0.1`",`"192.168.0.2`"]}"
  }

  try { 
    $json = ConvertFrom-Json -InputObject $text -ErrorAction Stop 
  } catch {
    $msg = "Invalid JSON in $Path. Expected format:`n{`"ips`":[`"192.168.0.1`",`"192.168.0.2`"]}"
    throw (New-Object System.Exception($msg, $_.Exception))
  }

  if (-not ($json.PSObject.Properties.Name -contains 'ips')) {
    throw "Config missing required property 'ips'. Expected format:`n{`"ips`":[`"192.168.0.1`",`"192.168.0.2`"]}"
  }

  $ips = @($json.ips | Where-Object { $_ -and $_.ToString().Trim() })

  if ($ips.Count -eq 0) {
    throw "No DC IPs discovered in $Path. Expected format:`n{`"ips`":[`"192.168.0.1`",`"192.168.0.2`"]}"
  }

  $valid = New-Object System.Collections.Generic.List[string]
  $invalid = New-Object System.Collections.Generic.List[string]
  
  foreach ($ip in $ips) {
    $ipStr = $ip.ToString().Trim()
    if ((Test-IPv4 $ipStr) -and (-not $valid.Contains($ipStr))) { $null = $valid.Add($ipStr) }
    else { $null = $invalid.Add($ipStr) }
  }
  
  $valid = $valid.ToArray()
  $invalid = $invalid.ToArray()

  if ($invalid.Count -gt 0) {
    throw "Invalid IPv4 address(es) in $($Path): $($invalid -join ', '). Expected format:`n{`"ips`":[`"192.168.0.1`",`"192.168.0.2`"]}"
  }

  if (-not $valid -or $valid.Count -eq 0) {
      throw "No DC IPs discovered. $Path should contain the IPs of all DCs in json format. Example:`n{`"ips`":[`"192.168.0.1`",`"192.168.0.2`"]}"
  }

  return $valid
}


function Get-DomainControllers {
  $Domain = (Get-CimInstance Win32_ComputerSystem).Domain

  if (-not $Domain) { throw "No domain detected." }
  $results = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)

  try {
    if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
      $srv = Resolve-DnsName -Type SRV ("_ldap._tcp.dc._msdcs.{0}" -f $Domain) -ErrorAction Stop
      foreach ($r in $srv) {
        if ($r.NameTarget) { [void]$results.Add(($r.NameTarget.TrimEnd('.'))) }
      }
    }
  } catch {}
  return $results
}


function Test-NetConnectionFast {
  [CmdletBinding()]
  param(
    [Parameter(ValueFromPipelineByPropertyName=$true)]
    [Alias('TargetName')]
    [string]$ComputerName = 'localhost',

    [Parameter(ParameterSetName='ByPort')]
    [int]$Port,

    [Parameter(ParameterSetName='ByCommon')]
    [ValidateSet('HTTP','RDP','SMB','WINRM')]
    [string]$CommonTCPPort,

    [ValidateSet('Detailed','Quiet')]
    [string]$InformationLevel = 'Detailed',

    [switch]$TryPingingHost
  )

  begin {
    $COMMON_MAP = @{
      HTTP = 80; RDP = 3389; SMB = 445; WINRM = 5985
    }
    $TIMEOUT_MS = 100
  }

  process {
    $remoteAddr = $null
    try {
      $ips = [System.Net.Dns]::GetHostAddresses($ComputerName)
      if ($ips) {
        $ipv4 = @($ips | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork })
        if ($ipv4 -and $ipv4.Count -gt 0) { $remoteAddr = $ipv4[0].ToString() }
        else { $remoteAddr = $ips[0].ToString() }
      }
    } catch {}

    $resolvedPort = $null
    if ($PSCmdlet.ParameterSetName -eq 'ByCommon') { $resolvedPort = $COMMON_MAP[$CommonTCPPort] }
    elseif ($PSCmdlet.ParameterSetName -eq 'ByPort') { $resolvedPort = $Port }

    if ($TryPingingHost) {
        $pingOk = $false
        try { $pingOk = Test-Connection -ComputerName $ComputerName -Count 1 -Quiet -ErrorAction SilentlyContinue } catch {}
    } else {
        $pingOk = $null
    }

    $tcpOk = $false
    if ($resolvedPort) {
      $client = New-Object System.Net.Sockets.TcpClient
      try {
        $ar = $client.BeginConnect($ComputerName, $resolvedPort, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($TIMEOUT_MS)) {
          try { $client.EndConnect($ar); $tcpOk = $true } catch {}
        }
      } finally {
        try { $client.Close() } catch {}
      }
    }

    if ($InformationLevel -eq 'Quiet') { return $tcpOk }

    [pscustomobject]@{
      ComputerName      = $ComputerName
      RemoteAddress     = $remoteAddr
      RemotePort        = $resolvedPort
      InterfaceAlias    = $null
      SourceAddress     = $null
      PingSucceeded     = $pingOk
      PingReplyDetails  = $null
      TcpTestSucceeded  = $tcpOk
    }
  }
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
    Log-Info "Gateway Configuration looks fine - Windows will prefer $($best.InterfaceAlias).$note"
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

    Log-Failure "Multiple Gateways with metrics that may cause routing instability." -comment "$desc`n$hintText"
  }
}
