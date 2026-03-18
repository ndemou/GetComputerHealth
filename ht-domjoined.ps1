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
AppliesTo: All
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
