<#
Standalone file for HealthTest-DnsSuffixBaseline.
Generated during the repo-wide health-test split.
#>
# HostRequirement: DomainJoined

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
        Write-Warning "[FAILURE] Primary DNS suffix: Current='$primarySuffix' Expected='$DomainName'. Ensure primary DNS suffix equals the AD DNS name (normally set by domain join)."
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
        $comment = "Get-DnsClient exception:`n$($err.Exception.Message)"
        Write-Warning "[WARNING] Unable to test if DNS registration is OK (RegisterThisConnectionsAddress=True and UseSuffixWhenRegistering=True)`n$comment"
        $allNics = @()
    }
    try {
        $nics = $allNics |
                Where-Object { $_.InterfaceOperationalStatus -eq "Up" -and $_.ConnectionSpecificSuffix -ne "localdomain" }
    } catch {
        $err = $_
        $comment = "Unable to filter DNS client interfaces based on InterfaceOperationalStatus & ConnectionSpecificSuffix`n$($err.Exception.Message)"
        Write-Warning "[WARNING] Unable to test if DNS registration is OK (RegisterThisConnectionsAddress=True and UseSuffixWhenRegistering=True)`n$comment"
        $nics = @()
    }

    foreach ($n in $nics) {
        $nicName = $n.InterfaceAlias

        # 3a) Registration flags must both be True
        if ($n.RegisterThisConnectionsAddress -and $n.UseSuffixWhenRegistering) {
            $details = "RegisterThisConnectionsAddress=True, UseSuffixWhenRegistering=True"
            Write-Warning ("[PASS] NIC '$nicName' DNS registration" + "`n" + $details)
        } else {
            $details = "RegisterThisConnectionsAddress=$($n.RegisterThisConnectionsAddress), UseSuffixWhenRegistering=$($n.UseSuffixWhenRegistering)`nEnable both flags on important interfaces."
            Write-Warning ("[FAILURE] NIC '$nicName' DNS registration" + "`n" + $details)
        }

        # 3b) Connection-specific suffix: must be Empty OR exactly the domain
        $css = $n.ConnectionSpecificSuffix
        if ([string]::IsNullOrWhiteSpace($css)) {
            $details = "Empty"
            Write-Warning ("[PASS] NIC '$nicName' Conn.-specific suffix" + "`n" + $details)
        } elseif ($css -ieq $DomainName) {
            $details = "Equals $DomainName"
            Write-Warning ("[PASS] NIC '$nicName' Conn.-specific suffix" + "`n" + $details)
        } else {
            $details = "Set to '$css'`nLeave blank for single-domain setups unless a specific suffix is required."
            Write-Warning ("[FAILURE] NIC '$nicName' Conn.-specific suffix" + "`n" + $details)
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-DnsSuffixBaseline
}
