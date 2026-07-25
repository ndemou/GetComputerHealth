# HostRequirement: DomainJoined

if (-not (Get-Command -Name 'Get-DomainControllers' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helper-regarding-domain-controllers.ps1')
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

function HealthTest-ConnectivityToDCs {
<#
Description: Checks DNS resolution and TCP connectivity to discovered domain controllers.
AppliesTo: DomainJoined
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Network)
Tags: Essential
Uses: Get-DomainControllers, Resolve-DnsName, Test-NetConnectionFast.
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

    # Required AD SRV labels are checked by HealthTest-RequiredSrvRecords.
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-ConnectivityToDCs
}
