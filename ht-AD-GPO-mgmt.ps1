<#
Active Directory & GPO Management
#>

# The functions below are only defined if computer is a DC/PDC
if ((Get-CimInstance Win32_ComputerSystem).DomainRole -in 4,5) {

function HealthTest-ADViewConsistency {
<#
.SYNOPSIS
Checks AD View Consistency

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-ADDomain, Get-ADDomainController, Get-ADForest.
FalsePositives: None.
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
<#
.SYNOPSIS
Checks Dcdiag

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Availability / Server Down Signals
Impact: High(Time)
Uses: Write-Progress.
FalsePositives: None.
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
<#
.SYNOPSIS
Checks Rid Manager

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Select-String.
FalsePositives: None.
#>
  $out=& dcdiag /test:ridmanager /v 2>&1
  $fail=($out | Select-String -Pattern 'failed test RidManager','is low' -SimpleMatch)
  if($fail){ Write-Warning "[failure] RID Manager test reported issues`nReview dcdiag /test:ridmanager output"; } else { Write-Warning "[pass] RID Manager health OK (dcdiag)" }
}

function HealthTest-DfsrBacklogSysvol{
<#
.SYNOPSIS
Checks Dfsr Backlog Sysvol

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: Get-ADDomainController, Get-DfsrBacklog.
FalsePositives: None.
#>
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
<#
.SYNOPSIS
Checks Dfs Replication State

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: Get-CimInstance.
FalsePositives: None.
#>
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
<#
.SYNOPSIS
Checks Dfsr Backlog

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: Get-DfsrBacklog, Install-WindowsFeature, Get-DfsrConnection.
FalsePositives: None.
#>
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

function HealthTest-GpoVersionConsistency{
<#
.SYNOPSIS
Checks Gpo Version Consistency

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-GPO.
FalsePositives: None.
#>
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
<#
.SYNOPSIS
Checks Kcc Connectivity

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Availability / Server Down Signals
Impact: Medium(Network)
Uses: Get-ADDomainController, Get-ADReplicationPartnerMetadata, Get-ADObject.
FalsePositives: None.
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
<#
.SYNOPSIS
Checks Kerberos Encryption Types

.DESCRIPTION
AppliesTo: DC
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-ADObject.
FalsePositives: None.
#>
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

function HealthTest-RodcPrp{
<#
.SYNOPSIS
Checks Rodc Prp

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-ADDomainController, Get-ADObject.
FalsePositives: None.
#>
  $rodcs=Get-ADDomainController -Filter {IsReadOnly -eq $true}
  if(-not $rodcs){ Write-Warning "[pass] No RODCs found (PRP not applicable)"; return }
  $bad=$false
  foreach($r in $rodcs){
    $ro=Get-ADObject $r.NTDSSettingsObjectDN -Properties msDS-RevealOnDemandGroup,msDS-NeverRevealGroup
    if(-not $ro.'msDS-RevealOnDemandGroup' -and -not $ro.'msDS-NeverRevealGroup'){ $bad=$true; Write-Warning "[failure] RODC PRP not configured on $($r.HostName)" }
  }
  if(-not $bad){ Write-Warning "[pass] PRP is configured on all RODCs" }
}
function HealthTest-SysvolAclHygiene{
<#
.SYNOPSIS
Checks Sysvol Acl Hygiene

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-Acl.
FalsePositives: None.
#>
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

function HealthTest-DfsDiagTestDCs {
<#
.SYNOPSIS
Checks Dfs Diag Test D Cs

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Write-Progress.
FalsePositives: None.
#>
    write-progress "Runing 'DFSDIAG /TestDCs'"
    $out=(DFSDIAG /TestDCs | sls -NotMatch '^$|^(Information|[A-Za-z]+ing|Success)[ :]|^Finished TestDcs[.] *$')
    if ($out) {
        Write-Warning "[failure] 'DFSDIAG /TestDCs' output does not seem clean`nIf the following lines I was not expecting indicate problems, run DFSDIAG /TestDCs to view the whole output:`n$out"
        return
    }
    Write-Warning "[pass] 'DFSDIAG /TestDCs' returned expected output"
}

function HealthTest-DfsNamespaceEnumerate{
<#
.SYNOPSIS
Checks Dfs Namespace Enumerate

.DESCRIPTION
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-DfsnRoot, Get-DfsnFolder.
FalsePositives: None.
#>
  $roots=Get-DfsnRoot -ErrorAction SilentlyContinue
  if(-not $roots){ Write-Warning "[pass] No DFS Namespace roots found (nothing to check)"; return }
  $count=0
  foreach($r in $roots){ $count += (Get-DfsnFolder -Path $r.Path -ErrorAction SilentlyContinue | Measure-Object).Count }
  Write-Warning "[pass] DFSN roots/folders enumerate: Roots=$($roots.Count); Folders=$count"
}


function HealthTest-PreWin2000Group{
<#
.SYNOPSIS
Checks Pre Win 2000 Group

.DESCRIPTION
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-ADGroup, Get-ADGroupMember.
FalsePositives: None.
#>
  $g=Get-ADGroup -Identity 'Pre-Windows 2000 Compatible Access'
  $m=Get-ADGroupMember $g -Recursive -ErrorAction SilentlyContinue
  foreach($u in $m){ Write-Warning "[failure] 'Pre-Windows 2000 Compatible Access' contains member: $($u.SamAccountName)" }
  if(($m | Measure-Object).Count -eq 0){ Write-Warning "[pass] 'Pre-Windows 2000 Compatible Access' group has no members" }
}


function HealthTest-TrustsVerify{
<#
.SYNOPSIS
Checks Trusts Verify

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: netdom.exe, Get-ADTrust.
FalsePositives: None.
#>
  $trusts=Get-ADTrust -Filter * -ErrorAction Stop
  if(-not $trusts){ Write-Warning "[pass] No inter-domain trusts configured"; return }
  $bad=$false
  foreach($t in $trusts){
    $r=& netdom.exe trust $t.TargetName /domain:$($t.Source) /verify 2>&1
    if($LASTEXITCODE -ne 0){ $bad=$true; Write-Warning "[failure] Trust verification failed`n$($t.Source) -> $($t.TargetName): $r" }
  }
  if(-not $bad){ Write-Warning "[pass] All domain trusts verify successfully" }
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
.SYNOPSIS
Checks Admin SD Holder Coverage

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-ADUser.
FalsePositives: None.
#>
  $prot=Get-ADUser -LDAPFilter '(adminCount=1)' -Properties MemberOf | Select-Object -ExpandProperty SamAccountName
  if($prot){ Write-Warning "[pass] AdminSDHolder applied; protected users: $($prot -join ", ")" } else { Write-Warning "[pass] No users currently protected by AdminSDHolder" }
}

function HealthTest-ADReplicationDomainRepadmin {
<#
.SYNOPSIS
Checks AD Replication Domain Repadmin

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: repadmin.exe.
FalsePositives: None.
#>
  [CmdletBinding()]
  param(
    [TimeSpan]$WarnLargestDelta = ([TimeSpan]::FromHours(1)),
    [TimeSpan]$FailLargestDelta = ([TimeSpan]::FromHours(4))
  )

  $domainRole = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).DomainRole
  $isHostDC = ($domainRole -in 4,5)
  if (-not $isHostDC) { return }

  $repadminCmd = Get-Command repadmin.exe -ErrorAction SilentlyContinue
  $repadmin = if ($repadminCmd -and $repadminCmd.Source) { $repadminCmd.Source } else { "$env:windir\system32\repadmin.exe" }

  if (-not (Test-Path -LiteralPath $repadmin)) {
    $synopsis = "repadmin.exe not found"
    $details = "`nCannot run domain-wide AD replication checks."
    Write-Warning "[failure] $synopsis$details"
    return
  }

  $ok = $true

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

  try {
    $sumOut = (& $repadmin /replsummary 2>&1 | Out-String)
  } catch {
    $synopsis = "repadmin /replsummary could not be executed"
    $details = "`n$($_.Exception.Message)"
    Write-Warning "[failure] $synopsis$details"
    return
  }

  if (-not $sumOut) {
    $synopsis = "repadmin /replsummary returned no output"
    $details = ""
    Write-Warning "[failure] $synopsis$details"
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
      $synopsis = "repadmin /replsummary output could not be parsed"
      $details = "`nRun repadmin /replsummary manually and inspect the output."
      Write-Warning "[failure] $synopsis$details"
      $ok = $false
    } else {
      $badFails = @($rows | Where-Object { $_.Fails -gt 0 })
      foreach ($b in $badFails) {
        $synopsis = "Replication failures reported for DSA $($b.DSA)"
        $details =
          "`nFails: $($b.Fails) / $($b.Total)" +
          "`nLargest delta: $($b.DeltaText)" +
          "`nError percentage: $($b.Percent)%"
        Write-Warning "[failure] $synopsis$details"
      }
      if ($badFails.Count -gt 0) { $ok = $false }

      $badDeltaFail = @($rows | Where-Object { $null -ne $_.Delta -and $_.Delta -ge $FailLargestDelta })
      foreach ($b in $badDeltaFail) {
        $synopsis = "Replication largest delta too high for DSA $($b.DSA)"
        $details =
          "`nLargest delta: $($b.DeltaText)" +
          "`nFail threshold: $($FailLargestDelta.ToString())" +
          "`nFails: $($b.Fails) / $($b.Total)"
        Write-Warning "[failure] $synopsis$details"
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
        $synopsis = "Replication largest delta elevated for DSA $($b.DSA)"
        $details =
          "`nLargest delta: $($b.DeltaText)" +
          "`nWarning threshold: $($WarnLargestDelta.ToString())" +
          "`nFail threshold: $($FailLargestDelta.ToString())" +
          "`nFails: $($b.Fails) / $($b.Total)"
        Write-Warning "[warning] $synopsis$details"
      }

      if ($badFails.Count -eq 0 -and $badDeltaFail.Count -eq 0) {
        $maxDelta = Get-MaxTimeSpan ($rows | Select-Object -ExpandProperty Delta)
        $maxDeltaText = if ($null -ne $maxDelta) { $maxDelta.ToString() } else { 'unknown' }
        $synopsis = "repadmin /replsummary found no replication failures"
        $details = "`nLargest parsed delta: $maxDeltaText"
        Write-Warning "[pass] $synopsis$details"
      }
    }
  }

  try {
    $showOut = (& $repadmin /showrepl * 2>&1 | Out-String)
  } catch {
    $synopsis = "repadmin /showrepl * could not be executed"
    $details = "`n$($_.Exception.Message)"
    Write-Warning "[failure] $synopsis$details"
    return
  }

  if (-not $showOut) {
    $synopsis = "repadmin /showrepl * returned no output"
    $details = ""
    Write-Warning "[failure] $synopsis$details"
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
      $synopsis = "repadmin /showrepl * produced no last-attempt lines"
      $details = "`nRun repadmin /showrepl * manually and inspect the output."
      Write-Warning "[warning] $synopsis$details"
      $ok = $false
    } else {
      $notOk = @($attempts | Where-Object { -not $_.Successful })
      foreach ($a in $notOk) {
        $synopsis = "Replication last attempt was unsuccessful"
        $details =
          "`nDC: $($a.DC)" +
          "`nNaming context: $($a.NamingCtx)" +
          "`nNeighbor: $($a.Neighbor)" +
          "`n$a.AttemptLine"
        Write-Warning "[failure] $synopsis$details"
      }
      if ($notOk.Count -gt 0) {
        $ok = $false
      } else {
        $dcCount = (@($attempts | Select-Object -ExpandProperty DC -Unique) | Measure-Object).Count
        $synopsis = "repadmin /showrepl * found all last attempts successful"
        $details =
          "`nChecked $($attempts.Count) inbound neighbor attempt line(s)" +
          "`nAcross $dcCount DC(s)"
        Write-Warning "[pass] $synopsis$details"
      }
    }
  }
}

function HealthTest-ADReplicationLocalRSAT {
<#
.SYNOPSIS
Checks AD Replication Local RSAT

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: Get-ADReplicationPartnerMetadata, Get-Module, Get-ADDomainController.
FalsePositives: None.
#>
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
    Write-Warning "[failure] AD replication (RSAT): ActiveDirectory module not available; cannot query replication partner metadata."; return
  }

  try {
    Import-Module ActiveDirectory -ErrorAction Stop
  } catch {
    Write-Warning "[failure] AD replication (RSAT): failed to import ActiveDirectory module.`n$($_.Exception.Message)"
    return
  }

  $me = $null
  try {
    $me = Get-ADDomainController -ErrorAction Stop
  } catch {
    Write-Warning "[failure] AD replication (RSAT): failed to identify local domain controller.`n$($_.Exception.Message)"
    return
  }

  if (-not $me -or -not $me.HostName) {
    Write-Warning "[failure] AD replication (RSAT): could not determine local DC hostname."; return
  }

  try {
    [void](Get-ADDomain -ErrorAction Stop)
  } catch {
    Write-Warning "[failure] AD replication (RSAT): cannot query domain info (ADWS/permissions/connectivity issue).`n$($_.Exception.Message)"
    return
  }

  $md = $null
  try {
    $md = Get-ADReplicationPartnerMetadata -Target $me.HostName -ErrorAction Stop
  } catch {
    Write-Warning "[failure] Exception from: Get-ADReplicationPartnerMetadata -Target $($me.HostName)`n$($_.Exception.Message)"
    return
  }

  if (-not $md) {
    Write-Warning "[failure] AD replication (RSAT): no partner metadata returned for $($me.HostName)."; return
  }

  $bad = @($md | Where-Object { $_.LastReplicationResult -ne 0 })
  if ($bad.Count -gt 0) {
    $details = $bad | ForEach-Object { "$($_.Partner) rc=$($_.LastReplicationResult) at $($_.LastSuccessfulSync)" }
    Write-Warning "[failure] AD replication (RSAT): replication partner errors for $($me.HostName).`n$($details -join ' | ')"
    return
  }

  Write-Warning "[pass] AD replication (RSAT): replication partner results healthy for $($me.HostName)."
}

function HealthTest-DisabledGpoLinksAtDomainRoot{
<#
.SYNOPSIS
Checks Disabled Gpo Links At Domain Root

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-GPO, Get-ADDomain, Get-GPOReport.
FalsePositives: None.
#>
  if(-not (Get-Command Get-GPO -ErrorAction SilentlyContinue)){
    Write-Warning "[warning] GroupPolicy cmdlets not available; install RSAT/GPMC (GroupPolicy module)."; return
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
      Write-Warning "[warning] Cannot resolve domain root DN (need AD or machine joined to a domain)."; return
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
    Write-Warning "[warning] One or more GPO reports could not be read/parsed ($parseFailures). Results may be incomplete."}

  if(-not $links){
    Write-Warning "[pass] No GPO links found at the domain root ($root)."; return
  }

  $flagged=$false
  foreach($l in $links){
    if($l.Enabled -eq 0){ $flagged=$true; Write-Warning "[warning] Domain-root GPO link is disabled: $($l.DisplayName)"}
    if($l.Enforced -eq 0){ $flagged=$true; Write-Warning "[warning] Domain-root GPO link is not enforced: $($l.DisplayName)"}
  }

  if(-not $flagged){ Write-Warning "[pass] All domain-root GPO links are enabled (and enforced per policy)"}
  else{ Write-Warning "[failure] There are disabled or non-enforced GPO links at the domain root"}
}

function HealthTest-KrbtgtAge{
<#
.SYNOPSIS
Checks Krbtgt Age

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-ADUser.
FalsePositives: None.
#>
  [CmdletBinding()] param([int]$MaxDays=720)
  $u=Get-ADUser krbtgt -Properties pwdLastSet
  $ageDays=[int]((Get-Date) - [DateTime]::FromFileTime($u.pwdLastSet)).TotalDays
  if($ageDays -le $MaxDays){
    Write-Warning "[pass] krbtgt password age acceptable ($ageDays days <= $MaxDays)"
  } else {
    Write-Warning "[failure] krbtgt password age exceeds threshold ($MaxDays)`nThe KRBTGT account key hasn't been rotated for $ageDays days. Windows keeps the previous KRBTGT key to validate existing TGTs; never rotating extends the attack window. Risk: if an attacker ever accessed the KRBTGT key, they can mint TGTs and persist. Rotating twice (with replication time in between) is the standard mitigation."
  }
}

function HealthTest-LocalAdminsBaseline {
<#
.SYNOPSIS
Checks Local Admins Baseline

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Audit / Compliance / Informational
Impact: Medium(Time)
Uses: New-Object.
FalsePositives: None.
#>
    param(
        [string[]]$Allowed = @(
            'BUILTIN\Administrators',
            'NT AUTHORITY\SYSTEM',
            'Domain Admins',
            'Enterprise Admins'
        )
    )

    $pass = $true

    $grp = [ADSI]"WinNT://$env:COMPUTERNAME/Administrators,group"
    $members = @(@($grp.psbase.Invoke('Members')) | ForEach-Object { [ADSI]$_ })
    $unexpected = @()

    foreach ($m in $members) {
        $name = $m.InvokeGet('Name')
        $path = [string]$m.Path

        $dom  = ''
        $acct = $name

        if ($path -match '^WinNT://([^/]+)/([^/,]+)(?:,.*)?$') {
            $dom  = $Matches[1]
            $acct = $Matches[2]
        }

        $full = if ($dom) { "$dom\$acct" } else { $acct }

        $isAllowed = $false
        # 1) Built-in Administrator: SID ends with -500
        try {
            $sidBytes = $m.InvokeGet('ObjectSid')
            if ($sidBytes) {
                $sid = New-Object System.Security.Principal.SecurityIdentifier($sidBytes, 0)
                if ($sid.Value -match '-500$') {
                    $isAllowed = $true
                }
            }
        } catch {
            # If SID lookup fails we just fall back to name-based checks
        }
        # 2) Name-based allow list (if not already allowed by SID)
        if (-not $isAllowed) {
            foreach ($a in $Allowed) {
                if ($full -ieq $a -or $full -like "*\$a") {
                    $isAllowed = $true
                    break
                }
            }
        }

        if (-not $isAllowed) {
            Write-Warning "[warning] Unexpected Local Administrator: $full"
            $pass = $false
        }
    }
    if ($pass) {
        Write-Warning "[pass] No unexpected accounts in Local Administrators"}
}

function HealthTest-SysvolContentConsistency{
<#
.SYNOPSIS
Checks Sysvol Content Consistency

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: Get-ADDomainController.
FalsePositives: None.
#>
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

    if($allSame) {
      Write-Warning "[pass] SYSVOL policy tree manifests match across all DCs"
    } elseif($hasMissing) {
      Write-Warning "[failure] At least one DC lacks SYSVOL\Policies`n$map"
    } else {
      Write-Warning "[failure] SYSVOL policy manifests are not consistent across DCs`n$map"
    }
}

function HealthTest-SysvolNetlogonAccessible{
<#
.SYNOPSIS
Checks Sysvol Netlogon Accessible

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Availability / Server Down Signals
Impact: Medium(Time)
Uses: None.
FalsePositives: None.
#>
    $dcs = Get-DomainControllers
    $bad = @()
    foreach($dc in $dcs){
      $ok1 = Test-Path "\\$dc\SYSVOL"
      if (!$ok1) {Write-Warning "[failure] '\\$dc\SYSVOL' not reachable"}
      $ok2 = Test-Path "\\$dc\NETLOGON"
      if (!$ok2) {Write-Warning "[failure] '\\$dc\NETLOGON' not reachable"}
      if(-not($ok1 -and $ok2)){ $bad += $dc.HostName }
    }
    $pass = ($bad.Count -eq 0)
    if($pass){Write-Warning "[pass] All DCs have reachable SYSVOL & NETLOGON"}
}

function HealthTest-UnexpectedListeningPorts {
<#
.SYNOPSIS
Checks Unexpected Listening Ports

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-NetTCPConnection.
FalsePositives: None.
#>
    [CmdletBinding()] param(
        [int[]]$AllowedPorts = @(53, 88, 123, 135, 139, 389, 445, 464, 636, 3268, 3269, 5722, 5985, 5986, 9389),
        [int[]]$OptionalNoticePorts = @(3389, 47001, 593),
        [int]$DynamicStart = 49152,
        [int]$DynamicEnd = 65535
    )
# From a brand new Lenovo:
#    FAILURE:[01d04124] Unexpected listening port: 7680 (Process: svchost)
#    FAILURE:[3d641d0f] Unexpected listening port: 5040 (Process: svchost)
#
#   From Intel ATM:
#       FAILURE:[5fbea54a] Unexpected listening port: 623 (Process: LMS)
#       FAILURE:[58582cc2] Unexpected listening port: 16992 (Process: LMS)

    $domainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole
    $isHostServer = ($domainRole  -in 3,4,5)

    # 1. Get all listening connections
    $AllListening = Get-NetTCPConnection -State Listen

    # 2. Filter out connections where the LocalAddress is *only* the localhost loopback (127.0.0.1 or ::1)
    $ExternalListening = $AllListening | Where-Object {
        $_.LocalAddress -ne '127.0.0.1' -and $_.LocalAddress -ne '::1'
    }

    # 3. Group the connections by port number. This ensures each port is checked only once.
    # This replaces the old method of selecting only the port number, so we retain the process ID.
    $listeningPortGroups = $ExternalListening | Group-Object -Property LocalPort

    $bad = $false
    # 4. Loop through each group of connections (one group per unique port).
    foreach ($portGroup in $listeningPortGroups) {
        $comment = ""
        $p = [int]$portGroup.Name # The port number is the 'Name' of the group

        if ($p -ge $DynamicStart -and $p -le $DynamicEnd) { continue } # ignore ephemeral
        if ($AllowedPorts -contains $p) { continue }

        # For optional and unexpected ports, we'll find the process name.
        # Get the Process ID from the first connection object in the group.
        $procID = $portGroup.Group[0].OwningProcess
        # Use the ID to get the process name. ErrorAction handles cases where the process might have just ended.
        $vendor="(failed to find)"
        if ($procID -eq 4) {
            $procDescr="Process=SYSTEM(PID=4)"
            $vendor="Microsoft Windows" # PID 4 is Microsoft Windows system process
        } else {
            $proc = (Get-Process -Id $procID -ErrorAction SilentlyContinue)
            if (-not $proc) {
                $procDescr = "PID $procID not found"
                $comment = "The process that was listening terminated before we had the chance to query it. That's unusual."
            } else {
                if ($proc.path) {$procPath=Resolve-ExecutablePath $proc.path} else {$procPath=Resolve-ExecutablePath $proc.ProcessName}
                try {$vendor=Get-ExeVendor $procPath} catch {}
                $procDescr="$($proc.ProcessName)"
                $comment = "Vendor: '$vendor'; Process Path: '$procPath'"
            }
        }

        if ($OptionalNoticePorts -contains $p) {
            # Added process name to the notice message for extra context.
            Write-Warning "[notice] Optional baseline port is listening: $p ($procDescr)"
            continue
        }

        $bad = $true

        if ($vendor.PSObject.Properties.Name -contains 'Vendor') {
            $vendorDescr=$vendor.Vendor
        } else {
            $vendorDescr=$vendor
        }

        # Display the unexpected port along with the listening process name.
        # If vendor is like "Microsoft Windows*" then level becomes "WARNING" for servers and "NOTICE" for workstations
        if ($vendorDescr -like "Microsoft Windows*") {
            if($isHostServer){
                Write-Warning ("[warning] Unexpected listening port: $p (Process: $procDescr, Vendor: $vendor)`n$comment")
            } else {
                Write-Warning ("[notice] Unexpected listening port: $p (Process: $procDescr, Vendor: $vendor)`n$comment")
            }
        } else {
            Write-Warning ("[failure] Unexpected listening port: $p (Process: $procDescr, Vendor: $vendor)`n$comment")
        }
    }

    if (-not $bad) { Write-Warning "[pass] Listening ports are within baseline"}
}

function HealthTest-UnusedEnabledAdapters{
<#
.SYNOPSIS
Checks Unused Enabled Adapters

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-NetAdapter.
FalsePositives: None.
#>
  $nics=Get-NetAdapter | Where-Object {$_.AdminStatus -eq 'Up' -and $_.Status -ne 'Up'}
  foreach($n in $nics){ Write-Warning "[warning] Enabled network adapter is disconnected: $($n.Name) ($($n.Status))" }
  if(($nics | Measure-Object).Count -eq 0){ Write-Warning "[pass] No enabled-but-disconnected network adapters detected" } else { Write-Warning "[failure] There are enabled-but-disconnected network adapters present" }
}

#--------------------------------------------------------
# Moved domain and AD governance checks from other categories

function HealthTest-SchemaVersionConsistency{
<#
.SYNOPSIS
Checks Schema Version Consistency

.DESCRIPTION
AppliesTo: DC
Scope: Forest
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-ADRootDSE, Get-ADDomainController, Get-ADObject.
FalsePositives: None.
#>
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

function HealthTest-TombstoneLifetime{
<#
.SYNOPSIS
Checks Tombstone Lifetime

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-ADRootDSE, Get-ADObject.
FalsePositives: None.
#>
  [CmdletBinding()] param([int]$MinDays=60)
  $ds="CN=Directory Service,CN=Windows NT,CN=Services,$((Get-ADRootDSE).ConfigurationNamingContext)"
  $tl=(Get-ADObject $ds -Properties tombstoneLifetime).tombstoneLifetime
  if(-not $tl){$tl=60}
  if($tl -ge $MinDays){ Write-Warning "[pass] AD tombstoneLifetime is sufficient ($tl days >= $MinDays)" }
  else{ Write-Warning "[failure] AD tombstoneLifetime below threshold`nCurrent=$tl; Min=$MinDays" }
}

function HealthTest-RecycleBinEnabled{
<#
.SYNOPSIS
Checks Recycle Bin Enabled

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-ADOptionalFeature.
FalsePositives: None.
#>
  $f=Get-ADOptionalFeature 'Recycle Bin Feature' -ErrorAction Stop
  $enabled=($f.EnabledScopes -ne $null -and $f.EnabledScopes.Count -gt 0)
  if($enabled){ Write-Warning "[pass] AD Recycle Bin enabled" } else { Write-Warning "[notice] AD Recycle Bin is not enabled -- consider enabling it." }
}

function HealthTest-ReplicationLatency{
<#
.SYNOPSIS
Checks Replication Latency

.DESCRIPTION
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: Get-ADRootDSE, Get-ADDomainController, Get-ADReplicationPartnerMetadata.
FalsePositives: None.
#>
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

} # computer is a DC/PDC