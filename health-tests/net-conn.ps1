<#
Network & Connectivity
#>

if (-not (Get-Command -Name 'Get-PropValue' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helpers-for-healthtests.ps1')
}
function Test-IpReachability {
<#
.SYNOPSIS
Checks whether one or more IP addresses reply to ICMP echo requests

.DESCRIPTION
Uses Test-Connection to probe IP targets and returns a result object per IP.
Accepts:
 - A single IP string
 - A single string containing multiple targets separated by commas and/or
   whitespace
 - Any enumerable of strings/objects (each item is converted to string)

Per target, retries are attempted up to -Retry times. The function does not
throw on ping failures; each result captures the last status.

.OUTPUTS
One PSCustomObject per IP with:
 - Ip
 - Responded  ([bool])
 - LastStatus ('Success' or error/timeout text)
 - RttMs      ([double] or $null)
#>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true,Position=0)]
    [Alias('IPs','Targets')]
    [object]$Ip,

    [ValidateRange(1,1000)]
    [int]$Retry=1,

    [ValidateRange(1,60000)]
    [int]$TimeoutMs=500
  )

  $ips = @()

  if ($Ip -is [string]) {
    $s = $Ip.Trim()
    if ($s -match '[,\s]') {
      $ips = @(
        $s -split '[,\s]+' |
          Where-Object { $_ -and $_.Trim() } |
          ForEach-Object { $_.Trim() }
      )
    } else {
      $ips = @($s)
    }
  } elseif ($Ip -is [System.Collections.IEnumerable]) {
    foreach ($x in $Ip) {
      if ($null -ne $x -and "$x".Trim()) {
        $ips += "$x".Trim()
      }
    }
  } else {
    $ips = @("$Ip".Trim())
  }

  $ips = @($ips | Where-Object { $_ } | Select-Object -Unique)

  foreach ($targetIp in $ips) {
    $responded = $false
    $lastStatus = $null
    $rttMs = $null

    for ($attempt = 1; $attempt -le $Retry; $attempt++) {
      try {
        $reply = Test-Connection -ComputerName $targetIp -Count 1 -BufferSize 16 -Delay 1 -TimeToLive 64 -ErrorAction Stop
        if ($reply) {
          $responded = $true
          $lastStatus = 'Success'
          $rttMs = [double]$reply.ResponseTime
          break
        }
      }
      catch {
        $lastStatus = $_.Exception.Message
      }
    }

    [pscustomobject]@{
      Ip        = $targetIp
      Responded = $responded
      LastStatus = $lastStatus
      RttMs     = $rttMs
    }
  }
}

function Split-IpByReachability {
<#
.SYNOPSIS
Splits input IPs into Alive vs NotAlive based on whether they respond to pings

.DESCRIPTION
Runs Test-IpReachability for the provided targets and returns a single object
containing two string arrays:
- AliveIps: IPs that responded ($true)
- DeadIps:  IPs that did not respond ($false) or hit errors/timeouts

.INPUTS
Same accepted shapes as Test-IpReachability -Ip.

.OUTPUTS
[pscustomobject] with:
- AliveIps ([string[]])
- DeadIps  ([string[]])
- Results  ([pscustomobject[]]) raw per-IP results (handy for lastStatus/rtt)
#>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true,Position=0)][Alias('Ips')][object]$Ip,
    [ValidateRange(1,1000)][int]$Retry=1,
    [ValidateRange(1,60000)][int]$TimeoutMs=500
  )

  $results = @(Test-IpReachability -Ip $Ip -Retry $Retry -TimeoutMs $TimeoutMs)

  $alive = @($results | Where-Object { $_.Responded } | Select-Object -ExpandProperty Ip)
  $dead  = @($results | Where-Object { -not $_.Responded } | Select-Object -ExpandProperty Ip)

  [pscustomobject]@{
    AliveIps = $alive
    DeadIps  = $dead
    Results  = $results
  }
}

# Intentionally duplicated from a helper ps1 script. 
# Not dot-sourcing it because it contains too much unneeded code.
function Test-NetConnectivityToNetwork {
<#
.SYNOPSIS
Assesses reachability of a network by pinging a list of hosts that are known to reply.

.DESCRIPTION
Given a human-friendly network description (e.g. "10.11.x.y/16") and a list of
IP addresses that are expected to respond to ICMP, this function probes them
(using Split-IpByReachability) and outputs the results using:
   Write-Warning "[<level>] ..."
(<level> is one of pass, notice, failure)

If -ReturnListOfAliveHosts is used, the function does not emit warnings and
instead returns the list of responsive hosts.
#>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true,Position=0)][string]$NetworkDescription,
    [Parameter(Mandatory=$true,Position=1)][object]$KnownHostIps,
    [ValidateRange(1,1000)][int]$Retry=1,
    [ValidateRange(1,60000)][int]$TimeoutMs=500,
    [switch]$ReturnListOfAliveHosts
  )

  $ips=@()
  if($KnownHostIps -is [string]){
    $s=$KnownHostIps.Trim()
    if($s -match '[,\s]'){ $ips=@($s -split '[,\s]+' | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() }) }
    else { $ips=@($s) }
  } elseif($KnownHostIps -is [System.Collections.IEnumerable]){
    foreach($x in $KnownHostIps){ if($null -ne $x -and "$x".Trim()){ $ips += "$x".Trim() } }
  } else { $ips=@("$KnownHostIps".Trim()) }
  $ips=@($ips | Where-Object { $_ } | Select-Object -Unique)

  $progress_msg="Pinging $($ips.Count) hosts"
  Write-Progress -Activity $progress_msg -Status "Please wait"
  $split = Split-IpByReachability -Ip $ips -Retry $Retry -TimeoutMs $TimeoutMs
  Write-Progress -Activity $progress_msg -Completed

  $alive=@($split.AliveIps)
  $dead=@($split.DeadIps)

  if($ReturnListOfAliveHosts){
    return $alive
  }
  
  if(-not $alive -or $alive.Count -eq 0){
    $message = "The $NetworkDescription network may be UNRECHABLE because none of the hosts replied to pings"
    $comment = "List of hosts that didn't reply: ($($ips -join ', ')); Maybe some VPN connection is down"
    Write-Warning "[failure] $message`n$comment" 
  } elseif($dead -and $dead.Count -gt 0){
    $message = "The $NetworkDescription network is reachable (at least one host replied to pings)"
    Write-Warning "[pass] $message"
    $message = "Note that some hosts of $NetworkDescription did not reply to pings (that's often normal)"
    $comment = "List of hosts that didn't reply: ($($dead -join ', '))`nIf some hosts are consistently failing, consider if you should update the list of hosts you ping"
    Write-Warning "[notice] $message`n$comment" 
  } else {
    $message = "The $NetworkDescription network is reachable; all known hosts replied to pings"
    $comment = "List of hosts that replied: ($($ips -join ', '))"
    Write-Warning "[pass] $message`n$comment" 
  }
}

function HealthTest-NetworkConnectionProfiles {
<#
Description: Checks network connection profiles and basic connectivity expectations for each active network.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Tags: Essential
Uses: Get-NetConnectionProfile, Test-NetConnectivityToNetwork.
#>
  [CmdletBinding()]
  param()

  $POPULAR_HOSTS = @('8.8.8.8','8.8.4.4','1.1.1.1','1.1.1.2')

  # Phase 1, Collect Data
  $profiles = @(Get-NetConnectionProfile) # We'll let an unexpected exception bubble up -- the caller catches and displays exceptions nicely
  $details = "`n" + "Get-NetConnectionProfile output:`n" + ($profiles|Format-List|Out-String).Trim()
  if (-not $profiles) {
    Write-Warning "[WARNING] Could not read network connection profiles$details"
    return
  }

  # Phase 2, Check Internet Connectivity
  $internetProfiles = @($profiles | Where-Object { $_.IPv4Connectivity -eq 'Internet' -or $_.IPv6Connectivity -eq 'Internet' })
  if ($internetProfiles.Count -gt 0) {
    Write-Warning "[PASS] Connected to the Internet"
  } else {
    $aliveHosts = Test-NetConnectivityToNetwork -NetworkDescription "Internet" -KnownHostIps $POPULAR_HOSTS -ReturnListOfAliveHosts
    if ($aliveHosts) {
      Write-Warning "[NOTICE] System seems connected to the Internet but windows report it is not$details`nBut these hosts reply to pings $aliveHosts"
    } else {
      Write-Warning "[FAILURE] No Internet connection$details`nAlso non of these hosts replied to pings: $POPULAR_HOSTS"
    }
  }

  # Phase 3, Check if NLA category(public, private, domain) is proper.
  $domainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole
  $isHostServer = ($domainRole -in 2, 3, 4, 5)
  $isHostInDomain = ($domainRole -in 1, 3, 4, 5)

  if (-not $isHostServer) { return } # N/A for workstations

  if ($isHostInDomain) {
    $allowedCategories = @('DomainAuthenticated')
  } else {
    $allowedCategories = @('Private')
  }

  $matchingServerProfiles = @($profiles | Where-Object { $allowedCategories -contains $_.NetworkCategory.ToString() })
  if ($matchingServerProfiles.Count -gt 0) {
    Write-Warning "[PASS] Found interface on expected NLA category"
  } else {
    $synopsis = "No connection with a proper NLA category: $(($allowedCategories -join ', '))"
    Write-Warning "[FAILURE] $synopsis$details"
  }
}

function HealthTest-SingleDefaultGateway{
<#
Description: Checks for multiple default gateways and validates that the active gateway configuration is sensible.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Time), Medium(Network)
Uses: Get-NetIPConfiguration, Test-MultipleGatewayConfiguration.
#>
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
        Write-Warning "[PASS] Default gateways: at most one per IP family"
    } else {
        if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 2) { # server -- always considered a failure
            Write-Warning "[FAILURE] Multiple default gateways detected per IP family`nIPv4=$v4; IPv6=$v6; Gateways=$(($nextHops) -join ', ')"
        } else { # workstation
            Test-MultipleGatewayConfiguration
        }
    }
  } else {
    if($nextHops.Count -le 1){
      Write-Warning "[PASS] Default gateways: at most one overall"
    } else {
        if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 2) { # server -- always considered a failure
            Write-Warning "[FAILURE] Multiple default gateways configured`nGateways=$(($nextHops) -join ', ')"
        } else { # workstation
            Test-MultipleGatewayConfiguration
        }
    }
  }
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

  if (-not $routes -or @($routes).Count -lt 2) {
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

    Write-Warning "[FAILURE] Multiple Gateways with metrics that may cause routing instability.`n$desc`n$hintText"
  }
}

function HealthTest-IPv6Binding{
<#
Description: Checks whether IPv6 is bound on network adapters as expected.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Tags: Essential
Uses: Get-NetAdapterBinding.
#>
  [CmdletBinding()] param([switch]$RequireEnabled)

  $rows = Get-NetAdapterBinding -ComponentID ms_tcpip6 | Select-Object Name,Enabled
  if(-not $rows){ Write-Warning "[FAILURE] No adapters returned for IPv6 binding (ms_tcpip6)"; return }
  $bad=$false
  if($RequireEnabled){
    foreach($r in $rows){
      if(-not $r.Enabled){ $bad=$true; Write-Warning "[FAILURE] IPv6 disabled on adapter`n$($r.Name)" }
    }
    if(-not $bad){ Write-Warning "[PASS] IPv6 enabled on all adapters" }
  } else {
    Write-Warning ("[PASS] IPv6 binding state reported`n" + (($rows | ForEach-Object { "$($_.Name)=$($_.Enabled)" }) -join '; '))
  }
}

function HealthTest-Nic {
<#
Description: Checks network adapters for unhealthy status or suspicious error counters.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Tags: Essential
Uses: Get-NetAdapter, Get-NetAdapterStatistics.
#>
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
            (Get-PropValue $stat 'ReceivedDiscardedPackets' 0) +
            (Get-PropValue $stat 'ReceivedPacketErrors' 0) +
            (Get-PropValue $stat 'OutboundDiscardedPackets' 0) +
            (Get-PropValue $stat 'OutboundPacketErrors' 0)

        $totalPackets =
            (Get-PropValue $stat 'ReceivedUnicastPackets' 0) +
            (Get-PropValue $stat 'ReceivedBroadcastPackets' 0) +
            (Get-PropValue $stat 'ReceivedMulticastPackets' 0) +
            (Get-PropValue $stat 'OutboundUnicastPackets' 0) +
            (Get-PropValue $stat 'OutboundBroadcastPackets' 0) +
            (Get-PropValue $stat 'OutboundMulticastPackets' 0)

        if ($n.MediaConnectionState -ne 'Connected') {
            $warnList += "$($n.Name): mediaState=$($n.MediaConnectionState)"
            Write-Warning "[WARNING] Disconnected network interface ($($n.Name))"
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
            Write-Warning "[WARNING] Network interface with plenty of errors ($($n.Name))`nerrors=$pctStr ($errors/$totalPackets total packets)"
            $pass = $false
        } elseif ($errors -ge 100 -and $errorPct -ge 0.002) {
            $noticeList += "$($n.Name): errors=$pctStr ($errors/$totalPackets total)"
            Write-Warning "[NOTICE] Network interface with some errors ($($n.Name))`nerrors=$pctStr ($errors/$totalPackets total packets)"
            $pass = $false
        } else {
            # below 0.002%: considered OK, no log entry
            continue
        }
    }

    if ($pass) {
        Write-Warning "[PASS] Network interfaces healthy; no significant error rates or disconnected interfaces detected"}
}

function HealthTest-WinRMListening{
<#
Description: Checks whether the WinRM service is running and responds to WSMan requests.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Network)
Tags: Essential
Uses: Test-WSMan.
#>
  $svc=Get-Service WinRM -ErrorAction Stop
  if($svc.Status -ne 'Running'){ Write-Warning "[FAILURE] WinRM service is not running`nStatus=$($svc.Status)"; return }
  try{ $null=Test-WSMan -ErrorAction Stop; Write-Warning "[PASS] WinRM running and responding"}
  catch{ Write-Warning "[FAILURE] WinRM not responding`n$($_.Exception.Message)" }
}
