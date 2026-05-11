<#
Active Directory & GPO Management
#>

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
    $out | Sort-Object -Unique
  }

  $ok = $true

  if (-not $Servers -or $Servers.Count -eq 0) {
    try { $Servers = Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName }
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


function HealthTest-Dcdiag {
<#
Description: Runs DCDIAG and reports failing basic and extended Active Directory diagnostics.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: dcdiag.exe.
#>

    write-progress "Runing DCDIAG /c /v"
    $AllTestResults = Get-DcDiagFailures -Comprehensive
    if($AllTestResults){
      write-progress "Runing DCDIAG /v to find out if the failure is in the basic tests"
      $BasicTestResults = Get-DcDiagFailures
      $AllTestResults | %{
          $testName = $_.failureline -replace '^[ .]*'
          if($_.Test -in $BasicTestResults.Test){
            $interesting_lines = (($_.BlockText -split "`n"|?{$_.trim()}|sls -NotMatch '\bno ([A-Za-z]+ )?errors?\b|\bPASS +FAIL\b|\.\.\.\.\.\..* failed test ').line|sls 'error|fail').line -replace '^ +'
            if ($testName -like '*DFSREvent*' -or $testName -like '*SystemLog*') {
                Write-Warning "[NOTICE] 'DCDIAG /v' reports a failure in this basic test that examines the event log: $testName`nSince this test fails when warnings/errors appear in the event log, false positives are likely.`nRun DCDIAG /v, search for '$testName' and examine the detailed report above it.`nBelow are lines from that report that contain words like error/fail:`n$interesting_lines"
            } else {
                Write-Warning "[FAILURE] 'DCDIAG /v' reports a failure in this basic test: $testName`nRun DCDIAG /v, search for '$testName' and examine the detailed report above it.`nBelow are lines from that report that contain words like error/fail:`n$interesting_lines"
            }
          } else {
            Write-Warning "[WARNING] 'DCDIAG /c /v' reports a failure in this extra test: $testName`nRun DCDIAG /c /v (do include the /c to run extra tests), search for '$testName' and examine the detailed report above it.`nBelow are lines from that report that contain words like error/fail:`n$interesting_lines"
          }
      }
      return
    }
  Write-Warning "[PASS] DCDIAG /c reports no failures."
}


function HealthTest-RidManager{
<#
Description: Runs the RID Manager dcdiag test and reports any detected issues.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: None.
#>
  $out=& dcdiag /test:ridmanager /v 2>&1
  $fail=($out | Select-String -Pattern 'failed test RidManager','is low' -SimpleMatch)
  if($fail){ Write-Warning "[FAILURE] RID Manager test reported issues`nReview dcdiag /test:ridmanager output"; } else { Write-Warning "[PASS] RID Manager health OK (dcdiag)" }
}


function HealthTest-DfsReplicationState {
<#
Description: Checks whether DFS Replication folders are in the Normal state.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: None.
#>
  $stateNames = @{0='Uninitialized';1='Initialized';2='Initial_Sync';3='Auto_Recovery';4='Normal';5='Error'}

  $repl = Get-CimInstance -Namespace 'root\MicrosoftDFS' -ClassName 'DfsrReplicatedFolderInfo' -ErrorAction SilentlyContinue |
          Select-Object ReplicatedFolderName, ReplicationGroupName, state

  if (-not $repl) {
    Write-Warning "[FAILURE] Could not query DFSR state (class root\MicrosoftDFS:DfsrReplicatedFolderInfo not found or no data).`nIs DFS Replication installed and running? Do you have permissions?"
    return
  }

  $notNormal = $repl | Where-Object { $_.state -ne 4 }

  foreach ($r in $notNormal) {
    $name = $stateNames[$r.state]; if (-not $name) { $name = 'Unknown' }
    if ($r.state -in 1,2,3) {
      Write-Warning ("[WARNING] DFSR replication for '{0}' is at state {1} ({2}) instead of 4 (Normal)" -f $r.ReplicatedFolderName, $r.state, $name)
    } else {
      Write-Warning ("[FAILURE] DFSR replication for '{0}' is at state {1} ({2}) instead of 4 (Normal)" -f $r.ReplicatedFolderName, $r.state, $name) `
        -comment ("Group: {0}. States: 0 Uninitialized, 1 Initialized, 2 Initial_Sync, 3 Auto_Recovery, 4 Normal, 5 Error." -f $r.ReplicationGroupName)
    }
  }

  if (-not $notNormal) {
    Write-Warning "[PASS] All DFSR replications are at state 4 (Normal)"
  }
}


function HealthTest-DfsrBacklog {
<#
Description: Checks DFS Replication backlog and warns when queued updates are high.
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-Service, Get-Command, Get-DfsrBacklog.
#>
    param([string]$RGName='Domain System Volume')
    if (-not(Get-Service DFSR -ErrorAction SilentlyContinue)) {
        Write-Output "No DFSR service; skipping HealthTest-DfsrBacklog."
        return
    }
    if (-not (Get-Command Get-DfsrBacklog -ErrorAction SilentlyContinue)) {
        Write-Warning "[WARNING] DFSR cmdlets not available. Can't start the DFSR backlog healthcheck." `
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
    if ($over.Count -gt 0) { Write-Warning "[WARNING] DFS-R backlog high`n$($over -join ' | ')"; return }
    Write-Warning "[PASS] DFS-R backlog OK"; return
}

function HealthTest-GpoVersionConsistency{
<#
Description: Checks whether each GPO has matching AD and SYSVOL version numbers.
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-GPO.
#>
    $dom=(Get-CimInstance Win32_ComputerSystem).Domain
    $base="\\$dom\SYSVOL\$dom\Policies"
    $bad=$false
    foreach($g in Get-GPO -All){
      $ini="$base\{$($g.Id)}\gpt.ini"
      $gptVer = if(Test-Path $ini){ [int]((Get-Content $ini | where {$_ -match '^Version='}) -replace 'Version=','') } else { -1 }
      if($gptVer -lt 0){ $bad=$true; Write-Warning "[FAILURE] GPO missing GPT: $($g.DisplayName)"; continue }
      $uGpt=$gptVer -shr 16; $cGpt=$gptVer -band 0xFFFF
      if($uGpt -ne $g.User.DSVersion -or $cGpt -ne $g.Computer.DSVersion){
        $bad=$true
        Write-Warning "[FAILURE] GPO GPT/AD version mismatch: '$($g.DisplayName)' User AD=$($g.User.DSVersion) GPT=$uGpt; Computer AD=$($g.Computer.DSVersion) GPT=$cGpt"
      }
    }
  if(-not $bad){ Write-Warning "[PASS] All GPOs have matching GPT/GPC versions" }
}


function HealthTest-ADInboundReplicationTopology{
<#
Description: Verifies that each domain controller has inbound AD replication partners and connection objects.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-ADDomainController, Get-ADReplicationPartnerMetadata, Get-ADObject.
#>
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
      $details = "PartnerMetadata=$metaCount; EnabledConnectionObjects=$enabledCount; NTDS=$($dc.NTDSSettingsObjectDN)"
      Write-Warning ("[FAILURE] No inbound replication detected for $($dc.HostName)" + "`n" + $details)
      continue
    }
    if($metaCount -eq 0 -and $enabledCount -gt 0){
      Write-Warning ("[NOTICE] Inbound connection objects exist but partner metadata returned none for {0}. Recheck with: repadmin /showrepl {0}" -f $dc.HostName)
    }
    if($metaCount -gt 0 -and $enabledCount -eq 0){
      Write-Warning "[NOTICE] Inbound partners reported by $($dc.HostName) but no enabled nTDSConnection objects under NTDS Settings. Possible permission/cache/KCC timing; investigate ISTG/KCC."
    }
  }
  if(-not $anyFail){ Write-Warning "[PASS] Inbound replication present for all DCs (partner metadata OK, NTDS container cross-check performed)" }
}


function HealthTest-KerberosEncryptionTypes{
<#
Description: Checks for AD accounts that still permit weak RC4 Kerberos encryption.
AppliesTo: DC
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-ADObject.
#>
  $objs=Get-ADObject -LDAPFilter '(msDS-SupportedEncryptionTypes=*)' -Properties msDS-SupportedEncryptionTypes,sAMAccountName,objectClass
  $bad_count = 0
  foreach($o in $objs){
    $v=[int]$o.'msDS-SupportedEncryptionTypes'
    if(($v -band 0x4) -ne 0){
        Write-Warning "[WARNING] RC4 permitted for $($o.objectClass): $($o.sAMAccountName)"
        $bad_count += 1
        if ($bad_count -gt 10) {
            Write-Warning "[WARNING] I will not report any more 'RC4 permitted for...' warnings"
            break
        }
    }
  }
  if($bad_count -eq 0){ Write-Warning "[PASS] No accounts permit RC4 in msDS-SupportedEncryptionTypes" }
}

function HealthTest-RodcPrp{
<#
Description: Checks whether each read-only domain controller has a Password Replication Policy configured.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: Get-ADDomainController, Get-ADObject.
#>
  $rodcs=Get-ADDomainController -Filter {IsReadOnly -eq $true}
  if(-not $rodcs){ Write-Warning "[PASS] No RODCs found (PRP not applicable)"; return }
  $bad=$false
  foreach($r in $rodcs){
    $ro=Get-ADObject $r.NTDSSettingsObjectDN -Properties msDS-RevealOnDemandGroup,msDS-NeverRevealGroup
    if(-not $ro.'msDS-RevealOnDemandGroup' -and -not $ro.'msDS-NeverRevealGroup'){ $bad=$true; Write-Warning "[FAILURE] RODC PRP not configured on $($r.HostName)" }
  }
  if(-not $bad){ Write-Warning "[PASS] PRP is configured on all RODCs" }
}
function HealthTest-SysvolAclHygiene{
<#
Description: Checks whether SYSVOL grants write access to overly broad principals.
AppliesTo: DC
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-Acl.
#>
  $path="C:\Windows\SYSVOL\sysvol"
  $acl=Get-Acl -Path $path
  $bad=$false
  foreach($ace in $acl.Access){
    $id=$ace.IdentityReference.Value
    $wr=($ace.FileSystemRights.ToString() -match 'Write|Modify|FullControl')
    if($wr -and ($id -match 'Everyone|Authenticated Users')){ $bad=$true; Write-Warning "[FAILURE] SYSVOL ACL too broad: $id has $($ace.FileSystemRights)" }
  }
  if(-not $bad){ Write-Warning "[PASS] SYSVOL does not grant write to broad principals (Everyone/Auth Users)" }
}

function HealthTest-DfsDiagTestDCs {
<#
Description: Runs DFSDIAG /TestDCs and reports unexpected DFS diagnostics output.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: None.
#>

    write-progress "Runing 'DFSDIAG /TestDCs'"
    $out=(DFSDIAG /TestDCs | sls -NotMatch '^$|^(Information|[A-Za-z]+ing|Success)[ :]|^Finished TestDcs[.] *$')
    if ($out) {
        Write-Warning "[FAILURE] 'DFSDIAG /TestDCs' output does not seem clean`nIf the following lines I was not expecting indicate problems, run DFSDIAG /TestDCs to view the whole output:`n$out"
        return
    }
    Write-Warning "[PASS] 'DFSDIAG /TestDCs' returned expected output"
}

function HealthTest-DfsNamespaceEnumerate{
<#
Description: Checks whether DFS namespace roots and folders can be enumerated successfully.
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: Get-DfsnRoot, Get-DfsnFolder.
#>
  $roots=Get-DfsnRoot -ErrorAction SilentlyContinue
  if(-not $roots){ Write-Warning "[PASS] No DFS Namespace roots found (nothing to check)"; return }
  $count=0
  foreach($r in $roots){ $count += (Get-DfsnFolder -Path $r.Path -ErrorAction SilentlyContinue | Measure-Object).Count }
  Write-Warning "[PASS] DFSN roots/folders enumerate: Roots=$($roots.Count); Folders=$count"
}


function HealthTest-PreWin2000Group{
<#
Description: Checks whether the Pre-Windows 2000 Compatible Access group has unexpected members.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: Get-ADGroup, Get-ADGroupMember.
#>
  $g=Get-ADGroup -Identity 'Pre-Windows 2000 Compatible Access'
  $m=Get-ADGroupMember $g -Recursive -ErrorAction SilentlyContinue
  foreach($u in $m){ Write-Warning "[FAILURE] 'Pre-Windows 2000 Compatible Access' contains member: $($u.SamAccountName)" }
  if(($m | Measure-Object).Count -eq 0){ Write-Warning "[PASS] 'Pre-Windows 2000 Compatible Access' group has no members" }
}


function HealthTest-TrustsVerify{
<#
Description: Verifies Active Directory trusts and reports any trust validation failures.
AppliesTo: DC
Scope: Forest
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: netdom.exe, Get-ADTrust, dcdiag.exe.
#>
  $trusts=Get-ADTrust -Filter * -ErrorAction Stop
  if(-not $trusts){ Write-Warning "[PASS] No inter-domain trusts configured"; return }
  $bad=$false
  foreach($t in $trusts){
    $r=& netdom.exe trust $t.TargetName /domain:$($t.Source) /verify 2>&1
    if($LASTEXITCODE -ne 0){ $bad=$true; Write-Warning "[FAILURE] Trust verification failed`n$($t.Source) -> $($t.TargetName): $r" }
  }
  if(-not $bad){ Write-Warning "[PASS] All domain trusts verify successfully" }
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

function HealthTest-AdminSDHolderCoverage{
<#
Description: Reports whether AdminSDHolder protection is currently applied to any users.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-ADUser.
#>
  $prot=Get-ADUser -LDAPFilter '(adminCount=1)' -Properties MemberOf | Select-Object -ExpandProperty SamAccountName
  if($prot){ Write-Warning "[PASS] AdminSDHolder applied; protected users: $($prot -join ", ")" } else { Write-Warning "[PASS] No users currently protected by AdminSDHolder" }
}

function HealthTest-DisabledGpoLinksAtDomainRoot{
<#
Description: Checks for disabled or non-enforced GPO links at the domain root.
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: Get-Command, Get-GPO, Get-ADDomain.
#>

  if(-not (Get-Command Get-GPO -ErrorAction SilentlyContinue)){
    Write-Warning "[WARNING] GroupPolicy cmdlets not available; install RSAT/GPMC (GroupPolicy module)."; return
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
      Write-Warning "[WARNING] Cannot resolve domain root DN (need AD or machine joined to a domain)."; return
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
      Write-Warning "[WARNING] Failed to parse GPO report; skipping GPO: $($g.DisplayName) ($($g.Id)) - $msg"
    }
  }

  if($parseFailures -gt 0){
    Write-Warning "[WARNING] One or more GPO reports could not be read/parsed ($parseFailures). Results may be incomplete."}

  if(-not $links){
    Write-Warning "[PASS] No GPO links found at the domain root ($root)."; return
  }

  $flagged=$false
  foreach($l in $links){
    if($l.Enabled -eq 0){ $flagged=$true; Write-Warning "[WARNING] Domain-root GPO link is disabled: $($l.DisplayName)"}
    if($l.Enforced -eq 0){ $flagged=$true; Write-Warning "[WARNING] Domain-root GPO link is not enforced: $($l.DisplayName)"}
  }

  if(-not $flagged){ Write-Warning "[PASS] All domain-root GPO links are enabled (and enforced per policy)"}
  else{ Write-Warning "[FAILURE] There are disabled or non-enforced GPO links at the domain root"}
}

function HealthTest-KrbtgtAge{
<#
Description: Checks whether the KRBTGT password has been rotated within the allowed age threshold.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-ADUser.
#>
  [CmdletBinding()] param([int]$MaxDays=720)
  $u=Get-ADUser krbtgt -Properties pwdLastSet
  $ageDays=[int]((Get-Date) - [DateTime]::FromFileTime($u.pwdLastSet)).TotalDays
  if($ageDays -le $MaxDays){
    Write-Warning "[PASS] krbtgt password age acceptable ($ageDays days <= $MaxDays)"
  } else {
    Write-Warning "[FAILURE] krbtgt password age exceeds threshold ($MaxDays)`nThe KRBTGT account key hasn't been rotated for $ageDays days. Windows keeps the previous KRBTGT key to validate existing TGTs; never rotating extends the attack window. Risk: if an attacker ever accessed the KRBTGT key, they can mint TGTs and persist. Rotating twice (with replication time in between) is the standard mitigation."
  }
}

function HealthTest-SysvolContentConsistency{
<#
Description: Checks whether SYSVOL policy content is present and consistent across domain controllers.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: Get-ADDomainController.
#>

    $dom=(Get-CimInstance Win32_ComputerSystem).Domain
    $dcs=Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName

    $sigs = foreach($dc in $dcs){
      $p="\\$dc\SYSVOL\$dom\Policies"
      if(-not (Test-Path -LiteralPath $p)){
        Write-Warning "[FAILURE] SYSVOL Policies path missing on ${dc}: $p"
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

    if($allSame) {
      Write-Warning "[PASS] SYSVOL policy tree manifests match across all DCs"
    } elseif($hasMissing) {
      Write-Warning "[FAILURE] At least one DC lacks SYSVOL\Policies`n$map"
    } else {
      Write-Warning "[FAILURE] SYSVOL policy manifests are not consistent across DCs`n$map"
    }
}

function HealthTest-SysvolNetlogonAccessible{
<#
Description: Checks whether each domain controller exposes reachable SYSVOL and NETLOGON shares.
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Resolve-DnsName.
#>
    $dcs = Get-DomainControllers
    $bad = @()
    foreach($dc in $dcs){
      $ok1 = Test-Path "\\$dc\SYSVOL"
      if (!$ok1) {Write-Warning "[FAILURE] '\\$dc\SYSVOL' not reachable"}
      $ok2 = Test-Path "\\$dc\NETLOGON"
      if (!$ok2) {Write-Warning "[FAILURE] '\\$dc\NETLOGON' not reachable"}
      if(-not($ok1 -and $ok2)){ $bad += $dc.HostName }
    }
    $pass = ($bad.Count -eq 0)
    if($pass){Write-Warning "[PASS] All DCs have reachable SYSVOL & NETLOGON"}
}

function HealthTest-UnusedEnabledAdapters{
<#
Description: Checks for enabled network adapters that are disconnected and likely unused.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: Get-NetAdapter.
#>
  $nics=Get-NetAdapter | Where-Object {$_.AdminStatus -eq 'Up' -and $_.Status -ne 'Up'}
  foreach($n in $nics){ Write-Warning "[WARNING] Enabled network adapter is disconnected: $($n.Name) ($($n.Status))" }
  if(($nics | Measure-Object).Count -eq 0){ Write-Warning "[PASS] No enabled-but-disconnected network adapters detected" } else { Write-Warning "[FAILURE] There are enabled-but-disconnected network adapters present" }
}

#--------------------------------------------------------
# Moved domain and AD governance checks from other categories

function HealthTest-SchemaVersionConsistency{
<#
Description: Checks whether all domain controllers report the same AD schema version.
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-ADRootDSE, Get-ADDomainController, Get-ADObject.
#>
  $schemaNC=(Get-ADRootDSE).schemaNamingContext
  $vers=@{}; $errs=@()
  foreach($dc in (Get-ADDomainController -Filter *)){
    try{
      $ov=(Get-ADObject -Identity $schemaNC -Server $dc.HostName -Properties objectVersion -ErrorAction Stop).objectVersion
      if($null -eq $ov -or "$ov" -eq ''){
        $msg="$($dc.HostName): objectVersion missing"; $errs+=$msg; Write-Warning "[FAILURE] $msg"; continue
      }
      $ov=[int]("$ov".Trim()); $vers[$dc.HostName]=$ov
    }catch{
      $msg="$($dc.HostName): $($_.Exception.Message)"; $errs+=$msg; Write-Warning "[FAILURE] $msg"
    }
  }

  if($vers.Count -eq 0){
    Write-Warning ("[FAILURE] AD schema version consistency`nNo schema versions retrieved. Errors: " + ($errs -join ' | '))
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
    Write-Warning "[PASS] AD schema version consistent across DCs ($det)"
  } else {
    Write-Warning "[FAILURE] AD schema version consistent across DCs`n$det"
  }
}

function HealthTest-TombstoneLifetime{
<#
Description: Checks whether the AD tombstoneLifetime meets the minimum baseline.
AppliesTo: DC
Scope: Forest
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: Get-ADRootDSE, Get-ADObject.
#>
  [CmdletBinding()] param([int]$MinDays=60)
  $ds="CN=Directory Service,CN=Windows NT,CN=Services,$((Get-ADRootDSE).ConfigurationNamingContext)"
  $tl=(Get-ADObject $ds -Properties tombstoneLifetime).tombstoneLifetime
  if(-not $tl){$tl=60}
  if($tl -ge $MinDays){ Write-Warning "[PASS] AD tombstoneLifetime is sufficient ($tl days >= $MinDays)" }
  else{ Write-Warning "[FAILURE] AD tombstoneLifetime below threshold`nCurrent=$tl; Min=$MinDays" }
}

function HealthTest-RecycleBinEnabled{
<#
Description: Checks whether Active Directory Recycle Bin is enabled.
AppliesTo: DC
Scope: Forest
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: Get-ADOptionalFeature.
#>
  $f=Get-ADOptionalFeature 'Recycle Bin Feature' -ErrorAction Stop
  $enabled=($f.EnabledScopes -ne $null -and $f.EnabledScopes.Count -gt 0)
  if($enabled){ Write-Warning "[PASS] AD Recycle Bin enabled" } else { Write-Warning "[NOTICE] AD Recycle Bin is not enabled -- consider enabling it." }
}

function HealthTest-ReplicationLatency {
<#
Description: Assesses AD replication latency and correlates it with replication trouble signals.
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-ADRootDSE, Get-ADDomainController, Get-ADReplicationPartnerMetadata.
#>
  [CmdletBinding()]
  param(
    [int]$NoticeMinutes = 30,
    [int]$WarnMinutes   = 120,
    [int]$FailMinutes   = 240
  )

  $rootDse = Get-ADRootDSE -ErrorAction Stop
  $parts = @(
    $rootDse.schemaNamingContext,
    $rootDse.configurationNamingContext
  )

  $hadFailure = $false
  $hadWarning = $false
  $hadNotice  = $false

  foreach ($dc in (Get-ADDomainController -Filter *)) {
    foreach ($p in $parts) {
      $rows = @(Get-ADReplicationPartnerMetadata -Target $dc.HostName -Partition $p -ErrorAction SilentlyContinue)

      foreach ($row in $rows) {
        if (-not $row.LastReplicationSuccess) { continue }

        $mins = [int](((Get-Date) - $row.LastReplicationSuccess).TotalMinutes)
        $hasTrouble = (($row.LastReplicationResult -ne 0) -or ($row.ConsecutiveReplicationFailures -gt 0))

        $details =
          "`nDC: $($dc.HostName)" +
          "`nPartition: $p" +
          "`nPartner: $($row.Partner)" +
          "`nLatency: $mins min" +
          "`nLastReplicationSuccess: $($row.LastReplicationSuccess)" +
          "`nLastReplicationResult: $($row.LastReplicationResult)" +
          "`nConsecutiveReplicationFailures: $($row.ConsecutiveReplicationFailures)"

        if ($mins -ge $FailMinutes -and $hasTrouble) {
          $hadFailure = $true
          Write-Warning "[FAILURE] Replication latency is very high and replication trouble signals are present.$details"
          continue
        }

        if ($mins -ge $NoticeMinutes -and $hasTrouble) {
          $hadWarning = $true
          Write-Warning "[WARNING] Replication latency is elevated and replication trouble signals are present.$details"
          continue
        }

        if ($mins -ge $WarnMinutes) {
          $hadNotice = $true
          Write-Warning "[NOTICE] Replication latency is elevated, but current partner metadata shows no failures.$details"
        }
      }
    }
  }

  if (-not ($hadFailure -or $hadWarning -or $hadNotice)) {
    Write-Warning "[PASS] AD replication latency looks acceptable. No elevated schema/config latency with corroborating trouble signals was found."
  }
}


function HealthTest-NtdsLogVolumeFree{
<#
Description: Checks whether the NTDS log volume has enough free space.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Disk)
Uses: None.
#>
  [CmdletBinding()] param([int]$MinFreeGB=5)
  $p='HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
  $logPath=(Get-ItemProperty $p -Name 'Database log files path').'Database log files path'
  $drive=(Get-Item $logPath).PSDrive.Name+':'
  $d=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive'"
  $freeGB=[math]::Round($d.FreeSpace/1GB,2)
  if($freeGB -ge $MinFreeGB){
    Write-Warning "[PASS] NTDS log volume free space OK ($freeGB GB >= $MinFreeGB GB)"
  } else {
    Write-Warning (
      "[FAILURE] " +
      "NTDS log volume low free space ($freeGB GB < $MinFreeGB GB)" +
      "`n" +
      "Log path: $logPath"
    )
  }
}


function HealthTest-NtdsPathsLocation{
<#
Description: Checks whether the NTDS database and log paths are on expected volumes.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: None.
#>
  [CmdletBinding()]
  param(
    [string[]]$ExpectedDbRoots,
    [string[]]$ExpectedLogRoots
  )
  $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
  $db = (Get-ItemProperty -Path $regPath -Name 'DSA Database file' -ErrorAction Stop).'DSA Database file'
  $lg = (Get-ItemProperty -Path $regPath -Name 'Database log files path' -ErrorAction Stop).'Database log files path'

  $dbOk = if($ExpectedDbRoots -and $ExpectedDbRoots.Count){
    ($ExpectedDbRoots | Where-Object { $db -like "$($_)*" -or ([IO.Path]::GetPathRoot($db) -eq $_) }).Count -gt 0
  } else { $true }
  if(-not $dbOk){ Write-Warning "[FAILURE] NTDS database path not on an expected volume`nDB=$db; Expected roots: $($ExpectedDbRoots -join ', ')" }

  $lgOk = if($ExpectedLogRoots -and $ExpectedLogRoots.Count){
    ($ExpectedLogRoots | Where-Object { $lg -like "$($_)*" -or ([IO.Path]::GetPathRoot($lg) -eq $_) }).Count -gt 0
  } else { $true }
  if(-not $lgOk){ Write-Warning "[FAILURE] NTDS log path not on an expected volume`nLOGS=$lg; Expected roots: $($ExpectedLogRoots -join ', ')" }

  if($dbOk -and $lgOk){ Write-Warning "[PASS] NTDS database/log paths sane (DB=$db; LOGS=$lg)" }
}


function HealthTest-ServiceAccountsPwdNeverExpires{
<#
Description: Checks for service accounts whose passwords are set to never expire.
AppliesTo: DC
Scope: Domain
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-ADUser.
#>
  $filter='(servicePrincipalName=*)'
  $objs=Get-ADUser -LDAPFilter $filter -Properties PasswordNeverExpires,PasswordLastSet
  $bad=@($objs | Where-Object {$_.PasswordNeverExpires -eq $true})
  if($bad.Count -gt 0){
    foreach($u in $bad){ Write-Warning "[FAILURE] Service account password set to never expire`n$($u.SamAccountName)" }
  } else {
    Write-Warning "[PASS] Service accounts have expiring passwords"
  }
}


# TODO this test is repeated in HealthTest-ShareReasonableness

function HealthTest-UnconstrainedDelegationAccounts{
<#
Description: Checks for accounts that are configured for unconstrained delegation.
AppliesTo: DC
Scope: Domain
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-ADObject.
#>
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

      Write-Warning "[FAILURE] Unconstrained delegation account found`n${cls}: $name"
    }

  } else {
    Write-Warning "[PASS] No unconstrained delegation accounts"
  }
}


function HealthTest-GcPlacement{
<#
Description: Checks whether each AD site has a Global Catalog and the domain has at least one GC.
AppliesTo: DC
Scope: Forest
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: Get-ADDomainController.
#>
  [CmdletBinding()] param([switch]$AtLeastOnePerSite=$true)
  $dcs=Get-ADDomainController -Filter *
  if(-not $AtLeastOnePerSite){
    $has=($dcs | Where-Object {$_.IsGlobalCatalog}).Count -gt 0
    if($has){ Write-Warning "[PASS] At least one Global Catalog exists in the domain" } else { Write-Warning "[FAILURE] No Global Catalog server detected in the domain" }
    return
  }
  $sites=$dcs | Group-Object Site
  $bad=@()
  foreach($s in $sites){
    if(($s.Group | Where-Object {$_.IsGlobalCatalog}).Count -eq 0){ $bad+=$s.Name; Write-Warning "[FAILURE] No Global Catalog in site '$($s.Name)'" }
  }
  if($bad.Count -eq 0){ Write-Warning "[PASS] Each AD site has at least one Global Catalog" }
}


function HealthTest-DuplicateSpn{
<#
Description: Checks for duplicate Service Principal Names in Active Directory.
AppliesTo: DC
Scope: Forest
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: Get-ADObject.
#>
  $objs = Get-ADObject -LDAPFilter "(servicePrincipalName=*)" -Properties servicePrincipalName,sAMAccountName,distinguishedName -ErrorAction Stop
  if(-not $objs){ Write-Warning "[PASS] No objects with SPN found"; return }

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
      Write-Warning ("[FAILURE] Duplicate SPN detected`n$spn -> " + ($owners -join ', '))
    }
  }
  if(-not $dupsFound){ Write-Warning "[PASS] No duplicate SPNs detected" }
}


function HealthTest-ADReplicationHealth {
<#
Description: Uses repadmin and local RSAT cross-checks to detect AD replication failures and stale replication.
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: repadmin.exe, Get-MaxTimeSpan, Invoke-LocalRsatCrossCheck.
#>
  [CmdletBinding()]
  param(
    [TimeSpan]$WarnLargestDelta = ([TimeSpan]::FromHours(1)),
    [TimeSpan]$FailLargestDelta = ([TimeSpan]::FromHours(4))
  )

  $domainRole = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).DomainRole
  $isHostDC = ($domainRole -in 4,5)
  if (-not $isHostDC) { return }

  function Convert-RepadminDeltaToTimeSpan {
    param([string]$Text)

    if (-not $Text) { return $null }
    $t = $Text.Trim()

    $m = [regex]::Match($t, '^(?:(?<d>\d+)d:)?(?:(?<h>\d+)h:)?(?<m>\d+)m:(?<s>\d+)s$')
    if ($m.Success) {
      $days    = if ($m.Groups['d'].Success) { [int]$m.Groups['d'].Value } else { 0 }
      $hours   = if ($m.Groups['h'].Success) { [int]$m.Groups['h'].Value } else { 0 }
      $minutes = [int]$m.Groups['m'].Value
      $seconds = [int]$m.Groups['s'].Value
      return (New-TimeSpan -Days $days -Hours $hours -Minutes $minutes -Seconds $seconds)
    }

    $m = [regex]::Match($t, '^(?<s>\d+)s$')
    if ($m.Success) {
      return (New-TimeSpan -Seconds ([int]$m.Groups['s'].Value))
    }

    return $null
  }

  function Get-MaxTimeSpan {
    param([System.Collections.IEnumerable]$Values)

    $max = $null
    foreach ($v in $Values) {
      if ($null -eq $v) { continue }
      if ($null -eq $max -or $v -gt $max) { $max = $v }
    }
    $max
  }

  function Invoke-LocalRsatCrossCheck {
    param([string]$LocalHostName)

    $result = [ordered]@{
      Executed      = $false
      Passed        = $false
      FailedCount   = 0
      FailureText   = $null
      SummaryText   = $null
    }

    if (-not $LocalHostName) { return [pscustomobject]$result }

    $result.Executed = $true

    try {
      $md = Get-ADReplicationPartnerMetadata -Target $LocalHostName -ErrorAction Stop
    } catch {
      $result.FailedCount = 1
      $result.FailureText = "[WARNING] Local RSAT replication cross-check could not query partner metadata for $LocalHostName.`n$($_.Exception.Message)"
      return [pscustomobject]$result
    }

    if (-not $md) {
      $result.FailedCount = 1
      $result.FailureText = "[WARNING] Local RSAT replication cross-check returned no partner metadata for $LocalHostName."
      return [pscustomobject]$result
    }

    $bad = @($md | Where-Object { $_.LastReplicationResult -ne 0 })
    if ($bad.Count -gt 0) {
      $details = $bad | ForEach-Object {
        "$($_.Partner) rc=$($_.LastReplicationResult) lastSuccess=$($_.LastReplicationSuccess)"
      }
      $result.FailedCount = $bad.Count
      $result.FailureText = "[FAILURE] Local RSAT replication cross-check found partner errors for $LocalHostName.`n$($details -join ' | ')"
      return [pscustomobject]$result
    }

    $result.Passed = $true
    $result.SummaryText = "[PASS] Local RSAT replication cross-check found no partner errors for $LocalHostName."
    return [pscustomobject]$result
  }

  $localDc = $null
  $localHostName = $env:COMPUTERNAME
  try {
    $localDc = Get-ADDomainController -Identity $env:COMPUTERNAME -ErrorAction Stop
    if ($localDc -and $localDc.HostName) { $localHostName = $localDc.HostName }
  } catch {
  }

  $repadminCmd = Get-Command repadmin.exe -ErrorAction SilentlyContinue
  $repadmin = if ($repadminCmd -and $repadminCmd.Source) { $repadminCmd.Source } else { "$env:windir\system32\repadmin.exe" }

  $ok = $true
  $repadminAvailable = (Test-Path -LiteralPath $repadmin)
  $rsatCheck = Invoke-LocalRsatCrossCheck -LocalHostName $localHostName

  if (-not $repadminAvailable) {
    Write-Warning "[WARNING] repadmin.exe not found.`nDomain-wide AD replication checks were skipped; using local RSAT replication cross-check only."

    if ($rsatCheck.Executed) {
      if ($rsatCheck.FailedCount -gt 0) {
        Write-Warning $rsatCheck.FailureText
      } elseif ($rsatCheck.Passed) {
        Write-Warning $rsatCheck.SummaryText
      }
    } else {
      Write-Warning "[FAILURE] Neither repadmin.exe nor local RSAT replication cross-check data were available."
    }

    return
  }

  try {
    $sumOut = (& $repadmin /replsummary 2>&1 | Out-String)
  } catch {
    Write-Warning "[FAILURE] repadmin /replsummary could not be executed.`n$($_.Exception.Message)"

    if ($rsatCheck.Executed) {
      if ($rsatCheck.FailedCount -gt 0) {
        Write-Warning $rsatCheck.FailureText
      } elseif ($rsatCheck.Passed) {
        Write-Warning $rsatCheck.SummaryText
      }
    }

    return
  }

  if (-not $sumOut) {
    Write-Warning "[FAILURE] repadmin /replsummary returned no output."
    $ok = $false
  } else {
    $rows = @()
    foreach ($ln in ($sumOut -split '\r?\n')) {
      if ($ln -match '^\s*(?<DSA>\S+)\s+(?<Delta>(?:\d+d:)?(?:\d+h:)?\d+m:\d+s|\d+s)\s+(?<Fails>\d+)\s*/\s*(?<Total>\d+)\s+(?<Pct>\d+)\b') {
        $rows += [pscustomobject]@{
          DSA       = $Matches.DSA
          DeltaText = $Matches.Delta
          Delta     = Convert-RepadminDeltaToTimeSpan $Matches.Delta
          Fails     = [int]$Matches.Fails
          Total     = [int]$Matches.Total
          Percent   = [int]$Matches.Pct
        }
      }
    }

    if ($rows.Count -eq 0) {
      Write-Warning "[FAILURE] repadmin /replsummary output could not be parsed.`nRun repadmin /replsummary manually and inspect the output."
      $ok = $false
    } else {
      $badFails = @($rows | Where-Object { $_.Fails -gt 0 })
      foreach ($b in $badFails) {
        Write-Warning (
          "[FAILURE] Replication failures reported for DSA $($b.DSA)" +
          "`nFails: $($b.Fails) / $($b.Total)" +
          "`nLargest delta: $($b.DeltaText)" +
          "`nError percentage: $($b.Percent)%"
        )
      }
      if ($badFails.Count -gt 0) { $ok = $false }

      $badDeltaFail = @($rows | Where-Object { $null -ne $_.Delta -and $_.Delta -ge $FailLargestDelta })
      foreach ($b in $badDeltaFail) {
        Write-Warning (
          "[FAILURE] Replication largest delta too high for DSA $($b.DSA)" +
          "`nLargest delta: $($b.DeltaText)" +
          "`nFail threshold: $($FailLargestDelta.ToString())" +
          "`nFails: $($b.Fails) / $($b.Total)"
        )
      }
      if ($badDeltaFail.Count -gt 0) { $ok = $false }

      $badDeltaWarn = @(
        $rows |
        Where-Object {
          $null -ne $_.Delta -and
          $_.Delta -ge $WarnLargestDelta -and
          $_.Delta -lt $FailLargestDelta
        }
      )
      foreach ($b in $badDeltaWarn) {
        Write-Warning (
          "[WARNING] Replication largest delta elevated for DSA $($b.DSA)" +
          "`nLargest delta: $($b.DeltaText)" +
          "`nWarning threshold: $($WarnLargestDelta.ToString())" +
          "`nFail threshold: $($FailLargestDelta.ToString())" +
          "`nFails: $($b.Fails) / $($b.Total)"
        )
      }

      if ($badFails.Count -eq 0 -and $badDeltaFail.Count -eq 0) {
        $maxDelta = Get-MaxTimeSpan ($rows | Select-Object -ExpandProperty Delta)
        $maxDeltaText = if ($null -ne $maxDelta) { $maxDelta.ToString() } else { 'unknown' }
        Write-Warning "[PASS] repadmin /replsummary found no replication failures.`nLargest parsed delta: $maxDeltaText"
      }
    }
  }

  try {
    $showOut = (& $repadmin /showrepl * 2>&1 | Out-String)
  } catch {
    Write-Warning "[FAILURE] repadmin /showrepl * could not be executed.`n$($_.Exception.Message)"

    if ($rsatCheck.Executed) {
      if ($rsatCheck.FailedCount -gt 0) {
        Write-Warning $rsatCheck.FailureText
      } elseif ($rsatCheck.Passed) {
        Write-Warning $rsatCheck.SummaryText
      }
    }

    return
  }

  if (-not $showOut) {
    Write-Warning "[FAILURE] repadmin /showrepl * returned no output."
    $ok = $false
  } else {
    $lines = @($showOut -split '\r?\n')
    $currentDc = $null
    $currentNc = $null
    $currentVia = $null
    $attempts = @()

    foreach ($ln in $lines) {
      if ($ln -match '^Repadmin:\s+running command /showrepl against full DC\s+(?<dc>\S+)') {
        $currentDc = $Matches.dc
        $currentNc = $null
        $currentVia = $null
        continue
      }

      if ($ln -match '^\s*([A-Z]{2}=|CN=).+$') {
        $currentNc = $ln.Trim()
        $currentVia = $null
        continue
      }

      if ($ln -match '^\s+(?<partner>\S+)\s+via\s+(?<transport>\S+)\s*$') {
        $currentVia = $ln.Trim()
        continue
      }

      if ($ln -match 'Last attempt @') {
        $attempts += [pscustomobject]@{
          DC          = $currentDc
          NamingCtx   = $currentNc
          Neighbor    = $currentVia
          AttemptLine = $ln.Trim()
          Successful  = ($ln -match 'was successful\.$')
        }
      }
    }

    if ($attempts.Count -eq 0) {
      Write-Warning "[WARNING] repadmin /showrepl * produced no last-attempt lines.`nRun repadmin /showrepl * manually and inspect the output."
      $ok = $false
    } else {
      $notOk = @($attempts | Where-Object { -not $_.Successful })
      foreach ($a in $notOk) {
        Write-Warning (
          "[FAILURE] Replication last attempt was unsuccessful" +
          "`nDC: $($a.DC)" +
          "`nNaming context: $($a.NamingCtx)" +
          "`nNeighbor: $($a.Neighbor)" +
          "`n$($a.AttemptLine)"
        )
      }

      if ($notOk.Count -gt 0) {
        $ok = $false
      } else {
        $dcCount = (@($attempts | Select-Object -ExpandProperty DC -Unique) | Measure-Object).Count
        Write-Warning (
          "[PASS] repadmin /showrepl * found all last attempts successful" +
          "`nChecked $($attempts.Count) inbound neighbor attempt line(s)" +
          "`nAcross $dcCount DC(s)"
        )
      }
    }
  }

  if ($rsatCheck.Executed) {
    if ($rsatCheck.FailedCount -gt 0) {
      Write-Warning $rsatCheck.FailureText
      $ok = $false
    } elseif ($rsatCheck.Passed) {
      Write-Warning $rsatCheck.SummaryText
    }
  }

}
