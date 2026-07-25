# HostRequirement: All

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

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-NetworkConnectionProfiles
}
