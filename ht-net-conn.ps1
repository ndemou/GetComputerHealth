<#
Network & Connectivity
#>

function HealthTest-ConnectivityToDCs {

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


function HealthTest-NetworkConnectionProfiles {
  [CmdletBinding()]
  param()

  $hostFacts = $Global:GetComputerHealthDataQMTA

  $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
  if (-not $profiles) {
    Write-Warning "[warning] Could not read network connection profiles (Get-NetConnectionProfile failed)"
    return
  }

  $internetProfiles = @($profiles | Where-Object { $_.IPv4Connectivity -eq 'Internet' -or $_.IPv6Connectivity -eq 'Internet' })
  if ($internetProfiles.Count -gt 0) {
    Write-Warning "[pass] Connected to the Internet"
  } else {
    Write-Warning ("[failure] No Internet connection" + "`n" + "According to windows (Get-NetConnectionProfile)")
  }

  $isServer = [bool]$hostFacts.isHostServer
  if (-not $isServer) { return }

  $isDomainJoined = [bool]$hostFacts.isHostDomainJoined
  $isHostDC = [bool]$hostFacts.isHostDC
  $isHostPDC = [bool]$hostFacts.isHostPDC

  $allowedCategories = @('Private')
  if ($isDomainJoined -and -not $isHostDC -and -not $isHostPDC) {
    $allowedCategories = @('DomainAuthenticated')
  }

  $matchingServerProfiles = @($profiles | Where-Object { $allowedCategories -contains $_.NetworkCategory.ToString() })
  if ($matchingServerProfiles.Count -gt 0) {
    Write-Warning "[pass] Expected network category: $(($allowedCategories -join ', '))"
  } else {
    Write-Warning "[failure] No connection with an expected network category: $(($allowedCategories -join ', '))"
  }
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
        Write-Warning "[pass] Default gateways: at most one per IP family"
    } else {
        if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 2) { # server -- always considered a failure
            Write-Warning "[failure] Multiple default gateways detected per IP family`nIPv4=$v4; IPv6=$v6; Gateways=$(($nextHops) -join ', ')"
        } else { # workstation
            Test-MultipleGatewayConfiguration
        }
    }
  } else {
    if($nextHops.Count -le 1){
      Write-Warning "[pass] Default gateways: at most one overall"
    } else {
        if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 2) { # server -- always considered a failure
            Write-Warning "[failure] Multiple default gateways configured`nGateways=$(($nextHops) -join ', ')"
        } else { # workstation
            Test-MultipleGatewayConfiguration
        }
    }
  }
}

function HealthTest-NetworkInterfaceMetrics{
  [CmdletBinding()] param([int]$MaxPreferredMetric=25)
  $ifs=Get-NetIPInterface -AddressFamily IPv4 | Where-Object {$_.ConnectionState -eq 'Connected'}
  $bad=$false
  foreach($i in $ifs){
    if($i.InterfaceMetric -gt $MaxPreferredMetric -and !($i.InterfaceAlias -like "Loopback*")){ $bad=$true; Write-Warning "[warning] Interface metric too high: $($i.InterfaceAlias) Metric=$($i.InterfaceMetric) (Max=$MaxPreferredMetric)" }
  }
  if(-not $bad){ Write-Warning "[pass] All connected interfaces have acceptable metrics (<= $MaxPreferredMetric)" } else { Write-Warning "[failure] One or more interfaces have metrics above the preferred threshold" }
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
    Write-Warning "[info] Gateway Configuration looks fine - Windows will prefer $($best.InterfaceAlias).$note"
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

    Write-Warning "[failure] Multiple Gateways with metrics that may cause routing instability.`n$desc`n$hintText"
  }
}

function HealthTest-IPv6Binding{
  [CmdletBinding()] param([switch]$RequireEnabled)
  $rows = Get-NetAdapterBinding -ComponentID ms_tcpip6 | Select-Object Name,Enabled
  if(-not $rows){ Write-Warning "[failure] No adapters returned for IPv6 binding (ms_tcpip6)"; return }
  $bad=$false
  if($RequireEnabled){
    foreach($r in $rows){
      if(-not $r.Enabled){ $bad=$true; Write-Warning "[failure] $("IPv6 disabled on adapter")`n$($r.Name)" }
    }
    if(-not $bad){ Write-Warning "[pass] IPv6 enabled on all adapters" }
  } else {
    Write-Warning ("[pass] IPv6 binding state reported`n" + (($rows | ForEach-Object { "$($_.Name)=$($_.Enabled)" }) -join '; '))
  }
}

function HealthTest-Nic {
    $nics = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
    if (-not $nics) {
        Write-Output "No physical NICs with Status=Up; skipping NIC health check"
        return
    }

    $pass = $true
    $minPackets = 100000

    foreach ($n in $nics) {
        $stat = Get-NetAdapterStatistics -Name $n.Name -ErrorAction SilentlyContinue
        if (-not $stat) {
            Write-Output "Network interface skipped due to missing stats ($($n.Name))"
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
            Write-Warning "[warning] Disconnected network interface ($($n.Name))"
            $pass = $false
            continue
        }

        if ($totalPackets -lt $minPackets) {
            Write-Output "Network interface skipped due to low traffic ($($n.Name))"
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
            Write-Warning "[warning] Network interface with plenty of errors ($($n.Name))`nerrors=$pctStr ($errors/$totalPackets total packets)"
            $pass = $false
        } elseif ($errors -ge 100 -and $errorPct -ge 0.002) {
            $noticeList += "$($n.Name): errors=$pctStr ($errors/$totalPackets total)"
            Write-Warning "[notice] Network interface with some errors ($($n.Name))`nerrors=$pctStr ($errors/$totalPackets total packets)"
            $pass = $false
        } else {
            # below 0.002%: considered OK, no log entry
            continue
        }
    }

    if ($pass) {
        Write-Warning "[pass] Network interfaces healthy; no significant error rates or disconnected interfaces detected"}
}

function HealthTest-WinRMListening{
  $svc=Get-Service WinRM -ErrorAction Stop
  if($svc.Status -ne 'Running'){ Write-Warning "[failure] WinRM service is not running`nStatus=$($svc.Status)"; return }
  try{ $null=Test-WSMan -ErrorAction Stop; Write-Warning "[pass] WinRM running and responding"}
  catch{ Write-Warning "[failure] WinRM not responding`n$($_.Exception.Message)" }
}
