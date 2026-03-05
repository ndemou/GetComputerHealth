<#
Active Directory & GPO Management
#>

function HealthTest-ADReplicationLocalRSAT {
  $domainRole = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).DomainRole
  $isHostDC = ($domainRole -in 4,5)

  if (-not $isHostDC) { return }

  $adModuleOk = $true
  try {
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) { $adModuleOk = $false }
  } catch {
    $adModuleOk = $false
  }

  if (-not $adModuleOk) {
    Write-Warning "[failure] AD replication (RSAT): ActiveDirectory module not available; cannot query replication partner metadata."
    return
  }

  try {
    Import-Module ActiveDirectory -ErrorAction Stop
  } catch {
    Write-Warning "[failure] $("AD replication (RSAT): failed to import ActiveDirectory module.")`n$($_.Exception.Message)"
    return
  }

  $me = $null
  try {
    $me = Get-ADDomainController -ErrorAction Stop
  } catch {
    Write-Warning "[failure] $("AD replication (RSAT): failed to identify local domain controller.")`n$($_.Exception.Message)"
    return
  }

  if (-not $me -or -not $me.HostName) {
    Write-Warning "[failure] AD replication (RSAT): could not determine local DC hostname."
    return
  }

  try {
    [void](Get-ADDomain -ErrorAction Stop)
  } catch {
    Write-Warning "[failure] $("AD replication (RSAT): cannot query domain info (ADWS/permissions/connectivity issue).")`n$($_.Exception.Message)"
    return
  }

  $md = $null
  try {
    $md = Get-ADReplicationPartnerMetadata -Target $me.HostName -ErrorAction Stop
  } catch {
    Write-Warning "[failure] $("Exception from: Get-ADReplicationPartnerMetadata -Target $($me.HostName)")`n$($_.Exception.Message)"
    return
  }

  if (-not $md) {
    Write-Warning "[failure] AD replication (RSAT): no partner metadata returned for $($me.HostName)."
    return
  }

  $bad = @($md | Where-Object { $_.LastReplicationResult -ne 0 })
  if ($bad.Count -gt 0) {
    $details = $bad | ForEach-Object { "$($_.Partner) rc=$($_.LastReplicationResult) at $($_.LastSuccessfulSync)" }
    Write-Warning "[failure] $("AD replication (RSAT): replication partner errors for $($me.HostName).")`n$(($details -join " | "))"
    return
  }

  Write-Warning "[pass] AD replication (RSAT): replication partner results healthy for $($me.HostName)."
}


function HealthTest-ADReplicationDomainRepadmin {
  $domainRole = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).DomainRole
  $isHostDC = ($domainRole -in 4,5)

  if (-not $isHostDC) { return }

  $repadminCmd = Get-Command repadmin.exe -ErrorAction SilentlyContinue
  $repadmin = if ($repadminCmd -and $repadminCmd.Source) { $repadminCmd.Source } else { "$env:windir\system32\repadmin.exe" }

  if (-not (Test-Path -LiteralPath $repadmin)) {
    Write-Warning "[failure] AD replication (repadmin): repadmin.exe not found; cannot run domain-wide checks."
    return
  }

  $ok = $true

  # --- Test 1: repadmin /replsum -> ensure all 'fails' are 0
  try {
    $sumOut = (& $repadmin /replsum 2>&1 | Out-String)
  } catch {
    Write-Warning "[failure] $("AD replication (repadmin): failed to execute 'repadmin /replsum'.")`n$($_.Exception.Message)"
    return
  }

  if (-not $sumOut) {
    Write-Warning "[failure] AD replication (repadmin): no output from 'repadmin /replsum'."
    $ok = $false
  } else {
    $bad = @()
    foreach ($ln in ($sumOut -split '\r?\n')) {
      if ($ln -match '^\s*(?<DSA>\S+)\s+(?<Delta>(?:\d+d:)?(?:\d+h:)?\d+m:\d+s|\d+s)\s+(?<Fails>\d+)\s*/\s*(?<Total>\d+)\b') {
        $dsa = $Matches.DSA
        $fails = [int]$Matches.Fails
        $total = [int]$Matches.Total
        if ($fails -gt 0) { $bad += [pscustomobject]@{ DSA=$dsa; Fails=$fails; Total=$total } }
      }
    }

    if ($bad.Count -gt 0) {
      foreach ($b in $bad) {
        Write-Warning "[failure] $("AD replication (repadmin): replsum reports failures on '$($b.DSA)'")`n$(("{0} fail(s) out of {1} neighbors." -f $b.Fails,$b.Total))"
      }
      $ok = $false
    } else {
      Write-Warning "[pass] AD replication (repadmin): replsum shows 0 fails for all DSAs."
    }
  }

  # --- Test 2: repadmin /showreps -> all latest attempts 'was successful.'
  try {
    $showOut = (& $repadmin /showreps 2>&1 | Out-String)
  } catch {
    Write-Warning "[failure] $("AD replication (repadmin): failed to execute 'repadmin /showreps'.")`n$($_.Exception.Message)"
    return
  }

  if (-not $showOut) {
    Write-Warning "[failure] AD replication (repadmin): no output from 'repadmin /showreps'."
    $ok = $false
  } else {
    $attemptLines = ($showOut -split '\r?\n') | Where-Object { $_ -match 'Last attempt @' }
    if (-not $attemptLines -or $attemptLines.Count -eq 0) {
      Write-Warning "[warning] AD replication (repadmin): showreps produced no 'Last attempt' lines.`nRun 'repadmin /showreps' manually to inspect output."
      $ok = $false
    } else {
      $notOk = @($attemptLines | Where-Object { $_ -notmatch 'was successful\.$' })
      if ($notOk.Count -gt 0) {
        foreach ($ln in $notOk) {
          Write-Warning "[failure] $("AD replication (repadmin): showreps has unsuccessful last attempt")`n$(($ln.Trim()))"
        }
        $ok = $false
      } else {
        Write-Warning "[pass] AD replication (repadmin): showreps indicates all last attempts were successful."
      }
    }
  }

  if (-not $ok) {
    Write-Warning "[notice] AD replication (repadmin): issues detected."
  }
}


function HealthTest-ADViewConsistency {
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
    $out | Sort-Object -Unique
  }

  $ok = $true
  try { Import-Module ActiveDirectory -ErrorAction Stop } catch {
    Write-Warning "[failure] ActiveDirectory module not available.`nInstall RSAT AD PowerShell tools. On a DC it's built-in; on a Domain member use Add-WindowsFeature RSAT-AD-PowerShell (Server) or RSAT package (Client)."
    return
  }

  if (-not $Servers -or $Servers.Count -eq 0) {
    try { $Servers = Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName }
    catch {
      Write-Warning "[failure] Unable to discover domain controllers.`nTry on a domain-joined host with AD PowerShell and DNS working. Command used: Get-ADDomainController -Filter *"
    return
    }
  }

  $Servers = Normalize-Names $Servers
  if ($Servers.Count -eq 0) {
    Write-Warning "[failure] No domain controllers to query.`nPass -Servers @('dc01.contoso.com','dc02.contoso.com') or run on a domain-joined host with AD tools."
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
      Write-Warning (("[failure] Cannot query DC '{0}'.`n" -f $s) + ("The server didn't answer AD queries (-Server {0}). Check network/DNS, ADWS service and firewall. Try: Test-NetConnection {0} -Port 389; Get-Service ADWS -ComputerName {0}; repadmin /showrepl {0}" -f $s))
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
      Write-Warning (("[failure] DC list mismatch on '{0}'.`n" -f $v.Server) + ("Baseline '{0}' sees DCs: [{1}] ; '{2}' sees: [{3}]. Likely replication or DNS SRV inconsistency. Run: repadmin /replsummary ; check _msdcs.{4} SRV records under _ldap._tcp.dc._msdcs and AD-integrated DNS." -f $baseline.Server, $baseDCsJoined, $v.Server, $dcJoin, $domainName))
      $ok = $false
    }

    # 2) FSMO holders equality
    if ($v.PDC -ne $baseline.PDC) {
      Write-Warning (("[failure] PDC emulator disagreement on '{0}'.`n" -f $v.Server) + ("Baseline: {0} ; {1} thinks: {2}. If a role transfer occurred, verify replication. Check: (Get-ADDomain -Server {1}).PDCEmulator; run repadmin /showrepl {1} and GPMC target DC." -f $baseline.PDC, $v.Server, $v.PDC))
      $ok = $false
    }
    if ($v.RID -ne $baseline.RID) {
      Write-Warning (("[failure] RID Master disagreement on '{0}'.`n" -f $v.Server) + ("Baseline: {0} ; {1} thinks: {2}. If long-standing, DCs may fail to create new SIDs when pools deplete. Check: (Get-ADDomain -Server {1}).RIDMaster; repadmin /showrepl {1}." -f $baseline.RID, $v.Server, $v.RID))
      $ok = $false
    }
    if ($v.Infra -ne $baseline.Infra) {
      Write-Warning (("[failure] Infrastructure Master disagreement on '{0}'.`n" -f $v.Server) + ("Baseline: {0} ; {1} thinks: {2}. In multi-domain forests this can cause stale cross-domain group memberships. Check: (Get-ADDomain -Server {1}).InfrastructureMaster; repadmin /showrepl {1}." -f $baseline.Infra, $v.Server, $v.Infra))
      $ok = $false
    }
    if ($v.Schema -ne $baseline.Schema) {
      Write-Warning (("[failure] Schema Master disagreement on '{0}'.`n" -f $v.Server) + ("Baseline: {0} ; {1} thinks: {2}. Schema updates should be halted until replication converges. Check: (Get-ADForest -Server {1}).SchemaMaster; repadmin /showrepl {1}." -f $baseline.Schema, $v.Server, $v.Schema))
      $ok = $false
    }
    if ($v.DNM -ne $baseline.DNM) {
      Write-Warning (("[failure] Domain Naming Master disagreement on '{0}'.`n" -f $v.Server) + ("Baseline: {0} ; {1} thinks: {2}. Avoid adding/removing domains until resolved. Check: (Get-ADForest -Server {1}).DomainNamingMaster; repadmin /showrepl {1}." -f $baseline.DNM, $v.Server, $v.DNM))
      $ok = $false
    }
  }

  if ($ok) {
    Write-Warning (("[pass] All DCs agree on DC list and FSMO role holders.`n") + ("Baseline DC: {0} ; DCs: [{1}]. Cross-check is order- and case-insensitive." -f $baseline.Server, $baseDCsJoined))
  }
}


function HealthTest-Dcdiag {
    write-progress "Runing DCDIAG /c /v"
    $AllTestResults = Get-DcDiagFailures -Comprehensive
    if($AllTestResults){
      write-progress "Runing DCDIAG /v to find out if the failure is in the basic tests"
      $BasicTestResults = Get-DcDiagFailures
      $AllTestResults | %{
          $testName = $_.failureline -replace '^[ .]*'
          if($_.Test -in $BasicTestResults.Test){
            $interesting_lines = (($_.BlockText -split "`n"|?{$_.trim()}|sls -NotMatch '\bno ([A-Za-z]+ )?errors?\b|\bPASS +FAIL\b|\.\.\.\.\.\..* failed test ').line|sls 'error|fail').line -replace '^ +'
            if ($testName -in @('DFSREvent','SystemLog')) {
                Write-Warning "[notice] 'DCDIAG /v' reports a failure in this basic test that examines the event log: $testName`nSince this test fails when warnings/errors appear in the event log, false positives are likely.`nRun DCDIAG /v, search for '$testName' and examine the detailed report above it.`nBelow are lines from that report that contain words like error/fail:`n$interesting_lines"
            } else {
                Write-Warning "[failure] 'DCDIAG /v' reports a failure in this basic test: $testName`nRun DCDIAG /v, search for '$testName' and examine the detailed report above it.`nBelow are lines from that report that contain words like error/fail:`n$interesting_lines"
            }
          } else {
            Write-Warning "[warning] 'DCDIAG /c /v' reports a failure in this extra test: $testName`nRun DCDIAG /c /v (do include the /c to run extra tests), search for '$testName' and examine the detailed report above it.`nBelow are lines from that report that contain words like error/fail:`n$interesting_lines"
          }
      }
      return
    }
  Write-Warning "[pass] DCDIAG /c reports no failures."
}


function HealthTest-RidManager{
  $out=& dcdiag /test:ridmanager /v 2>&1
  $fail=($out | Select-String -Pattern 'failed test RidManager','is low' -SimpleMatch)
  if($fail){ Write-Warning "[failure] RID Manager test reported issues`nReview dcdiag /test:ridmanager output"; } else { Write-Warning "[pass] RID Manager health OK (dcdiag)" }
}


function HealthTest-DcDnsARecords{
  $bad=@()
  foreach($dc in (Get-ADDomainController -Filter *)){
    $hn=$dc.HostName; $ip=$dc.IPv4Address
    if(-not $hn -or -not $ip){ continue }
    $ares=(Resolve-DnsName -Name $hn -Type A -ErrorAction SilentlyContinue).IPAddress
    if(-not $ares){ $msg="$hn has no A records in DNS"; $bad+=$msg; Write-Warning "[failure] $($msg)"; continue }
    if($ares -notcontains $ip){ $msg="$hn A record mismatch: AD IP=$ip, DNS IPs="+($ares -join ','); $bad+=$msg; Write-Warning "[failure] $($msg)" }
  }
  if($bad.Count -eq 0){ Write-Warning "[pass] DC DNS A records match AD IPs for all DCs" }
}


function HealthTest-DfsrBacklogSysvol{
  [CmdletBinding()] param([int]$MaxBacklog=100)
  $group='Domain System Volume'; $folder='SYSVOL Share'
  $dcs=Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName
  $bad=$false
  foreach($dc in $dcs){
    foreach($peer in $dcs){
      if($dc -eq $peer){continue}
      $b=Get-DfsrBacklog -GroupName $group -FolderName $folder -SourceComputerName $peer -DestinationComputerName $dc -ErrorAction SilentlyContinue
      if($null -ne $b){
        $count=($b | Measure-Object).Count
        if($count -gt $MaxBacklog){ $bad=$true; Write-Warning "[failure] DFSR backlog above threshold: $dc <- $peer : $count (Max=$MaxBacklog)" }
      }
    }
  }
  if(-not $bad){ Write-Warning "[pass] DFSR SYSVOL backlog within threshold on all DC pairs" }
}


function HealthTest-DfsReplicationState {
  $stateNames = @{0='Uninitialized';1='Initialized';2='Initial_Sync';3='Auto_Recovery';4='Normal';5='Error'}

  $repl = Get-CimInstance -Namespace 'root\MicrosoftDFS' -ClassName 'DfsrReplicatedFolderInfo' -ErrorAction SilentlyContinue |
          Select-Object ReplicatedFolderName, ReplicationGroupName, state

  if (-not $repl) {
    Write-Warning "[failure] Could not query DFSR state (class root\MicrosoftDFS:DfsrReplicatedFolderInfo not found or no data).`nIs DFS Replication installed and running? Do you have permissions?"
    return
  }

  $notNormal = $repl | Where-Object { $_.state -ne 4 }

  foreach ($r in $notNormal) {
    $name = $stateNames[$r.state]; if (-not $name) { $name = 'Unknown' }
    if ($r.state -in 1,2,3) {
      Write-Warning "[warning] $(("DFSR replication for '{0}' is at state {1} ({2}) instead of 4 (Normal)" -f $r.ReplicatedFolderName, $r.state, $name))"
    } else {
      Write-Warning "[failure] $(("DFSR replication for '{0}' is at state {1} ({2}) instead of 4 (Normal)" -f $r.ReplicatedFolderName, $r.state, $name))" `
        -comment ("Group: {0}. States: 0 Uninitialized, 1 Initialized, 2 Initial_Sync, 3 Auto_Recovery, 4 Normal, 5 Error." -f $r.ReplicationGroupName)
    }
  }

  if (-not $notNormal) {
    Write-Warning "[pass] All DFSR replications are at state 4 (Normal)"
  }
}


function HealthTest-DfsrBacklog {
    param([string]$RGName='Domain System Volume')
    if (-not(Get-Service DFSR -ErrorAction SilentlyContinue)) {
        Write-Output "No DFSR service; skipping HealthTest-DfsrBacklog."
        return
    }
    if (-not (Get-Command Get-DfsrBacklog -ErrorAction SilentlyContinue)) {
        Write-Warning "[warning] DFSR cmdlets not available. Can't start the DFSR backlog healthcheck." `
            -comment 'I suggest you install RSAT-DFS-Mgmt-Con:`n        Install-WindowsFeature RSAT-DFS-Mgmt-Con'
        return
    }
    $conn = Get-DfsrConnection -GroupName $RGName -ErrorAction SilentlyContinue
    if (-not $conn) { Write-Warning "[info] No DFS-R connections found for '$RGName'"; return }
    $over = @()
    foreach ($c in $conn) {
      $b = Get-DfsrBacklog -GroupName $RGName -SourceComputerName $c.SourceComputerName -DestinationComputerName $c.DestinationComputerName -ErrorAction SilentlyContinue
      if ($b -and $b.Count -gt 1000) { $over += "$($c.SourceComputerName)->$($c.DestinationComputerName): $($b.Count)" }
    }
    if ($over.Count -gt 0) { Write-Warning "[warning] DFS-R backlog high`n$($over -join ' | ')"; return }
    Write-Warning "[pass] DFS-R backlog OK"; return
}


function HealthTest-DisabledGpoLinksAtDomainRoot{
  if(-not (Get-Command Get-GPO -ErrorAction SilentlyContinue)){
    Write-Warning "[warning] GroupPolicy cmdlets not available; install RSAT/GPMC (GroupPolicy module)."
    return
  }

  $root=$null
  if(Get-Command Get-ADDomain -ErrorAction SilentlyContinue){
    try{ $root=(Get-ADDomain).DistinguishedName }catch{}
  }
  if(-not $root){
    try{
      $dns=(Get-CimInstance Win32_ComputerSystem).Domain
      if(-not $dns -or $dns -eq 'WORKGROUP'){ throw "Not on a domain" }
      $root=($dns -split '\.')|ForEach-Object{"DC=$_"} -join ','
    }catch{
      Write-Warning "[warning] Cannot resolve domain root DN (need AD or machine joined to a domain)."
      return
    }
  }

  $parseFailures=0
  $links=@()
  foreach($g in (Get-GPO -All -ErrorAction Stop)){
    try{
      $xml=[xml](Get-GPOReport -Guid $g.Id -ReportType Xml -ErrorAction Stop)
      foreach($lnk in @($xml.GPO.LinksTo.LinkTo)){
        if($lnk.SOMPath -eq $root){
          $links += [pscustomobject]@{
            DisplayName=$xml.GPO.Name
            Enabled= if($lnk.Enabled -eq 'true'){1}else{0}
            Enforced=if($lnk.NoOverride -eq 'true'){1}else{0}
            Order=[int]$lnk.Order
          }
        }
      }
    }catch{
      $parseFailures++
      $msg=($_.Exception.Message -replace '\s+',' ').Trim()
      Write-Warning "[warning] Failed to parse GPO report; skipping GPO: $($g.DisplayName) ($($g.Id)) - $msg"
    }
  }

  if($parseFailures -gt 0){
    Write-Warning "[warning] One or more GPO reports could not be read/parsed ($parseFailures). Results may be incomplete."
  }

  if(-not $links){
    Write-Warning "[pass] No GPO links found at the domain root ($root)."
    return
  }

  $flagged=$false
  foreach($l in $links){
    if($l.Enabled -eq 0){ $flagged=$true; Write-Warning "[warning] Domain-root GPO link is disabled: $($l.DisplayName)" }
    if($l.Enforced -eq 0){ $flagged=$true; Write-Warning "[warning] Domain-root GPO link is not enforced: $($l.DisplayName)" }
  }

  if(-not $flagged){ Write-Warning "[pass] All domain-root GPO links are enabled (and enforced per policy)" }
  else{ Write-Warning "[failure] There are disabled or non-enforced GPO links at the domain root" }
}


function HealthTest-DuplicateSpn{
  $objs = Get-ADObject -LDAPFilter "(servicePrincipalName=*)" -Properties servicePrincipalName,sAMAccountName,distinguishedName -ErrorAction Stop
  if(-not $objs){ Write-Warning "[pass] No objects with SPN found"; return }

  $map = @{}
  foreach($o in $objs){
    $acct = if($o.sAMAccountName){ $o.sAMAccountName } else { $o.distinguishedName }
    foreach($spn in @($o.servicePrincipalName)){
      if([string]::IsNullOrEmpty($spn)){ continue }
      if($map.ContainsKey($spn)){ $map[$spn] += $acct } else { $map[$spn] = @($acct) }
    }
  }

  $dupsFound=$false
  foreach($spn in $map.Keys){
    $owners = @($map[$spn] | Sort-Object -Unique)
    if($owners.Count -gt 1){
      $dupsFound=$true
      Write-Warning "[failure] $("Duplicate SPN detected")`n$(("$spn -> " + ($owners -join ', ')))"
    }
  }
  if(-not $dupsFound){ Write-Warning "[pass] No duplicate SPNs detected" }
}


function HealthTest-GcPlacement{
  [CmdletBinding()] param([switch]$AtLeastOnePerSite=$true)
  $dcs=Get-ADDomainController -Filter *
  if(-not $AtLeastOnePerSite){
    $has=($dcs | Where-Object {$_.IsGlobalCatalog}).Count -gt 0
    if($has){ Write-Warning "[pass] At least one Global Catalog exists in the domain" } else { Write-Warning "[failure] No Global Catalog server detected in the domain" }
    return
  }
  $sites=$dcs | Group-Object Site
  $bad=@()
  foreach($s in $sites){
    if(($s.Group | Where-Object {$_.IsGlobalCatalog}).Count -eq 0){ $bad+=$s.Name; Write-Warning "[failure] No Global Catalog in site '$($s.Name)'" }
  }
  if($bad.Count -eq 0){ Write-Warning "[pass] Each AD site has at least one Global Catalog" }
}


function HealthTest-GpoVersionConsistency{

    $dom=(Get-CimInstance Win32_ComputerSystem).Domain
    $base="\\$dom\SYSVOL\$dom\Policies"
    $bad=$false
    foreach($g in Get-GPO -All){
      $ini="$base\{$($g.Id)}\gpt.ini"
      $gptVer = if(Test-Path $ini){ [int]((Get-Content $ini | where {$_ -match '^Version='}) -replace 'Version=','') } else { -1 }
      if($gptVer -lt 0){ $bad=$true; Write-Warning "[failure] GPO missing GPT: $($g.DisplayName)"; continue }
      $uGpt=$gptVer -shr 16; $cGpt=$gptVer -band 0xFFFF
      if($uGpt -ne $g.User.DSVersion -or $cGpt -ne $g.Computer.DSVersion){
        $bad=$true
        Write-Warning "[failure] GPO GPT/AD version mismatch: '$($g.DisplayName)' User AD=$($g.User.DSVersion) GPT=$uGpt; Computer AD=$($g.Computer.DSVersion) GPT=$cGpt"
      }
    }
  if(-not $bad){ Write-Warning "[pass] All GPOs have matching GPT/GPC versions" }
}


function HealthTest-KccConnectivity{
  $dcs = Get-ADDomainController -Filter *
  $anyFail = $false
  foreach($dc in $dcs){
    $meta = Get-ADReplicationPartnerMetadata -Target $dc.HostName -Scope Server -ErrorAction SilentlyContinue
    $metaCount = 0
    if ($meta) { $metaCount = (@($meta) | Measure-Object).Count }

    $q = @{
      SearchBase  = $dc.NTDSSettingsObjectDN
      SearchScope = 'OneLevel'
      LDAPFilter  = '(objectClass=nTDSConnection)'
      Properties  = 'enabledConnection'
      ErrorAction = 'SilentlyContinue'
    }
    $objs = Get-ADObject @q

    $enabledCount = 0
    foreach($o in @($objs)){
      $isEnabled = $true
      if ($null -ne $o.enabledConnection) { $isEnabled = [bool]$o.enabledConnection }
      if ($isEnabled) { $enabledCount++ }
    }

    if($metaCount -eq 0 -and $enabledCount -eq 0){
      $anyFail = $true
      Write-Warning ("[failure] No inbound replication detected for $($dc.HostName)`nPartnerMetadata=" + $metaCount + "; EnabledConnectionObjects=" + $enabledCount + "; NTDS=" + $dc.NTDSSettingsObjectDN)
      continue
    }
    if($metaCount -eq 0 -and $enabledCount -gt 0){
      Write-Warning "[notice] $(("Inbound connection objects exist but partner metadata returned none for " + $dc.HostName + ". Recheck with: repadmin /showrepl " + $dc.HostName))"
    }
    if($metaCount -gt 0 -and $enabledCount -eq 0){
      Write-Warning "[notice] Inbound partners reported by $($dc.HostName) but no enabled nTDSConnection objects under NTDS Settings. Possible permission/cache/KCC timing; investigate ISTG/KCC."
    }
  }
  if(-not $anyFail){ Write-Warning "[pass] Inbound replication present for all DCs (partner metadata OK, NTDS container cross-check performed)" }
}


function HealthTest-KerberosEncryptionTypes{
  $objs=Get-ADObject -LDAPFilter '(msDS-SupportedEncryptionTypes=*)' -Properties msDS-SupportedEncryptionTypes,sAMAccountName,objectClass
  $bad_count = 0
  foreach($o in $objs){
    $v=[int]$o.'msDS-SupportedEncryptionTypes'
    if(($v -band 0x4) -ne 0){
        Write-Warning "[warning] RC4 permitted for $($o.objectClass): $($o.sAMAccountName)"
        $bad_count += 1
        if ($bad_count -gt 10) {
            Write-Warning "[warning] I will not report any more 'RC4 permitted for...' warnings"
            break
        }
    }
  }
  if($bad_count -eq 0){ Write-Warning "[pass] No accounts permit RC4 in msDS-SupportedEncryptionTypes" }
}


function HealthTest-LdapSigningChannelBinding {
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'

    # Read all registry values in one shot (avoids repeated calls)
    $props = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue

    # LDAPServerIntegrity
    $signProp = $props.PSObject.Properties['LDAPServerIntegrity']
    $sign     = if ($signProp) { $signProp.Value } else { $null }

    # LdapEnforceChannelBinding
    $cbProp = $props.PSObject.Properties['LdapEnforceChannelBinding']
    $cb     = if ($cbProp) { $cbProp.Value } else { $null }

    # Bonus tip: normalize null -> 0 (disabled)
    $sign = [int]($sign + 0)
    $cb   = [int]($cb   + 0)

    if (($sign -ge 1) -and ($cb -ge 1)) {
        Write-Warning "[pass] LDAP signing & channel binding enforced"
    } else {
        Write-Warning "[notice] LDAP signing and/or channel binding not enforced`nLDAPServerIntegrity=$sign; LdapEnforceChannelBinding=$cb"
    }
}


function HealthTest-ReplicationLatency{
  [CmdletBinding()] param([int]$MaxMinutes=30)
  $parts=@((Get-ADRootDSE).schemaNamingContext,(Get-ADRootDSE).configurationNamingContext)
  $anyFail=$false
  foreach($dc in (Get-ADDomainController -Filter *)){
    foreach($p in $parts){
      $m=Get-ADReplicationPartnerMetadata -Target $dc.HostName -Partition $p -ErrorAction Stop
      foreach($row in $m){
        $mins = [int](((Get-Date)-$row.LastReplicationSuccess).TotalMinutes)
        if($mins -gt $MaxMinutes){ $anyFail=$true; Write-Warning "[failure] Replication latency above threshold`n$($dc.HostName) partition '$p' latency=$mins min (Max=$MaxMinutes)" }
      }
    }
  }
  if(-not $anyFail){ Write-Warning "[pass] AD replication latency acceptable (<= $MaxMinutes min on schema/config)" }
}


function HealthTest-RodcPrp{
  $rodcs=Get-ADDomainController -Filter {IsReadOnly -eq $true}
  if(-not $rodcs){ Write-Warning "[pass] No RODCs found (PRP not applicable)"; return }
  $bad=$false
  foreach($r in $rodcs){
    $ro=Get-ADObject $r.NTDSSettingsObjectDN -Properties msDS-RevealOnDemandGroup,msDS-NeverRevealGroup
    if(-not $ro.'msDS-RevealOnDemandGroup' -and -not $ro.'msDS-NeverRevealGroup'){ $bad=$true; Write-Warning "[failure] RODC PRP not configured on $($r.HostName)" }
  }
  if(-not $bad){ Write-Warning "[pass] PRP is configured on all RODCs" }
}


function HealthTest-SchemaVersionConsistency{
  $schemaNC=(Get-ADRootDSE).schemaNamingContext
  $vers=@{}; $errs=@()
  foreach($dc in (Get-ADDomainController -Filter *)){
    try{
      $ov=(Get-ADObject -Identity $schemaNC -Server $dc.HostName -Properties objectVersion -ErrorAction Stop).objectVersion
      if($null -eq $ov -or "$ov" -eq ''){
        $msg="$($dc.HostName): objectVersion missing"; $errs+=$msg; Write-Warning "[failure] $($msg)"; continue
      }
      $ov=[int]("$ov".Trim()); $vers[$dc.HostName]=$ov
    }catch{
      $msg="$($dc.HostName): $($_.Exception.Message)"; $errs+=$msg; Write-Warning "[failure] $($msg)"
    }
  }

  if($vers.Count -eq 0){
    Write-Warning "[failure] $("AD schema version consistency")`n$(("No schema versions retrieved. Errors: "+($errs -join ' | ')))"
    return
  }

  # Force array so .Count and [0] are always valid even when only one element
  $distinct = @($vers.Values | Sort-Object -Unique)
  $distinctCount = $distinct.Count

  $perDc = ($vers.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; '

  $det = if ($distinctCount -eq 1) {
    "SchemaVersion=$($distinct[0]); $perDc"
  } else {
    "Mismatch: "+($distinct -join ', ')+" | "+$perDc
  }

  if($errs){ $det += " | Errors: "+($errs -join ' | ') }

  $pass = ($distinctCount -eq 1 -and $errs.Count -eq 0)

  if($pass){
    Write-Warning "[pass] AD schema version consistent across DCs ($det)"
  } else {
    Write-Warning "[failure] $("AD schema version consistent across DCs")`n$($det)"
  }
}


function HealthTest-SysvolContentConsistency{
    $dom=(Get-CimInstance Win32_ComputerSystem).Domain
    $dcs=Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName

    $sigs = foreach($dc in $dcs){
      $p="\\$dc\SYSVOL\$dom\Policies"
      if(-not (Test-Path -LiteralPath $p)){
        Write-Warning "[failure] SYSVOL Policies path missing on ${dc}: $p"
        [pscustomobject]@{DC=$dc;Sig='<missing>'}
        continue
      }
      $files = Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue
      $count = ($files | Measure-Object).Count
      [uint64]$total=0; foreach($f in $files){ $total += [uint64]$f.Length }
      [pscustomobject]@{DC=$dc;Sig=('' + $count + '|' + $total).Trim()}
    }

    # Compute uniqueness without Group-Object
    $uniqueSigs = @($sigs | Select-Object -ExpandProperty Sig -Unique)
    $hasMissing = $uniqueSigs -contains '<missing>'
    $allSame    = ($uniqueSigs.Count -eq 1) -and -not $hasMissing
    $map        = ($sigs | ForEach-Object { "$($_.DC)=$($_.Sig)" }) -join ' | '

    # Debug: show what PowerShell *thinks* are distinct values and their bytes
    write-verbose "`nDEBUG: Distinct Sig values ($uniqueSigs.Count):"
    $uniqueSigs | ForEach-Object {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($_)
      write-verbose "  '$_'  bytes=[$([System.BitConverter]::ToString($bytes))]"
    }

    if($allSame){
      Write-Warning "[pass] SYSVOL policy tree manifests match across all DCs"
    } elseif($hasMissing){
      Write-Warning "[failure] $("At least one DC lacks SYSVOL\Policies")`n$($map)"
    } else {
      Write-Warning "[failure] $("SYSVOL policy manifests are not consistent across DCs")`n$($map)"
    }
}


function HealthTest-SysvolAclHygiene{
  $path="C:\Windows\SYSVOL\sysvol"
  $acl=Get-Acl -Path $path
  $bad=$false
  foreach($ace in $acl.Access){
    $id=$ace.IdentityReference.Value
    $wr=($ace.FileSystemRights.ToString() -match 'Write|Modify|FullControl')
    if($wr -and ($id -match 'Everyone|Authenticated Users')){ $bad=$true; Write-Warning "[failure] SYSVOL ACL too broad: $id has $($ace.FileSystemRights)" }
  }
  if(-not $bad){ Write-Warning "[pass] SYSVOL does not grant write to broad principals (Everyone/Auth Users)" }
}


function HealthTest-TombstoneLifetime{
  [CmdletBinding()] param([int]$MinDays=60)
  $ds="CN=Directory Service,CN=Windows NT,CN=Services,$((Get-ADRootDSE).ConfigurationNamingContext)"
  $tl=(Get-ADObject $ds -Properties tombstoneLifetime).tombstoneLifetime
  if(-not $tl){$tl=60}
  if($tl -ge $MinDays){ Write-Warning "[pass] AD tombstoneLifetime is sufficient ($tl days >= $MinDays)" }
  else{ Write-Warning "[failure] AD tombstoneLifetime below threshold`nCurrent=$tl; Min=$MinDays" }
}


function HealthTest-UnconstrainedDelegationAccounts{
  [CmdletBinding()] param([switch]$IncludeDomainControllers)

  $bitTrusted  = 524288    # 0x80000 TRUSTED_FOR_DELEGATION
  $bitDC       = 8192      # 0x2000  SERVER_TRUST_ACCOUNT

  if ($IncludeDomainControllers) {
    $ldap = "(&(|(objectClass=user)(objectClass=computer))(userAccountControl:1.2.840.113556.1.4.803:=$bitTrusted))"
  } else {
    $ldap = "(&(|(objectClass=user)(objectClass=computer))(userAccountControl:1.2.840.113556.1.4.803:=$bitTrusted)(!(userAccountControl:1.2.840.113556.1.4.803:=$bitDC)))"
  }

  $objs = @(
    Get-ADObject -LDAPFilter $ldap -Properties sAMAccountName,objectClass,dnsHostName |
      Select-Object sAMAccountName,objectClass,dnsHostName
  )

  if ($objs.Count -gt 0) {

    foreach($o in $objs){

      # Determine if computer object (objectClass may be array or string)
      $isComputer = $false
      if ($o.objectClass -is [array]) {
        if ($o.objectClass -contains 'computer') { $isComputer = $true }
      } elseif ($o.objectClass -eq 'computer') {
        $isComputer = $true
      }

      # Build a friendly name
      if ($isComputer) {
        $name = $o.sAMAccountName.TrimEnd('$')
        if ($o.dnsHostName) {
          $name += " ($($o.dnsHostName))"
        }
        $cls = 'computer'
      } else {
        $name = $o.sAMAccountName
        $cls  = 'user'
      }

      Write-Warning "[failure] Unconstrained delegation account found`n$($cls): $name"
    }

  } else {
    Write-Warning "[pass] No unconstrained delegation accounts"
  }
}


function HealthTest-DfsDiagTestDCs {
    write-progress "Runing 'DFSDIAG /TestDCs'"
    $out=(DFSDIAG /TestDCs | sls -NotMatch '^$|^(Information|[A-Za-z]+ing|Success)[ :]|^Finished TestDcs[.] *$')
    if ($out) {
        Write-Warning "[failure] 'DFSDIAG /TestDCs' output does not seem clean`nIf the following lines I was not expecting indicate problems, run DFSDIAG /TestDCs to view the whole output:`n$out"
        return
    }
    Write-Warning "[pass] 'DFSDIAG /TestDCs' returned expected output"
}


function HealthTest-DfsNamespaceEnumerate{
  $roots=Get-DfsnRoot -ErrorAction SilentlyContinue
  if(-not $roots){ Write-Warning "[pass] No DFS Namespace roots found (nothing to check)"; return }
  $count=0
  foreach($r in $roots){ $count += (Get-DfsnFolder -Path $r.Path -ErrorAction SilentlyContinue | Measure-Object).Count }
  Write-Warning "[pass] DFSN roots/folders enumerate: Roots=$($roots.Count); Folders=$count"
}


function HealthTest-PreWin2000Group{
  $g=Get-ADGroup -Identity 'Pre-Windows 2000 Compatible Access'
  $m=Get-ADGroupMember $g -Recursive -ErrorAction SilentlyContinue
  foreach($u in $m){ Write-Warning "[failure] 'Pre-Windows 2000 Compatible Access' contains member: $($u.SamAccountName)" }
  if(($m | Measure-Object).Count -eq 0){ Write-Warning "[pass] 'Pre-Windows 2000 Compatible Access' group has no members" }
}


function HealthTest-TrustsVerify{
  $trusts=Get-ADTrust -Filter * -ErrorAction Stop
  if(-not $trusts){ Write-Warning "[pass] No inter-domain trusts configured"; return }
  $bad=$false
  foreach($t in $trusts){
    $r=& netdom.exe trust $t.TargetName /domain:$($t.Source) /verify 2>&1
    if($LASTEXITCODE -ne 0){ $bad=$true; Write-Warning "[failure] Trust verification failed`n$($t.Source) -> $($t.TargetName): $r" }
  }
  if(-not $bad){ Write-Warning "[pass] All domain trusts verify successfully" }
}


function HealthTest-RecycleBinEnabled{
  $f=Get-ADOptionalFeature 'Recycle Bin Feature' -ErrorAction Stop
  $enabled=($f.EnabledScopes -ne $null -and $f.EnabledScopes.Count -gt 0)
  if($enabled){ Write-Warning "[pass] AD Recycle Bin enabled" } else { Write-Warning "[notice] AD Recycle Bin is not enabled -- consider enabling it." }
}


function HealthTest-GpWmiFiltersNamespaces{
  $bad=$false
  $items=@()

  # Resolve domain via RootDSE
  $dns=$null; $dn=$null
  try{
    $rootDse = [ADSI]"LDAP://RootDSE"
    $dn = $rootDse.defaultNamingContext
    $dns = $rootDse.rootDomainNamingContext -replace '(?i)(?<=,|^)\s*dc=','' -replace '\s*,\s*','.'
  }catch{
    Write-Warning "[warning] This machine cannot read LDAP RootDSE. Is it domain-joined and can it reach a DC?"
    return
  }

  # Try GPMC COM first if present
  $usedCom=$false
  try{
    if([type]::GetTypeFromProgID('GPMgmt.GPM')){
      $gpm   = New-Object -ComObject GPMgmt.GPM
      $const = $gpm.GetConstants()
      $dom   = $gpm.GetDomain($dns,$null,$const.UseAnyDC)
      $sc    = $gpm.CreateSearchCriteria()
      foreach($f in @($dom.SearchWmiFilters($sc))){
        $got=$false
        try{
          foreach($q in @($f.Queries)){
            if($q -and $q.Namespace){ $items += [pscustomobject]@{Filter=$f.Name; Namespace=$q.Namespace}; $got=$true }
          }
        }catch{}
        if(-not $got){
          $txt = ($f.Query,$f.Description,$f.ToString()) -join "`n"
          foreach($m in [regex]::Matches($txt,'(?im)\broot(\\[A-Za-z0-9_]+)+')){
            $items += [pscustomobject]@{Filter=$f.Name; Namespace=$m.Value}
          }
        }
      }
      $usedCom=$true
    }
  }catch{
    # fall through to LDAP
    $usedCom=$false
  }

  # LDAP fallback (and also used to detect "no filters defined")
  if(-not $usedCom -or -not $items){
    try{
      $wmipath = "LDAP://CN=WMIPolicy,CN=System,$dn"
      $wmicont = [ADSI]$wmipath
      if(-not $wmicont.psbase.Name){
        Write-Warning "[pass] No GPO WMI filters defined (CN=WMIPolicy container not found)."
        return
      }
      $ds = New-Object System.DirectoryServices.DirectorySearcher($wmicont)
      $ds.PageSize=500
      $ds.ReferralChasing = [System.DirectoryServices.ReferralChasingOption]::All
      [void]$ds.PropertiesToLoad.AddRange(@('msWMI-Name','msWMI-Parm1'))
      $ds.Filter="(objectClass=msWMI-Som)"
      foreach($res in @($ds.FindAll())){
        $name = ($res.Properties['mswmi-name']|Select-Object -First 1)
        foreach($p in @($res.Properties['mswmi-parm1'])){
          $ns=$null
          if($p -match '^\s*\d+\s*;\s*([^;:]+)'){ $ns=$matches[1] }
          if(-not $ns){
            $m=[regex]::Match($p,'(?im)\broot(\\[A-Za-z0-9_]+)+')
            if($m.Success){ $ns=$m.Value }
          }
          if($ns){ $items += [pscustomobject]@{Filter=$name; Namespace=$ns} }
        }
      }
    }catch{
      Write-Warning "[warning] Cannot enumerate WMI filters via GPMC or LDAP. Check: domain join, DC reachability/DNS, and GPMC installation."
      return
    }
  }

  if(-not $items){ Write-Warning "[pass] No GPO WMI filters defined"; return }

  $unique = $items | Sort-Object Filter,Namespace -Unique
  foreach($i in $unique){
    try{
      $null=Get-CimInstance -Namespace $i.Namespace -ClassName __NAMESPACE -ErrorAction Stop
    } catch {
      $bad=$true
      Write-Warning "[failure] WMI namespace missing for filter '$($i.Filter)': $($i.Namespace)"
    }
  }  

  if(-not $bad){ Write-Warning "[pass] All WMI namespaces referenced by GPO WMI filters exist on this host" }
  else{ Write-Warning "[warning] One or more GPO WMI filter namespaces are missing on this host" }
}


function HealthTest-GpupdatePolicyApply {
  [CmdletBinding()] param()
  $cs   = Get-CimInstance Win32_ComputerSystem
  $role = $cs.DomainRole
  $fn   = $MyInvocation.MyCommand.Name
  if ($role -in 0,2) { Write-Warning "[notice] This test ($fn) is not applicable to non-domain joined hosts"; return }
  if ($role -in 4,5) { Write-Warning "[notice] This test ($fn) is not applicable to Domain Controllers"; return }


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
    Write-Warning "[pass] Computer and user policy updates completed successfully (gpupdate)."
    return
  }

  if ($compOk) {
    Write-Warning "[pass] Computer policy update completed successfully (gpupdate)."
  } else {
    Write-Warning "[failure] $("Computer policy update did not report success.")`n$(("gpupdate output:`n" + $text))"
  }

  if (-not $userOk) {
    if ($isSystem) {
      Write-Warning "[notice] $("User policy update did not report success (gpupdate running under SYSTEM/non-interactive).")`n$(("This can be expected when no interactive user is logged on.`nRaw gpupdate output:`n" + $text))"
    } else {
      Write-Warning "[failure] $("User policy update did not report success.")`n$(("Expected success for interactive user.`nRaw gpupdate output:`n" + $text))"
    }
  } else {
    Write-Warning "[pass] User policy update completed successfully (gpupdate)."
  }
}


function Get-DcDiagFailures {
  [CmdletBinding()]
  param(
    [string]$File,
    [switch]$Comprehensive
  )

  if     ($File)             { $s = Get-Content -LiteralPath $File -Raw }
  elseif ($Comprehensive)    { $s = dcdiag /c /v | Out-String }
  else                       { $s = dcdiag /v   | Out-String }

  $rePhase = '^(?<p>\S.*)$'
  $reServer= '^\s{3}Testing server:\s*(?<s>.+)$'
  $reStart = '^\s{6}Starting test:\s*(?<t>.+)$'
  $reEnd   = '^\s*\.{25,}\s+(?<srv>\S+)\s+(?<st>passed|failed)\s+test\s+(?<tt>.+?)\s*$'

  $phase=$null; $server=$null; $test=$null; $buf=@(); $out=@()

  foreach($line in ($s -split "\r?\n")){

    $m = [regex]::Match($line, $rePhase)
    if($m.Success){
      $p = $m.Groups['p'].Value
      if($p -match '^Doing .* tests$'){ $phase = $p; continue }
    }

    $m = [regex]::Match($line, $reServer)
    if($m.Success){ $server = $m.Groups['s'].Value; continue }

    $m = [regex]::Match($line, $reStart)
    if($m.Success){
      $test = $m.Groups['t'].Value
      $buf  = @(); $buf += $line
      continue
    }

    if($test){
      $buf += $line
      $m = [regex]::Match($line, $reEnd)
      if($m.Success){
        $st = $m.Groups['st'].Value
        $tt = $m.Groups['tt'].Value
        if($st -eq 'failed' -and $tt -eq $test){
          $block = ($buf -join "`r`n")
          $out += [pscustomobject]@{
            Phase       = $phase
            Server      = $server
            Test        = $test
            Path        = ('{0} -> {1} -> Starting test: {2}' -f $phase,$server,$test)
            Status      = $st
            FailureLine = $line
            BlockText   = $block
          }
        }
        $test = $null; $buf = @()
      }
    }
  }
  $out
}
