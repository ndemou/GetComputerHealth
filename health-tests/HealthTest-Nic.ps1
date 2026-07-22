<#
Standalone file for HealthTest-Nic.
Generated during the repo-wide health-test split.
#>
# HostRequirement: All

if (-not (Get-Command -Name 'Get-PropValue' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helpers-for-healthtests.ps1')
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
            Write-Warning "[WARNING] Network interface with plenty of errors ($($n.Name))`nerrors=$pctStr ($errors/$totalPackets total packets)"
            $pass = $false
        } elseif ($errors -ge 100 -and $errorPct -ge 0.002) {
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

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-Nic
}
