<#
Standalone file for HealthTest-ADViewConsistency.
Generated during the repo-wide health-test split.
#>
# HostRequirement: DC

function HealthTest-ADViewConsistency {
<#
Description: Verifies that domain controllers agree on the DC list and FSMO role holders.
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Get-ADDomainController, Get-ADDomain, Get-ADForest.
#>
  [CmdletBinding()]
  param(
    [string[]]$Servers  # optional: explicit DC/DNS names; otherwise discover
  )

  function Normalize-Names {
	# Gets an array of strings and returns only the non-empty ones lowercased
    param([string[]]$Names)
    if (-not $Names) { return @() }
    $out = @()
    foreach ($n in $Names) { if ($n) { $out += $n.ToLower() } }
    @($out | Sort-Object -Unique)
  }

  $ok = $true

  if (-not $Servers -or $Servers.Count -eq 0) {
    try { $Servers = @(Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName) }
    catch {
      Write-Warning "[FAILURE] Unable to discover domain controllers.`nTry on a domain-joined host with AD PowerShell and DNS working. Command used: Get-ADDomainController -Filter *"
    return
    }
  }

  $Servers = Normalize-Names $Servers
  if ($Servers.Count -eq 0) {
    Write-Warning "[FAILURE] No domain controllers to query.`nPass -Servers @('dc01.contoso.com','dc02.contoso.com') or run on a domain-joined host with AD tools."
    return
  }

  $views = @()
  foreach ($s in $Servers) {
    try {
      $dcList = Get-ADDomainController -Filter * -Server $s | Select-Object -ExpandProperty HostName
      $dom = Get-ADDomain -Server $s
      $for = Get-ADForest -Server $s
      $views += [pscustomobject]@{
        Server = $s
        DCs    = Normalize-Names $dcList
        PDC    = ($dom.PDCEmulator            | ForEach-Object { $_.ToLower() })
        RID    = ($dom.RIDMaster              | ForEach-Object { $_.ToLower() })
        Infra  = ($dom.InfrastructureMaster   | ForEach-Object { $_.ToLower() })
        Schema = ($for.SchemaMaster           | ForEach-Object { $_.ToLower() })
        DNM    = ($for.DomainNamingMaster     | ForEach-Object { $_.ToLower() })
      }
    } catch {
      $details = "The server didn't answer AD queries (-Server $s). Check network/DNS, ADWS service and firewall. Try: Test-NetConnection $s -Port 389; Get-Service ADWS -ComputerName $s; repadmin /showrepl $s"
      Write-Warning ("[FAILURE] Cannot query DC '$s'." + "`n" + $details)
      $ok = $false
    }
  }

  if ($views.Count -eq 0) { return }

  $baseline = ($views | Sort-Object Server)[0]
  $domainName = $null
  try { $domainName = (Get-ADDomain -Server $baseline.Server).DNSRoot } catch { $domainName=(Get-CimInstance Win32_ComputerSystem).Domain }

  $baseDCsJoined = ($baseline.DCs -join ', ')
  foreach ($v in $views) {
    # 1) DC list equality (order-insensitive, case-insensitive)
    $dcJoin = ($v.DCs -join ', ')
    if ($dcJoin -ne $baseDCsJoined) {
      $details = "Baseline '$($baseline.Server)' sees DCs: [$baseDCsJoined] ; '$($v.Server)' sees: [$dcJoin]. Likely replication or DNS SRV inconsistency. Run: repadmin /replsummary ; check _msdcs.${domainName} SRV records under _ldap._tcp.dc._msdcs and AD-integrated DNS."
      Write-Warning ("[FAILURE] DC list mismatch on '$($v.Server)'." + "`n" + $details)
      $ok = $false
    }

    # 2) FSMO holders equality
    if ($v.PDC -ne $baseline.PDC) {
      $details = "Baseline: $($baseline.PDC) ; $($v.Server) thinks: $($v.PDC). If a role transfer occurred, verify replication. Check: (Get-ADDomain -Server $($v.Server)).PDCEmulator; run repadmin /showrepl $($v.Server) and GPMC target DC."
      Write-Warning ("[FAILURE] PDC emulator disagreement on '$($v.Server)'." + "`n" + $details)
      $ok = $false
    }
    if ($v.RID -ne $baseline.RID) {
      $details = "Baseline: $($baseline.RID) ; $($v.Server) thinks: $($v.RID). If long-standing, DCs may fail to create new SIDs when pools deplete. Check: (Get-ADDomain -Server $($v.Server)).RIDMaster; repadmin /showrepl $($v.Server)."
      Write-Warning ("[FAILURE] RID Master disagreement on '$($v.Server)'." + "`n" + $details)
      $ok = $false
    }
    if ($v.Infra -ne $baseline.Infra) {
      $details = "Baseline: $($baseline.Infra) ; $($v.Server) thinks: $($v.Infra). In multi-domain forests this can cause stale cross-domain group memberships. Check: (Get-ADDomain -Server $($v.Server)).InfrastructureMaster; repadmin /showrepl $($v.Server)."
      Write-Warning ("[FAILURE] Infrastructure Master disagreement on '$($v.Server)'." + "`n" + $details)
      $ok = $false
    }
    if ($v.Schema -ne $baseline.Schema) {
      $details = "Baseline: $($baseline.Schema) ; $($v.Server) thinks: $($v.Schema). Schema updates should be halted until replication converges. Check: (Get-ADForest -Server $($v.Server)).SchemaMaster; repadmin /showrepl $($v.Server)."
      Write-Warning ("[FAILURE] Schema Master disagreement on '$($v.Server)'." + "`n" + $details)
      $ok = $false
    }
    if ($v.DNM -ne $baseline.DNM) {
      $details = "Baseline: $($baseline.DNM) ; $($v.Server) thinks: $($v.DNM). Avoid adding/removing domains until resolved. Check: (Get-ADForest -Server $($v.Server)).DomainNamingMaster; repadmin /showrepl $($v.Server)."
      Write-Warning ("[FAILURE] Domain Naming Master disagreement on '$($v.Server)'." + "`n" + $details)
      $ok = $false
    }
  }

  if ($ok) {
    $details = "Baseline DC: $($baseline.Server) ; DCs: [$baseDCsJoined]. Cross-check is order- and case-insensitive."
    Write-Warning ("[PASS] All DCs agree on DC list and FSMO role holders." + "`n" + $details)
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-ADViewConsistency
}
