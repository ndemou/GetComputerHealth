<#
Tests only for domain joined servers except DC/PDC
#>

function HealthTest-DomainARecordPointsToDcIp {
<#
.SYNOPSIS
Checks Domain A Record Points To Dc Ip

.DESCRIPTION
AppliesTo: DomainJoined
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Resolve-DnsName.
FalsePositives: None.
#>
  $dcIps = @($Global:GCHDQMTA.IpsOfAllDcs)

  $domain = (Get-CimInstance Win32_ComputerSystem).Domain
  $ares = $null
  try { $ares = Resolve-DnsName -Name $domain -Type A -ErrorAction Stop } catch {}
  if (-not $ares) {
    Write-Warning "[failure] No A records found for domain DNS name.`n$domain"
    return
  }

  $aIps = @($ares | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
  $intersection = @()
  foreach ($ip in $aIps) { if ($dcIps -contains $ip) { $intersection += $ip } }

  $comment = "Domain=$domain; DC IPs=" + ($dcIps -join ', ') + "; Domain A IPs=" + ($aIps -join ', ')
  if ($intersection.Count -gt 0) {
    Write-Warning ("[pass] Domain DNS name resolves to at least one DC IP.`n$comment")
  } else {
    Write-Warning ("[failure] Domain DNS name does not resolve to any known DC IPv4 address.`n$comment")
  }
}

function HealthTest-NltestSiteDiscovery {
<#
.SYNOPSIS
Checks Nltest Site Discovery

.DESCRIPTION
AppliesTo: DomainJoined
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-CimInstance.
FalsePositives: None.
#>
  [CmdletBinding()] param()
  $dcIps = @($Global:GCHDQMTA.IpsOfAllDcs)

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
    Write-Warning "[pass] NLTEST /dsgetsite succeeded.`nSite: $site"
  } else {
    $hex = '0x{0:X}' -f ($exit -band 0xFFFFFFFF)
    Write-Warning "[failure] NLTEST /dsgetsite failed.`nExitCode=$hex; Output=`n$txt"
  }
}

function HealthTest-GpupdatePolicyApply {
<#
.SYNOPSIS
Checks Gpupdate Policy Apply

.DESCRIPTION
AppliesTo: DomainJoined
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Test-ComputerSecureChannel.
FalsePositives: None.
#>
  [CmdletBinding()] param()
if ($Global:GCHDQMTA.DebugSkipSlowTests) {Write-Warning "[info] Skipping slow test $($MyInvocation.MyCommand.Name) because of -DebugSkipSlowTests switch"; return}
  $dcIps = @($Global:GCHDQMTA.IpsOfAllDcs)

  if (!(Test-ComputerSecureChannel)) {
      Write-Warning "[warning] Can't connected to any Domain Controller. Can not run gpupdate.`nMake sure you are on the domain LAN or connected via VPN."
    return
  }

  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $isSystem = $false
  try {
    if ($id -and $id.User -and $id.User.Value -eq 'S-1-5-18') { $isSystem = $true }
  } catch {}

  $out  = gpupdate 2>&1
  $text = ($out | sls -notmatch '^ *$' | Out-String)

  $compOk = ($text -like "*Computer Policy update has completed successfully*")
  $userOk = ($text -like "*User Policy update has completed successfully*")

  if ($compOk -and $userOk) {
    Write-Warning "[pass] Computer and user policy updates completed successfully (gpupdate)."; return
  }

  if ($compOk) {
    Write-Warning "[pass] Computer policy update completed successfully (gpupdate)."
  } else {
    Write-Warning ("[failure] Computer policy update did not report success.`ngpupdate output:`n" + $text)
  }

  if (-not $userOk) {
    if ($isSystem) {
      Write-Warning ("[notice] User policy update did not report success (gpupdate running under SYSTEM/non-interactive).`nThis can be expected when no interactive user is logged on.`nRaw gpupdate output:`n" + $text)
    } else {
      Write-Warning ("[failure] User policy update did not report success.`nExpected success for interactive user.`nRaw gpupdate output:`n" + $text)
    }
  } else {
    Write-Warning "[pass] User policy update completed successfully (gpupdate)."
  }
}
