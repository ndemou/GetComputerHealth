<#
Tests only for domain joined computers except DC/PDC
#>

function HealthTest-InterfaceDnsServersUseDcs {
<#
Description: Checks whether member-server network interfaces use domain controllers as DNS servers.
AppliesTo: DomainJoined
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Tags: Essential
Uses: None.

Checks the DNS suffix configuration for domain-joined member computers. It collects
the computer's domain role and AD domain name from Win32_ComputerSystem, skips hosts
where the test is not applicable, and inspects ipconfig /all output for DNS suffix
entries that end with the joined domain. It detects member servers whose DNS suffix
data does not include the AD domain, which can break domain name resolution and AD
service discovery.
#>
  $cs = Get-CimInstance Win32_ComputerSystem
  $role = $cs.DomainRole
  if ($role -in 0,2) { Write-Warning "[NOTICE] This test (HealthTest-InterfaceDnsServersUseDcs) is not applicable to non-domain joined hosts"; return }
  if ($role -in 4,5) { Write-Warning "[NOTICE] This test (HealthTest-InterfaceDnsServersUseDcs) is not applicable to Domain Controllers"; return }
  $dcIps = @($Global:GchData.IpsOfAllDcs)

  $nets = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=TRUE"
  if (-not $nets) {
    Write-Warning "[FAILURE] No IP-enabled network adapters found."; return
  }

  $anyClean = $false
  $anyBad   = $false

  foreach ($net in $nets) {
    $dns  = $net.DNSServerSearchOrder
    $desc = $net.Description
    if (-not $dns -or $dns.Count -eq 0) {
      Write-Warning "[NOTICE] Interface has no DNS servers configured.`n$desc"
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
      Write-Warning "[PASS] Interface has only DCs as DNS servers.`nInterface: $desc; DNS=$dnsList"
    } elseif ($allNonDomain) {
      # Ignoring this interface that only has non-domain DNS servers
    } else {
      $anyBad = $true
      Write-Warning "[FAILURE] Interface DNS servers include non-DC addresses.`nInterface: $desc; DNS=$dnsList; DC IPs=$($dcIps -join ', ')"
    }
  }

  if (-not $anyClean) {
    Write-Warning "[FAILURE] No interface found where all DNS servers are DC IPs."} elseif (-not $anyBad) {
    Write-Warning "[PASS] All interfaces with DNS configured use only DC IPs."}
}

function HealthTest-GpupdatePolicyApply {
<#
Description: Checks whether the machine secure channel is healthy enough for Group Policy processing.
AppliesTo: DomainJoined
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: Test-ComputerSecureChannel, gpupdate.exe.
#>
  [CmdletBinding()] param()

  $dcIps = @($Global:GchData.IpsOfAllDcs)

  if (!(Test-ComputerSecureChannel)) {
      Write-Warning "[WARNING] Can't connected to any Domain Controller. Can not run gpupdate.`nMake sure you are on the domain LAN or connected via VPN."
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
    Write-Warning "[PASS] Computer and user policy updates completed successfully (gpupdate)."; return
  }

  if ($compOk) {
    Write-Warning "[PASS] Computer policy update completed successfully (gpupdate)."
  } else {
    Write-Warning "[FAILURE] Computer policy update did not report success.`ngpupdate output:`n$text"
  }

  if (-not $userOk) {
    if ($isSystem) {
      Write-Warning "[NOTICE] User policy update did not report success (gpupdate running under SYSTEM/non-interactive).`nThis can be expected when no interactive user is logged on.`nRaw gpupdate output:`n$text"
    } else {
      Write-Warning "[FAILURE] User policy update did not report success.`nExpected success for interactive user.`nRaw gpupdate output:`n$text"
    }
  } else {
    Write-Warning "[PASS] User policy update completed successfully (gpupdate)."
  }
}
