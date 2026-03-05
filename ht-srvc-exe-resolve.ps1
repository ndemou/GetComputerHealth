<#
Service & Executable Resolution
#>

# Win32 interop used by helper functions (documented APIs)
if (-not ('Win32SvcPath' -as [type])) {
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class Win32SvcPath {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern uint SearchPathW(string lpPath,string lpFileName,string lpExtension,uint nBufferLength,StringBuilder lpBuffer, IntPtr lpFilePart);

  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern uint ExpandEnvironmentStringsW(string lpSrc, StringBuilder lpDst, uint nSize);

  [DllImport("shell32.dll", CharSet=CharSet.Unicode, SetLastError=false)]
  public static extern IntPtr CommandLineToArgvW(string lpCmdLine, out int pNumArgs);

  [DllImport("kernel32.dll", SetLastError=false)]
  public static extern IntPtr LocalFree(IntPtr hMem);
}
"@
}

function HealthTest-NonMicrosoftServices {
    $ok = $true
    $CORE_MICROSOFT_VENDORS = @('Microsoft Windows','Microsoft Windows Publisher','Microsoft Corporation','Microsoft Windows Hardware Compatibility Publisher')
    $COMMON_VENDORS_FOR_WORKSTATIONS = @('Adobe Inc.', 'Cisco Systems, Inc.', 'Google LLC', 'Lenovo', 'Mozilla Corporation')
    $domainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole
    $isHostServer = ($domainRole  -in 3,4,5)
    Get-ServiceVendors | ?{$_.Vendor -notin $CORE_MICROSOFT_VENDORS -or $_.ExceptionsThrown} | %{
        if ($_.ExeSHA256) {$extra_msg = " (SHA256 of '$($_.ExePath)' is $($_.ExeSHA256))"} else {$extra_msg=""}
        $TrimmdServiceName = $_.ServiceName -replace '[0-9]+[.][0-9][0-9.]*$','[VERSION]'
        $ok = $false
        if ($_.ExceptionsThrown) {
            Write-Warning "[warning] $("Either something's wrong with service '$($_.ServiceName)' or there's a bug in Get-ServiceVendors.")`n$($_.ExceptionsThrown)"
        } else {
            if ($isHostServer -or ($_.Vendor -notin $COMMON_VENDORS_FOR_WORKSTATIONS)) {
                Write-Warning "[warning] Found service that is not a core Microsoft service: Vendor='$($_.Vendor)' Name='$TrimmdServiceName'$extra_msg" `
                    -Comment ("Admin must verify if service is legit and needed. Service Description: '$($_.DisplayName)'`n" `
                    + "Executable: '$($_.ExePath)'.")
            } else {
                Write-Warning "[notice] Found service that is not a core Microsoft service: Vendor='$($_.Vendor)' Name='$TrimmdServiceName'$extra_msg" `
                    -Comment ("It is however from a common vendor. Admin must verify if service is legit and needed. Service Description: '$($_.DisplayName)'`n" `
                    + "Executable: '$($_.ExePath)'.")
            }
        }
    }
    if ($ok) {Write-Warning "[pass] Found no service except Microsoft ones"}
}


function HealthTest-UnexpectedListeningPorts {
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
                Write-Warning "[warning] $("Unexpected listening port: $p (Process: $procDescr, Vendor: $vendor)")`n$($comment)"
            } else {
                Write-Warning "[notice] $("Unexpected listening port: $p (Process: $procDescr, Vendor: $vendor)")`n$($comment)"
            }
        } else {
            Write-Warning "[failure] $("Unexpected listening port: $p (Process: $procDescr, Vendor: $vendor)")`n$($comment)"
        }
    }

    if (-not $bad) { Write-Warning "[pass] Listening ports are within baseline" }
}

<#
.SYNOPSIS
Verifies DFS Namespace (domain-based) objects enumerate without error. OnlyForDomainServers
#>
function HealthTest-DfsNamespaceEnumerate{
  $roots=Get-DfsnRoot -ErrorAction SilentlyContinue
  if(-not $roots){ Write-Warning "[pass] No DFS Namespace roots found (nothing to check)"; return }
  $count=0
  foreach($r in $roots){ $count += (Get-DfsnFolder -Path $r.Path -ErrorAction SilentlyContinue | Measure-Object).Count }
  Write-Warning "[pass] DFSN roots/folders enumerate: Roots=$($roots.Count); Folders=$count"
}

<#
.SYNOPSIS
Lists SYSTEM-scheduled tasks that are disabled, stale, or failing.
#>
function HealthTest-SystemScheduledTasks{
  [CmdletBinding()] param(
    [string[]]$MustBeEnabled = @(),  # exact paths or regex
    [string[]]$Ignore = @(
      '^\\Microsoft\\Windows\\(AppxDeploymentClient|Bluetooth|Clip|PushToInstall|SharedPC)\\',
      '^\\Microsoft\\Windows\\(InstallService|WaaSMedic|UpdateOrchestrator)\\',
      '^\\Microsoft\\Windows\\(PLA\\Server Manager Performance Monitor|File Classification Infrastructure\\Property Definition Sync)$',
      '^\\Microsoft\\Windows\\\.NET Framework\\\.NET Framework NGEN v4\.0\.30319.*$',
      '^\\Microsoft\\Windows\\Server Initial Configuration Task$'
    ),
    [switch]$IncludeHidden,
    [switch]$IncludeBuiltIn,   # include Microsoft-authored tasks in checks
    [int]$StaleDays = 30,
    [switch]$WarnOnNonZeroLastResult
  )

  $hadIssue = $false
  $isSystem       = { param($t) $t.Principal.UserId -match '^(NT AUTHORITY\\)?SYSTEM$' }
  $isMicrosoft    = { param($t) ($t.Author -match 'Microsoft') -or ($t.TaskPath -like '\Microsoft\*') }
  $shouldIgnore   = { param($path) foreach($rx in $Ignore){ if($path -match $rx){ return } } return }
  $isRequired     = { param($path) foreach($rx in $MustBeEnabled){ if($path -match $rx){ return } } return }

  $tasks = Get-ScheduledTask | Where-Object { & $isSystem $_ }
  if(-not $IncludeHidden){ $tasks = $tasks | Where-Object { -not $_.Settings.Hidden } }
  if(-not $IncludeBuiltIn){ $tasks = $tasks | Where-Object { -not (& $isMicrosoft $_) } }

  foreach($t in $tasks){
    # Keep the leading "\" so paths look like \Microsoft\Windows\...
    $path = "$($t.TaskPath.TrimEnd('\'))\$($t.TaskName)"
    if(& $shouldIgnore $path){ continue }

    $info = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath
    $enabled = [bool]$t.Settings.Enabled
    $state = $t.State
    $hasEnabledTrigger = ($t.Triggers | Where-Object { $_.Enabled }) -ne $null
    $lastRun = $info.LastRunTime
    if (-not $lastRun) {$lastRun = [datetime]::new(1900, 1, 1)}
    $lastRes = ('0x{0:X8}' -f ([uint32]$info.LastTaskResult))

    # 1) Disabled tasks
    if(-not $enabled -or $state -eq 'Disabled'){
      $hadIssue = $true
      if(& $isRequired $path){ Write-Warning "[failure] Required SYSTEM task is disabled: $path" }
      else { Write-Warning "[warning] SYSTEM task is disabled: $path" }
      continue
    }

    # 2) Stale runs (only if triggers exist)
    if($hasEnabledTrigger -and $StaleDays -gt 0){
      if(($lastRun -eq [datetime]::MinValue) -or ((Get-Date) - $lastRun).TotalDays -gt $StaleDays){
        $hadIssue = $true
        Write-Warning "[warning] SYSTEM task appears stale: $path ; LastRun=$lastRun (> $StaleDays days or never)"
      }
    }

    # 3) Non-zero last result (optional)
    if($WarnOnNonZeroLastResult -and $info.LastTaskResult -ne 0){
      $hadIssue = $true
      if(& $isRequired $path){ Write-Warning "[failure] Required SYSTEM task has non-zero LastTaskResult: $path ; Code=$lastRes" }
      else { Write-Warning "[warning] SYSTEM task has non-zero LastTaskResult: $path ; Code=$lastRes" }
    }
  }

  if(-not $hadIssue){ Write-Warning "[pass] All relevant SYSTEM scheduled tasks are enabled and healthy" }
}

<#
.SYNOPSIS
Checks SYSVOL NTFS ACLs do not grant write to broad principals. OnlyForDCs
#>
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

<#
.SYNOPSIS
Reports accounts permitting RC4 via msDS-SupportedEncryptionTypes. OnlyForDomainServers
#>
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

<#
.SYNOPSIS
Ensures DHCP server presence/authorization sane if role installed. OnlyForDomainServers
#>
function HealthTest-DhcpInAd{
  $dhcp=Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
  if(-not $dhcp -or -not $dhcp.Installed){ Write-Warning "[pass] DHCP role not installed on this server"; return }
  $auth=Get-DhcpServerInDC -ErrorAction SilentlyContinue
  $fqdn=[System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName
  $isAuth=($auth | Where-Object { $_.DnsName -ieq $fqdn })
  if($isAuth){ Write-Warning "[pass] DHCP server is authorized in AD ($fqdn)" } else { Write-Warning "[failure] DHCP server is NOT authorized in AD ($fqdn)" }
}

<#
.SYNOPSIS
Flags enabled NICs that are disconnected (cleanup). OnlyForDomainServers
#>
function HealthTest-UnusedEnabledAdapters{
  $nics=Get-NetAdapter | Where-Object {$_.AdminStatus -eq 'Up' -and $_.Status -ne 'Up'}
  foreach($n in $nics){ Write-Warning "[warning] Enabled network adapter is disconnected: $($n.Name) ($($n.Status))" }
  if(($nics | Measure-Object).Count -eq 0){ Write-Warning "[pass] No enabled-but-disconnected network adapters detected" } else { Write-Warning "[failure] There are enabled-but-disconnected network adapters present" }
}

<#
.SYNOPSIS
Checks active interface metrics for sane binding preference. OnlyForDomainServers
#>
function HealthTest-NetworkInterfaceMetrics{
  [CmdletBinding()] param([int]$MaxPreferredMetric=25)
  $ifs=Get-NetIPInterface -AddressFamily IPv4 | Where-Object {$_.ConnectionState -eq 'Connected'}
  $bad=$false
  foreach($i in $ifs){
    if($i.InterfaceMetric -gt $MaxPreferredMetric -and !($i.InterfaceAlias -like "Loopback*")){ $bad=$true; Write-Warning "[warning] Interface metric too high: $($i.InterfaceAlias) Metric=$($i.InterfaceMetric) (Max=$MaxPreferredMetric)" }
  }
  if(-not $bad){ Write-Warning "[pass] All connected interfaces have acceptable metrics (<= $MaxPreferredMetric)" } else { Write-Warning "[failure] One or more interfaces have metrics above the preferred threshold" }
}

<#
.SYNOPSIS
Detects disabled GPO links at domain root (policy choice). OnlyForDCs
#>
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

<#
.SYNOPSIS
Ensures event log max sizes meet baseline without reading events. OnlyForDomainServers
#>
function HealthTest-EventLogMaxSizes{
  [CmdletBinding()]
  param([hashtable]$OverrideMinSizesMB)

  $role = (Get-CimInstance Win32_ComputerSystem).DomainRole
  $MinSizesMB = switch ($role) {
    0 { @{Security=20; System=20;  Application=20} }     # Workstation, non-domain
    1 { @{Security=20; System=20;  Application=20} }     # Workstation, domain-joined
    2 { @{Security=512; System=256; Application=256} }    # Server, non-domain
    3 { @{Security=512; System=256; Application=256} }    # Server, domain-joined
    4 { @{Security=1024;System=256; Application=256} }    # DC (non-FSMO)
    5 { @{Security=1024;System=256; Application=256} }    # DC (PDC Emulator)
    Default { @{Security=512; System=256; Application=256} }
  }
  if ($OverrideMinSizesMB) {
    foreach($k in $OverrideMinSizesMB.Keys){ $MinSizesMB[$k] = [int]$OverrideMinSizesMB[$k] }
  }

  $bad=$false
  foreach($name in $MinSizesMB.Keys){
    $sz=[int64]0
    try{
      $log=Get-WinEvent -ListLog $name -ErrorAction Stop
      $sz=[int64]$log.MaximumSizeInBytes
    }catch{
      $out=& wevtutil gl $name 2>&1
      $line=($out | Select-String -Pattern 'maximum size:' -SimpleMatch | Select-Object -First 1).Line
      if($line -and ($line -match 'maximum size:\s*(\d+)')){ $sz=[int64]$Matches[1] }
    }
    if(-not $sz){ Write-Warning "[warning] $name log size could not be determined"; $bad=$true; continue }

    $minMB=[int]$MinSizesMB[$name]
    $minBytes=[int64]$minMB*1MB
    if($sz -lt $minBytes){
      $bad=$true
      $currentMB=[math]::Round($sz/1MB)
      $comment="Fix: Run  wevtutil sl $name /ms:$minBytes"
      Write-Warning "[failure] $("$name log maximum size too small: ${currentMB}MB < ${minMB}MB")`n$($comment)"
    }
  }

  if(-not $bad){ Write-Warning "[pass] Event log maximum sizes meet or exceed baseline" }
}


<#
.SYNOPSIS
Runs DCDIAG RIDManager and checks for failures or low pool signals. OnlyForDCs
#>
function HealthTest-RidManager{
  $out=& dcdiag /test:ridmanager /v 2>&1
  $fail=($out | Select-String -Pattern 'failed test RidManager','is low' -SimpleMatch)
  if($fail){ Write-Warning "[failure] RID Manager test reported issues`nReview dcdiag /test:ridmanager output"; } else { Write-Warning "[pass] RID Manager health OK (dcdiag)" }
}

<#
.SYNOPSIS
Checks presence of EFS Data Recovery Agents policy/certs. OnlyForDomainServers
#>
function HealthTest-EfsRecoveryAgents{
  $out=& certutil -recoveryagent 2>&1
  $has=($out | Select-String -Pattern 'Recovery Agent' -SimpleMatch)
  if($has){ Write-Warning "[pass] EFS Data Recovery Agents are configured" } else { Write-Warning "[notice] No EFS Data Recovery Agents configured.`nIf anyone uses EFS (NTFS file encryption), there's no domain recovery agent to decrypt data if the user's key is lost." }
}

<#
.SYNOPSIS
Verifies DNS zone transfers are restricted. OnlyForDCs
#>
function HealthTest-DnsZoneTransfers{
  $zones=Get-DnsServerZone | Where-Object { -not $_.IsAutoCreated }
  $bad=$false
  foreach($z in $zones){
    if($z.SecureSecondaries -eq 'Any'){ $bad=$true; Write-Warning "[failure] DNS zone transfer open to Any: $($z.ZoneName)" }
  }
  if(-not $bad){ Write-Warning "[pass] DNS zone transfers are restricted (not 'Any')" }
}

<#
.SYNOPSIS
Flags stale krbtgt (pwdLastSet age above threshold). OnlyForDomainServers
.NOTES
What a failure means: The KRBTGT account key hasn't been rotated for years. Windows keeps the previous KRBTGT key to validate existing TGTs; never rotating extends the window for 'golden ticket' persistence if the key ever leaked.
Risk: If an attacker ever accessed the KRBTGT key, they can mint TGTs and persist. Rotating twice (with replication time in between) is the standard mitigation.
Severity: Critical.
#>
function HealthTest-KrbtgtAge{
  [CmdletBinding()] param([int]$MaxDays=720)
  $u=Get-ADUser krbtgt -Properties pwdLastSet
  $ageDays=[int]((Get-Date) - [DateTime]::FromFileTime($u.pwdLastSet)).TotalDays
  if($ageDays -le $MaxDays){
    Write-Warning "[pass] krbtgt password age acceptable ($ageDays days <= $MaxDays)"
  } else {
    Write-Warning "[failure] krbtgt password age exceeds threshold($MaxDays)`nThe KRBTGT account key hasn't been rotated for $ageDays days. Windows keeps the previous KRBTGT key to validate existing TGTs; never rotating extends the brute force time window for an attacker. Risk: If an attacker ever accessed the KRBTGT key, they can mint TGTs and persist. Rotating twice (with replication time in between) is the standard mitigation."
  }
}

<#
.SYNOPSIS
Ensures NTDS log volume free space above threshold. OnlyForDCs
#>
function HealthTest-NtdsLogVolumeFree{
  [CmdletBinding()] param([int]$MinFreeGB=5)
  $p='HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
  $logPath=(Get-ItemProperty $p -Name 'Database log files path').'Database log files path'
  $drive=(Get-Item $logPath).PSDrive.Name+':'
  $d=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive'"
  $freeGB=[math]::Round($d.FreeSpace/1GB,2)
  if($freeGB -ge $MinFreeGB){ Write-Warning "[pass] NTDS log volume free space OK ($freeGB GB >= $MinFreeGB GB)" } else { Write-Warning "[failure] NTDS log volume low free space ($freeGB GB < $MinFreeGB GB)`nLog path: $logPath" }
}

<#
.SYNOPSIS
Verifies required hotfix baseline is present. OnlyForDomainServers
#>
function HealthTest-HotfixBaseline{
  [CmdletBinding()] param([string[]]$RequiredKBs)
  if(-not $RequiredKBs -or $RequiredKBs.Count -eq 0){ Write-Warning "[pass] No hotfix baseline provided"; return }
  $have=(Get-HotFix | Select-Object -ExpandProperty HotFixID)
  $miss=@()
  foreach($kb in $RequiredKBs){
    if($have -notcontains $kb){ $miss += $kb; Write-Warning "[failure] Missing required hotfix: $kb" }
  }
  if($miss.Count -eq 0){ Write-Warning "[pass] All required hotfixes are installed" }
}

<#
.SYNOPSIS
Validates DHCP DNS update credential account health. OnlyForDomainServers
#>
function HealthTest-DhcpDnsCredential{
  [CmdletBinding()] param([int]$MaxPwdAgeDays=365)
  $dhcp=Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
  if(-not $dhcp -or -not $dhcp.Installed){ Write-Warning "[pass] DHCP role not installed on this server"; return }
  $cred=Get-DhcpServerDnsCredential -ErrorAction SilentlyContinue
  if(-not $cred -or -not $cred.UserName){ Write-Warning "[failure] No DHCP DNS update credentials configured"; return }
  $u=Get-ADUser -Identity $cred.UserName -Properties Enabled,pwdLastSet
  $age=[int]((Get-Date) - [DateTime]::FromFileTime($u.pwdLastSet)).TotalDays
  if(-not $u.Enabled){ Write-Warning "[failure] DHCP DNS credential account is disabled: $($cred.UserName)"; return }
  if($age -gt $MaxPwdAgeDays){ Write-Warning "[failure] DHCP DNS credential password age too high ($age days > $MaxPwdAgeDays): $($cred.UserName)" } else { Write-Warning "[pass] DHCP DNS credential healthy (Enabled, pwd age $age days <= $MaxPwdAgeDays)" }
}

<#
.SYNOPSIS
Validates GPT vs GPC version numbers for GPO consistency. OnlyForDomainServers
#>
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

<#
.SYNOPSIS
Compares SYSVOL policy tree manifest across DCs (count+hash). OnlyForDCs
.NOTES 
Stresses Network: SMB directory tree walks to each DC's SYSVOL\Policies across sites.
#>
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

<#
.SYNOPSIS
Reviews RODC PRP (allow/deny) presence where RODCs exist. OnlyForDomainServers
#>
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

<#
.SYNOPSIS
Reports members of 'Pre-Windows 2000 Compatible Access' (should be empty). OnlyForDomainServers
#>
function HealthTest-PreWin2000Group{
  $g=Get-ADGroup -Identity 'Pre-Windows 2000 Compatible Access'
  $m=Get-ADGroupMember $g -Recursive -ErrorAction SilentlyContinue
  foreach($u in $m){ Write-Warning "[failure] 'Pre-Windows 2000 Compatible Access' contains member: $($u.SamAccountName)" }
  if(($m | Measure-Object).Count -eq 0){ Write-Warning "[pass] 'Pre-Windows 2000 Compatible Access' group has no members" }
}

<#
.SYNOPSIS
Validates GP WMI filters use namespaces that exist on this host. OnlyForDomainServers
#>
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

function Get-SoftwareLicensing {
    [CmdletBinding()]
    param([string]$ComputerName = $env:COMPUTERNAME)

    function Convert-LicenseStatus {
        param([int]$code)
        switch ($code) {
            0 {'Unlicensed'}
            1 {'Licensed'}
            2 {'OOB Grace'}
            3 {'OOT Grace'}
            4 {'Non-Genuine Grace'}
            5 {'Notification'}
            6 {'Extended Grace'}
            default {"Unknown ($code)"}
        }
    }

    if ($ComputerName -eq $env:COMPUTERNAME) {
        $products = Get-CimInstance -ClassName SoftwareLicensingProduct -ErrorAction Stop |
                Where-Object { $_.PartialProductKey -and $_.LicenseStatus -ne $null }
    } else {
        $products = Get-CimInstance -ClassName SoftwareLicensingProduct -ComputerName $ComputerName -ErrorAction Stop |
                Where-Object { $_.PartialProductKey -and $_.LicenseStatus -ne $null }
    }

    $objects = foreach($p in $products){
        $statusText = Convert-LicenseStatus -code ([int]$p.LicenseStatus)

        $channel = $null
        if ($p.Description) {
            $m = [regex]::Match($p.Description, '(?i)\b([A-Z0-9_]+)\s+channel\b')
            if ($m.Success) { $channel = $m.Groups[1].Value }
        }

        [pscustomobject][ordered]@{
            ComputerName         = $ComputerName
            ProductName          = $p.Name
            LicenseFamily        = Get-PropValue $p 'LicenseFamily'
            ApplicationId        = $p.ApplicationId
            ProductSkuId         = Get-PropValue $p 'ProductSkuId'
            PartialProductKey    = Get-PropValue $p 'PartialProductKey'
            LicenseStatus        = [int]$p.LicenseStatus
            LicenseStatusText    = $statusText
            IsLicensed           = [bool]($p.LicenseStatus -eq 1)
            GracePeriodRemaining = Get-PropValue $p 'GracePeriodRemaining'
            Description          = $p.Description
            Channel              = $channel
        }
    }

    $objects | Sort-Object ProductName, LicenseStatus
}

<#
.SYNOPSIS
Verifies Windows are Licensed.
#>
function HealthTest-SoftwareLicensing{
    Get-SoftwareLicensing | %{
        # ($_ | Format-List * -Force | Out-String).Trim()|write-host -f green
        Write-BasedOnTestResult "Is $($_.ProductName) Licensed?" -Test $_.IsLicensed -comment "$_"
    }
}

<#
.SYNOPSIS
Checks if TPM is activated. OnlyForMobile
#>
function HealthTest-IsTPMActivated {
  Write-BasedOnTestResult "Is TPM Activated?" -Test (Get-Tpm).TpmActivated
}




<#
.SYNOPSIS
Checks DNS suffix for the AD domain. OnlyForDomain,NotForDCs
#>
function HealthTest-DnsSuffixMatchesDomain {
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

<#
.SYNOPSIS
Checks that the domain DNS name A record points to at least one DC IP. OnlyForDomain,NotForDCs

IMPORTANT: you need to have a json list with the IPs of all DCs in file
	'C:\it\config\ips-of-all-DCs.conf'. E.g:
	{"ips":["192.168.0.1","192.168.0.2"]}
#>
function HealthTest-DomainARecordPointsToDcIp {
  $cs = Get-CimInstance Win32_ComputerSystem
  $role = $cs.DomainRole
  $fn = $MyInvocation.MyCommand.Name
  if ($role -in 0,2) { Write-Warning "[notice] This test ($fn) is not applicable to non-domain joined hosts"; return }
  if ($role -in 4,5) { Write-Warning "[notice] This test ($fn) is not applicable to Domain Controllers"; return }

  Write-Output "Reading C:\it\config\ips-of-all-DCs.conf to get the list of the IPs of all DCs"
  # will return a list of IPs or throw
  $dcIps = Get-AllDCIPs -Path 'C:\it\config\ips-of-all-DCs.conf'

  $domain = $cs.Domain
  $ares = $null
  try { $ares = Resolve-DnsName -Name $domain -Type A -ErrorAction Stop } catch {}
  if (-not $ares) {
    Write-Warning "[failure] $("No A records found for domain DNS name.")`n$($domain)"
    return
  }

  $aIps = @($ares | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
  $intersection = @()
  foreach ($ip in $aIps) { if ($dcIps -contains $ip) { $intersection += $ip } }

  $comment = "Domain=$domain; DC IPs=" + ($dcIps -join ', ') + "; Domain A IPs=" + ($aIps -join ', ')
  if ($intersection.Count -gt 0) {
    Write-Warning "[pass] $("Domain DNS name resolves to at least one DC IP.")`n$($comment)"
  } else {
    Write-Warning "[failure] $("Domain DNS name does not resolve to any known DC IPv4 address.")`n$($comment)"
  }
}

<#
.SYNOPSIS
Ensures each interface DNS server list contains only DC IPs. OnlyForDomain,NotForDCs

IMPORTANT: you need to have a json list with the IPs of all DCs in file
	'C:\it\config\ips-of-all-DCs.conf'. E.g:
	{"ips":["192.168.0.1","192.168.0.2"]}
#>
function HealthTest-InterfaceDnsServersUseDcs {

  $cs = Get-CimInstance Win32_ComputerSystem
  $role = $cs.DomainRole
  $fn = $MyInvocation.MyCommand.Name
  if ($role -in 0,2) { Write-Warning "[notice] This test ($fn) is not applicable to non-domain joined hosts"; return }
  if ($role -in 4,5) { Write-Warning "[notice] This test ($fn) is not applicable to Domain Controllers"; return }

  Write-Output "Reading C:\it\config\ips-of-all-DCs.conf to get the list of the IPs of all DCs"
  # will return a list of IPs or throw
  $dcIps = Get-AllDCIPs -Path 'C:\it\config\ips-of-all-DCs.conf'

  $nets = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=TRUE"
  if (-not $nets) {
    Write-Warning "[failure] No IP-enabled network adapters found."
    return
  }

  $anyClean = $false
  $anyBad   = $false

  foreach ($net in $nets) {
    $dns  = $net.DNSServerSearchOrder
    $desc = $net.Description
    if (-not $dns -or $dns.Count -eq 0) {
      Write-Warning "[notice] $("Interface has no DNS servers configured.")`n$($desc)"
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
      Write-Warning ("[pass] Interface has only DCs as DNS servers.`nInterface: " + $desc + "; DNS=" + $dnsList)
    } elseif ($allNonDomain) {
      # Ignoring this interface that only has non-domain DNS servers
    } else {
      $anyBad = $true
      Write-Warning ("[failure] Interface DNS servers include non-DC addresses.`nInterface: " + $desc + "; DNS=" + $dnsList + "; DC IPs=" + ($dcIps -join ', '))
    }
  }

  if (-not $anyClean) {
    Write-Warning "[failure] No interface found where all DNS servers are DC IPs."
  } elseif (-not $anyBad) {
    Write-Warning "[pass] All interfaces with DNS configured use only DC IPs."
  }
}

<#
.SYNOPSIS
Verifies NLTEST /dsgetsite can determine the client AD site. OnlyForDomain,NotForDCs
#>
function HealthTest-NltestSiteDiscovery {
  [CmdletBinding()] param()
  $cs = Get-CimInstance Win32_ComputerSystem
  $role = $cs.DomainRole
  $fn = $MyInvocation.MyCommand.Name
  if ($role -in 0,2) { Write-Warning "[notice] This test ($fn) is not applicable to non-domain joined hosts"; return }
  if ($role -in 4,5) { Write-Warning "[notice] This test ($fn) is not applicable to Domain Controllers"; return }

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
    Write-Warning "[pass] $("NLTEST /dsgetsite succeeded.")`n$(("Site: " + $site))"
  } else {
    $hex = '0x{0:X}' -f ($exit -band 0xFFFFFFFF)
    Write-Warning ("[failure] NLTEST /dsgetsite failed.`nExitCode=" + $hex + "; Output=`n" + $txt)
  }
}

<#
.SYNOPSIS
Runs gpupdate and validates computer and user policy application. OnlyForDomain,NotForDCs
#>
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

#--------------------------------------------------------
# xxx new tests 20205-11-26

<# .SYNOPSIS Checks recent critical disk/NTFS/storage errors in the System event log. #>
function HealthTest-RecentDiskErrors {
    param([int]$Hours = 48)

    $pass = $true
    if ($Hours -lt 1) { $Hours = 1 }

    $start     = (Get-Date).AddHours(-$Hours)
    $providers = @('disk','ntfs','stornvme')
    $events    = @()

    foreach ($p in $providers) {
        try {
            Get-WinEvent -FilterHashtable @{
                    LogName      = 'System'
                    ProviderName = $p
                    Level        = 2     # Error
                    StartTime    = $start
            } -ErrorAction SilentlyContinue | %{
                Write-Warning "[failure] Storage($p) error in last N hours`nN=$Hours hours; Event: $($_.TimeCreated), $($_.LevelDisplayName), $($_.Message)"
                $pass = $false
            }
        } catch {
            if ($_.Exception.Message -notlike '*There is not an event provider*') {
                Write-Warning "[warning] Failed reading System log for provider '$p': $($_.Exception.Message)"
            }
        }
    }

    if ($pass) {
        Write-Warning "[pass] No disk/NTFS/storage errors in last $Hours h"
    }

}

<# .SYNOPSIS Looks for crash dumps and bugcheck events as indicators of recent system crashes. #>
function HealthTest-CrashDumpSignals {
    param([int]$Hours = 48)

    $pass = $true
    if ($Hours -lt 1) { $Hours = 1 }
    $cutoff = (Get-Date).AddHours(-$Hours)

    Get-ChildItem "$env:SystemRoot\Minidump" -Filter *.dmp -ErrorAction SilentlyContinue | ?{ $_.LastWriteTime -gt $cutoff } | %{
        Write-Warning "[failure] Found $env:SystemRoot\Minidump\ file(s) within the last N hours`nN=$Hours hours. File: $env:SystemRoot\Minidump\$($_.name))"
    }
    if ($pass) {
        Write-Warning "[pass] No recent minidumps"
    }

    $pass = $true
    Get-WinEvent -FilterHashtable @{
            LogName   = 'System'
            Id        = 1001  # BugCheck
            StartTime = $cutoff
    } -ErrorAction SilentlyContinue | %{
        Write-Warning "[failure] Found System Event #1001 within the last N hours (this event often indicates a crash)`nN=$Hours hours. Event: $($_.TimeCreated), $($_.LevelDisplayName), $($_.Message)"
    }

    if ($pass) {
        Write-Warning "[pass] No recent System #1001 events"
    }
}

<# .SYNOPSIS Detects unexpected members in the local Administrators group. #>
function HealthTest-LocalAdminsBaseline {
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
        Write-Warning "[pass] No unexpected accounts in Local Administrators"
    }
}

<# .SYNOPSIS Checks physical NICs for link problems and significant error rates. #>
function HealthTest-Nic {
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
            $stat.ReceivedDiscardedPackets +
            $stat.ReceivedPacketErrors +
            $stat.OutboundDiscardedPackets +
            $stat.OutboundPacketErrors

        $totalPackets =
            $stat.ReceivedUnicastPackets +
            $stat.ReceivedBroadcastPackets +
            $stat.ReceivedMulticastPackets +
            $stat.OutboundUnicastPackets +
            $stat.OutboundBroadcastPackets +
            $stat.OutboundMulticastPackets

        if ($n.MediaConnectionState -ne 'Connected') {
            $warnList += "$($n.Name): mediaState=$($n.MediaConnectionState)"
            Write-Warning "[warning] Disconnected network interface ($($n.Name))`n"
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
            $warnList += "$($n.Name): errors=$pctStr ($errors/$totalPackets total)"
            Write-Warning "[warning] Network interface with plenty of errors ($($n.Name))`nerrors=$pctStr ($errors/$totalPackets total packets)"
            $pass = $false
        } elseif ($errors -ge 100 -and $errorPct -ge 0.002) {
            $noticeList += "$($n.Name): errors=$pctStr ($errors/$totalPackets total)"
            Write-Warning "[notice] Network interface with some errors ($($n.Name))`nerrors=$pctStr ($errors/$totalPackets total packets)"
            $pass = $false
        } else {
            # below 0.002%: considered OK, no log entry
            continue
        }
    }

    if ($pass) {
        Write-Warning "[pass] Network interfaces healthy; no significant error rates or disconnected interfaces detected"
    }
}

<# .SYNOPSIS Summarizes BitLocker protection status for local volumes. #>
function HealthTest-BitLockerStatus {
    if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        Write-Warning "[warning] BitLocker PowerShell cmdlets not available; skipping BitLocker status check"
        return
    }

    $pass = $true

    $vols = Get-BitLockerVolume -ErrorAction SilentlyContinue
    if (-not $vols) {
        Write-Warning "[notice] No BitLocker-capable volumes found"

    }
    $vols | Where-Object { $_.ProtectionStatus -ne 'On' } | %{
        Write-Warning "[failure] Volume not protected by BitLocker: $($_.MountPoint)"
        $pass = $false
    }
    if ($pass) {
        Write-Warning "[pass] BitLocker protection is ON for all detected volumes"
    }
}

<# .SYNOPSIS Detects DHCP scopes whose utilization is close to exhaustion. #>
function HealthTest-DhcpScopeUtilization {
    $svc = Get-Service -Name 'DHCPServer' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Output "Host is not a DHCP server (DHCPServer service missing); skipping DHCP scope utilization test"
        return
    }

    if (-not (Get-Command Get-DhcpServerv4ScopeStatistics -ErrorAction SilentlyContinue)) {
        Write-Warning "[warning] DHCP server cmdlets not available on this DHCP server; skipping DHCP scope utilization test"
        return
    }

    $stats = Get-DhcpServerv4ScopeStatistics -ErrorAction SilentlyContinue
    if (-not $stats) {
        Write-Warning "[warning] DHCP server role present but no DHCPv4 scopes found"
        return
    }

    $over = @()
    foreach ($s in $stats) {
        if ($s.PercentageInUse -ge 90) {
            $over += $s.ScopeId
            Write-Warning "[failure] DHCP scope is >=90% used: $($s.ScopeId)"
        } elseif ($s.PercentageInUse -ge 80) {
            $over += $s.ScopeId
            Write-Warning "[warning] DHCP scope is >=80% used: $($s.ScopeId)"
        }
    }

    if ($over.Count -gt 0) {
        Write-Warning "[pass] DHCP scope utilization OK (<80% in use)"
    }

}

<#
.SYNOPSIS
  Verifies key DNS suffix/devolution/registration settings for a small, single-domain AD.
#>
function HealthTest-DnsSuffixBaseline {
    $DomainName=(Get-CimInstance Win32_ComputerSystem).Domain

    # 1) Primary DNS suffix equals the AD DNS name
    $ipg = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    $primarySuffix = $ipg.DomainName

    if ([string]::IsNullOrWhiteSpace($primarySuffix)) {
        Write-Warning "[failure] Primary DNS suffix" "Current is empty" "Ensure the system has a primary DNS suffix (normally set by domain join)."
    } elseif ($primarySuffix -ieq $DomainName) {
        Write-Warning "[pass] Primary DNS suffix" $primarySuffix
    } else {
        Write-Warning "[failure] Primary DNS suffix" ("Current='{0}' Expected='{1}'" -f $primarySuffix,$DomainName) "Ensure primary DNS suffix equals the AD DNS name (normally set by domain join)."
    }

    # 2) DNS devolution is enabled (boolean only)
    try {
        $g = Get-DnsClientGlobalSetting -ErrorAction Stop
        if ($g.UseDevolution -eq $true) {
            Write-Warning "[pass] DNS devolution enabled" "UseDevolution=True"
        } else {
            Write-Warning "[failure] DNS devolution enabled" "UseDevolution=False" "Enable devolution (GPO: Computer Configuration/Administrative Templates/Network/DNS Client/Turn off DNS devolution = Disabled)."
        }
    } catch {
        $err = $_
        Write-Warning "[failure] DNS devolution enabled" ("Unable to query global DNS client settings: {0}" -f $err.Exception.Message) "Check OS support for Get-DnsClientGlobalSetting and that the DNS Client service is running."
    }

    # 3) Per-NIC checks (only PASS/FAIL; no discovery warning if none found)
    $nics = @()
    try {
        $nics = Get-DnsClient -ErrorAction Stop |
                Where-Object { $_.InterfaceOperationalStatus -eq "Up" -and $_.ConnectionSpecificSuffix -ne "localdomain" }
    } catch {
        $err = $_
        Write-Warning "[failure] NIC DNS settings" ("Unable to query DNS client interfaces: {0}" -f $err.Exception.Message) "Confirm OS supports Get-DnsClient and you have sufficient privileges."
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

<#
.SYNOPSIS
HealthTest-ADReplicationDomainRepadmin: Domain-wide AD replication health using repadmin.exe (replsum + showreps). DC-only; fails if repadmin or AD DS prerequisites are missing.
#>
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


<#
.SYNOPSIS
HealthTest-ADReplicationLocalRSAT: Local DC AD replication partner health using RSAT AD cmdlets (Get-ADReplicationPartnerMetadata). DC-only; fails if AD module/ADWS prerequisites are missing.
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


function Expand-EnvVarsWin32 {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Text)
  $sb = New-Object System.Text.StringBuilder 32768
  $rc = [Win32SvcPath]::ExpandEnvironmentStringsW($Text, $sb, [uint32]$sb.Capacity)
  if ($rc -gt 0 -and $rc -le $sb.Capacity) { $sb.ToString() } else { [Environment]::ExpandEnvironmentVariables($Text) }
}


function Get-ExeVendor {
  [CmdletBinding()] [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][string]$Exe)

  if (-not (Test-Path -LiteralPath $Exe)) { return [pscustomobject]@{ Vendor=$null; ExeSHA256=$null } }

  if (-not (Get-Variable -Name GetExeVendor_VendorCache -Scope Script -ErrorAction SilentlyContinue)) { $script:GetExeVendor_VendorCache = @{} }
  if (-not (Get-Variable -Name GetExeVendor_HashCache   -Scope Script -ErrorAction SilentlyContinue)) { $script:GetExeVendor_HashCache   = @{} }

  $vc = $script:GetExeVendor_VendorCache
  $hc = $script:GetExeVendor_HashCache
  $vendor = $null
  $exeSHA256 = $null

  if (-not $vc.ContainsKey($Exe)) {
    try {
      $sig = Get-AuthenticodeSignature -FilePath $Exe -ErrorAction Stop
      $sigStatus        = $sig.Status
      $sigStatusMessage = $sig.StatusMessage
      $sigCert          = $sig.SignerCertificate
    } catch {
      Write-Verbose "[Get-ExeVendor] Signature check failed for [$Exe]: $($_.Exception.Message)"
      $vc[$Exe] = '(Unknown)'
      return [pscustomobject]@{ Vendor='(Unknown)'; ExeSHA256=$null }
    }

    $isGoodEnough = ($sigStatus -eq 'Valid') -or ($sigStatusMessage -eq 'A certificate chain processed, but terminated in a root certificate which is not trusted by the trust provider')

    if ($isGoodEnough) {
      if ($sigCert) {
        $vendor = $sigCert.GetNameInfo('SimpleName', $false)
        if (-not $vendor) { $vendor = $sigCert.Subject }
      } else {
        $vendor = '(Unsigned)'
        try {
          $h = (Get-FileHash -Path $Exe -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
          if ($h) { $hc[$Exe] = $h; $exeSHA256 = $h }
        } catch { Write-Verbose "[Get-ExeVendor] Hash calc failed for [$Exe]: $($_.Exception.Message)" }
      }
    } elseif ($sigStatus -eq 'NotSigned') {
      $vendor = '(Unsigned)'
      if (-not $hc.ContainsKey($Exe)) {
        try {
          $h = (Get-FileHash -Path $Exe -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
          if ($h) { $hc[$Exe] = $h }
        } catch { Write-Verbose "[Get-ExeVendor] Hash calc failed for [$Exe]: $($_.Exception.Message)" }
      }
      if ($hc.ContainsKey($Exe)) { $exeSHA256 = $hc[$Exe] }
    } else {
      $vendor = "(Invalid: $sigStatus, $sigStatusMessage)"
    }

    $vc[$Exe] = $vendor
  } else {
    $vendor = $vc[$Exe]
    if ($hc.ContainsKey($Exe)) { $exeSHA256 = $hc[$Exe] }
  }

  [pscustomobject]@{ Vendor=$vendor; ExeSHA256=$exeSHA256 }
}


function Get-PathExtList {
  [CmdletBinding()]
  param()
  $exts=@()
  if ($env:PATHEXT) { $exts += ($env:PATHEXT -split ';') }
  $exts += '.EXE'
  $exts | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { if ($_.StartsWith('.')) { $_ } else { ".$_" } } | Select-Object -Unique
}


function Get-ServiceDllFromReg {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$SvcName)

  $svcKey="Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$SvcName"

  $candidates=@(
    @{Path="$svcKey\Parameters"; Name='ServiceDll'},
    @{Path="$svcKey\Parameters"; Name='ServiceDllEx'},
    @{Path="$svcKey";           Name='ServiceDll'},
    @{Path="$svcKey";           Name='ServiceDllEx'}
  )

  foreach($c in $candidates){
    try{
      $v=(Get-ItemProperty -Path $c.Path -Name $c.Name -ErrorAction SilentlyContinue).($c.Name)
      if($v){ return [pscustomobject]@{ Value=$v; Where="$($c.Path)\$($c.Name)" } }
    } catch {}
  }

  $null
}


function Get-ServiceVendors {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param()

  $services = Get-CimInstance Win32_Service | Select-Object Name,PathName,DisplayName

  foreach($s in $services){
    $ExceptionsThrown = ""
    $exe = $null
    try {
		$rse = Resolve-ServiceExecutable $s.PathName $s.Name
		if (-not ($null -eq $rse)) {$exe = $rse.PayloadPath}
    } catch {
        $ExceptionsThrown += "[Get-ServiceVendors] Resolve failed for service [$($s.Name)]: $($_.Exception.Message)."
    }
    if([string]::IsNullOrWhiteSpace($exe)){ $exe = $null }

    $vendor = $null; $exeSHA256 = $null
    if($exe -and (Test-Path -LiteralPath $exe)){
      $r = Get-ExeVendor -Exe $exe
      $vendor = $r.Vendor
      $exeSHA256 = $r.ExeSHA256
    } else {
      $ExceptionsThrown += "Service $($s.Name) points to missing executable. Exe='$exe' PathName='$($s.PathName)'."
    }

    [pscustomobject]@{
      ServiceName = $s.Name
      Vendor      = $vendor
      ExePath     = $exe
      ExeSHA256   = $exeSHA256
      DisplayName = $s.DisplayName
      ExceptionsThrown  = $ExceptionsThrown
    }
  }
}


function Normalize-CommandText {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowNull()][string]$Text,
    [switch]$NoTrim,
    [switch]$NoDequote,
    [switch]$NoExpandEnv,
    [switch]$NoNormalizeSystemRoot
  )
  if ($null -eq $Text) { return $null }
  $s=$Text
  if(-not $NoTrim){$s=$s.Trim()}
  if(-not $NoDequote){$s=Strip-SurroundingQuotes $s}
  if(-not $NoTrim){$s=$s.Trim()}
  if(-not $NoExpandEnv){$s=Expand-EnvVarsWin32 $s}
  if(-not $NoNormalizeSystemRoot){$s=Normalize-SystemRootPrefix $s}
  if([string]::IsNullOrWhiteSpace($s)){return $null}
  $s
}


function Normalize-SystemRootPrefix {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Text)
  if ($Text.StartsWith('\SystemRoot\',[StringComparison]::OrdinalIgnoreCase)) {
    $tail = $Text.Substring(11)
    $windir = $env:WINDIR; if ([string]::IsNullOrEmpty($windir)) { $windir = $env:SystemRoot }
    if ([string]::IsNullOrEmpty($windir)) { $windir = 'C:\Windows' }
    return (Join-Path $windir $tail)
  }
  $Text
}


function Probe-UnquotedServicePath {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$CommandLineDequoted,
    [Parameter(Mandatory)][string[]]$Exts
  )
  $c=$CommandLineDequoted.Trim()
  if ([string]::IsNullOrWhiteSpace($c)) { return $null }
  if ($c -notmatch '\s') { return $null }

  $spaces=@()
  for($i=0;$i -lt $c.Length;$i++){ if($c[$i] -eq ' '){ $spaces += $i } }

  foreach($pos in $spaces){
    $cand = $c.Substring(0,$pos).Trim()
    if (-not (Test-LooksLikePath $cand)) { continue }
    $resolved = Resolve-ExecutablePath $cand -ExtsIfMissing $Exts
    if ($resolved) {
      $rest = $c.Substring($pos).Trim()
      return ,@($resolved,$rest)
    }
  }
  $null
}


function Resolve-ExecutablePath {
<#
.SYNOPSIS
  Locate the actual executable file that Windows would run.

.DESCRIPTION
  This function wraps the Win32 API SearchPathW to locate the actual executable file that Windows would run,
  while adding important safety, correctness, and robustness features expected in modern PowerShell tooling.
  It provides behavior closely aligned with CreateProcess and CMD executable resolution.     If no executable is found, the function returns $null.
   - It never throws exceptions for normal resolution failures.
   - If input is path-like AND NOT rooted, returns $null (refuses relative paths)

  The function follows a strict, deterministic resolution strategy with literal semantics (no wildcard expansion),
  predictable behavior, and explicit PATHEXT probing.
  If the input looks like a path (rooted, relative with \ or /, or \SystemRoot\... after normalization), 
  the function does not search $env:PATH, System32, Windows, or the current directory to 
  "find something else". It only checks whether the explicit path exists as given and, if the input has 
  no extension, it performs extension probing (PATHEXT or -ExtsIfMissing) against that same explicit path.
  If no match is found, it returns $null.

  Resolution proceeds through these stages:

  - If the input appears to be a path but contains illegal filesystem characters it returns $null instead 
  of throwing.
  - If the input does not include an extension, the function probes all extensions in $env:PATHEXT
     (plus .EXE to guarantee coverage), exactly like CMD and CreateProcess.
  - Wildcard characters (* ? [ ]) are treated as literal filename characters, not patterns.

.PARAMETER NameOrPath
  The executable string to resolve. May be:

.OUTPUTS
  System.String or $null

  The fully qualified path of the resolved executable, or $null if resolution fails.

.EXAMPLE
        - 'notepad' -> C:\Windows\System32\notepad.exe
        - 'script'  -> C:\Tools\script.bat   (if present and PATHEXT includes .BAT)
        - 'tool'    -> C:\Bin\tool.cmd       (if present and PATHEXT includes .CMD)
        - 'tool*.exe'  -> resolves only if a file literally named "tool*.exe" exists
		- Command name:        netsh, git, cmd
		- Absolute path:       C:\Windows\System32\cmd.exe
		- Absolute path w/o ext: C:\Windows\System32\cmd
		- Relative path:       .\tools\build.cmd
		- Environment path:    %WINDIR%\system32\cmd
  Resolve-ExecutablePath netsh
  -> C:\Windows\System32\netsh.exe

  Resolve-ExecutablePath cmd
  -> C:\Windows\System32\cmd.exe

  Resolve-ExecutablePath C:\Windows\System32\cmd
  -> C:\Windows\System32\cmd.exe

  Resolve-ExecutablePath '%WINDIR%\System32\WindowsPowerShell\v1.0\powershell'
  -> C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe

  Resolve-ExecutablePath 'nonexistenttool'
  -> $null
#>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$NameOrPath,
    [string[]]$ExtsIfMissing
  )

  $s = Normalize-CommandText $NameOrPath
  if ($null -eq $s) { return $null }

  $looksLikePath = Test-LooksLikePath $s
  if ($looksLikePath) {
    if (Test-HasInvalidPathChars $s) { return $null }
    $isRooted=$false
    try { $isRooted=[IO.Path]::IsPathRooted($s) } catch { $isRooted=$false }
    if(-not $isRooted){ return $null }  # <-- your requirement: refuse relative path-like inputs
  }

  $sys32  = [Environment]::SystemDirectory
  $windir = $env:WINDIR
  if ([string]::IsNullOrWhiteSpace($windir)) { $windir = $env:SystemRoot }
  if ([string]::IsNullOrWhiteSpace($windir)) { $windir = 'C:\Windows' }

  $searchPath = Expand-EnvVarsWin32 "$sys32;$windir;$env:PATH"

  $sb = New-Object System.Text.StringBuilder 32768
  $call = {
    param([string]$name,[string]$ext)
    $sb.Length = 0
    $rc = [Win32SvcPath]::SearchPathW($searchPath,$name,$ext,[uint32]$sb.Capacity,$sb,[IntPtr]::Zero)
    if ($rc -gt 0 -and $rc -le $sb.Capacity) { $sb.ToString() } else { $null }
  }

  $ext=''
  try { $ext=[IO.Path]::GetExtension($s) } catch { $ext='' }

  if ($ext) {
    $r = & $call $s $null
    if ($r) { return $r }
    return $null
  }

  if (-not $ExtsIfMissing -or $ExtsIfMissing.Count -eq 0) {
    $ExtsIfMissing = Get-PathExtList
  } else {
    $ExtsIfMissing = $ExtsIfMissing |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ } |
      ForEach-Object { if ($_.StartsWith('.')) { $_ } else { ".$_" } } |
      Select-Object -Unique
  }

  foreach ($e in $ExtsIfMissing) {
    $r = & $call $s $e
    if ($r) { return $r }
  }

  $null
}


function Resolve-ServiceExecutable {
<#
.SYNOPSIS
  Resolve the launcher executable and the underlying payload referenced by a service launch command.

.DESCRIPTION
  Input:
    - LaunchCommand: a service ImagePath/PathName-style command line (may include quotes, env vars, args, rundll32, svchost, etc.)
    - ServiceName  : short service name (used for registry lookups like Parameters\ServiceDll and service Type)

  Output:
    - LauncherExe, LauncherArgs
    - PayloadType: Exe | DllViaRundll32 | DllViaSvchost | DriverSys | Unknown
    - PayloadPath (when determinable)
    - Warnings (e.g., unquoted path ambiguity)

  Debugging:
    Use -Verbose or set $VerbosePreference='Continue' to see step-by-step resolution decisions.

.EXAMPLE
  Resolve-ServiceExecutable -LaunchCommand '"C:\Program Files\App\svc.exe" -k run' -ServiceName 'AppSvc' -Verbose
#>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$LaunchCommand,
    [Parameter(Mandatory)][string]$ServiceName
  )
  
  function Get-BaseServiceName {
    param([Parameter(Mandatory)][string]$ServiceName)
  
    $m=[regex]::Match($ServiceName,'^(?<base>.+?)_(?<hex>[0-9a-fA-F]{5,16})$')
    if(-not $m.Success){ return $ServiceName }
  
    $base=$m.Groups['base'].Value
    $baseKey="Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$base"
    if(Test-Path -LiteralPath $baseKey){ return $base }
  
    $ServiceName
  }


  $warnings = New-Object System.Collections.Generic.List[string]

  $raw = $LaunchCommand
  $san = Normalize-CommandText $raw -NoDequote
  Write-Verbose "[Resolve-ServiceExecutable] OriginalLaunchCommand=<$raw>"
  Write-Verbose "[Resolve-ServiceExecutable] SanitizedCommandLine=<$san>"

  $extsExe = Get-PathExtList

  $launcherToken = $null
  $launcherArgs  = ''
  $launcherPath  = $null

  $sanDequoted = Normalize-CommandText $san -NoDequote -NoExpandEnv -NoNormalizeSystemRoot
  Write-Verbose "[Resolve-ServiceExecutable] SanitizedDequoted=<$sanDequoted>"

  if (Test-LooksLikePath $sanDequoted) {
    Write-Verbose "[Resolve-ServiceExecutable] BypassCheck: looks like path"
    if (Test-HasInvalidPathChars $sanDequoted) {
      Write-Verbose "[Resolve-ServiceExecutable] BypassCheck: invalid path chars -> return null launcher"
    } elseif (Test-Path -LiteralPath $sanDequoted -PathType Leaf) {
      $launcherToken = $sanDequoted
      $launcherArgs  = ''
      $launcherPath  = (Get-Item -LiteralPath $sanDequoted).FullName
      Write-Verbose "[Resolve-ServiceExecutable] BypassCheck: existing file -> launcherPath=<$launcherPath> (skip parsing)"
    }
  }

  if (-not $launcherPath) {
    $pair = Split-FirstTokenSmart $san
    $launcherToken = $pair[0]
    $launcherArgs  = $pair[1]
    Write-Verbose "[Resolve-ServiceExecutable] ParsedFirstToken: token=<$launcherToken> args=<$launcherArgs>"
  }

  # Warn only for the classic case: the EXE PATH itself contains spaces and wasn't quoted
  # (i.e., ambiguous "C:\Program Files\..." style)
  if ($san -match '\s' -and -not $san.TrimStart().StartsWith('"') -and -not $san.TrimStart().StartsWith("'")) {
    $first = $launcherToken
    if ($first -and (Test-LooksLikePath $first) -and ($first -match '\s')) {
      $warnings.Add("Unquoted executable path contains spaces; command line is ambiguous (classic 'unquoted service path' pattern). Attempting progressive probing.")
      Write-Verbose "[Resolve-ServiceExecutable] Warning: unquoted executable path with spaces detected"
    }
  }


  Write-Verbose "[Resolve-ServiceExecutable] LauncherToken=<$launcherToken>"
  if (-not $launcherPath) {
    $launcherPath = Resolve-ExecutablePath -NameOrPath $launcherToken -ExtsIfMissing $extsExe
  }
  Write-Verbose "[Resolve-ServiceExecutable] LauncherPath=<$launcherPath>"

  if (-not $launcherPath) {
    $pp = Probe-UnquotedServicePath -CommandLineDequoted $sanDequoted -Exts $extsExe
    if ($pp) {
      $launcherPath = $pp[0]
      $launcherArgs = $pp[1]
      Write-Verbose "[Resolve-ServiceExecutable] ProgressiveProbe: launcherPath=<$launcherPath> args=<$launcherArgs>"
    }
  }

  # (payload logic unchanged from your version)
  $payloadType='Unknown'; $payloadPath=$null; $payloadDetails=$null
  if ($launcherPath) {
    $launcherLeaf = [IO.Path]::GetFileName($launcherPath)
    $svcKey  = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$ServiceName"
    $svcType = $null
    try { $svcType = (Get-ItemProperty -Path $svcKey -Name Type -ErrorAction SilentlyContinue).Type } catch {}
    $isDriver=$false
    if ($svcType -ne $null) { if (($svcType -band 1) -or ($svcType -band 2)) { $isDriver=$true } }

    if ($isDriver -or ($launcherLeaf -match '\.sys$')) {
      $payloadType='DriverSys'; $payloadPath=$launcherPath; $payloadDetails='Driver-style service (kernel/filesystem driver).'
    } elseif ($launcherLeaf -ieq 'rundll32.exe') {
      $payloadType='DllViaRundll32'
      $pair2 = Split-FirstTokenSmart $launcherArgs
      $dllTokenPlus = $pair2[0]
      if ($dllTokenPlus) {
        $dllPair = Split-Rundll32DllToken $dllTokenPlus
        $dllToken=$dllPair[0]; $entry=$dllPair[1]
        $dllPath = Resolve-ExecutablePath -NameOrPath $dllToken -ExtsIfMissing @('.DLL','.CPL')
        $payloadPath = $dllPath
        $payloadDetails = [pscustomobject]@{ DllToken=$dllToken; EntryPoint=$entry }
      } else {
        $warnings.Add("rundll32.exe detected but DLL token could not be parsed from arguments.")
      }
    } elseif ($launcherLeaf -ieq 'svchost.exe') {
      $payloadType='DllViaSvchost'
    
      $svcDll=$null; $svcDllWhere=$null
    
      $hit = Get-ServiceDllFromReg -SvcName $ServiceName
      if($hit){ $svcDll=$hit.Value; $svcDllWhere=$hit.Where }
    
      if(-not $svcDll){
        $base = Get-BaseServiceName $ServiceName
        if($base -and $base -ne $ServiceName){
          $hit2 = Get-ServiceDllFromReg -SvcName $base
          if($hit2){ $svcDll=$hit2.Value; $svcDllWhere="$($hit2.Where) (base of $ServiceName)" }
        }
      }
    
      if ($svcDll) {
        $svcDllNorm = Normalize-CommandText $svcDll -NoDequote
        $dllPath = Resolve-ExecutablePath -NameOrPath $svcDllNorm -ExtsIfMissing @('.DLL')
        $payloadPath = $dllPath
        $payloadDetails = [pscustomobject]@{ ServiceDll=$svcDllNorm; Registry=$svcDllWhere }
      } else {
        $warnings.Add("svchost.exe detected but ServiceDll/ServiceDllEx not found for '$ServiceName' (checked service key + Parameters, and base service if applicable).")
      }
    } else {
      $payloadType='Exe'; $payloadPath=$launcherPath
    }
  } else {
    $warnings.Add("Launcher executable could not be resolved from LaunchCommand.")
  }

  [pscustomobject]@{
    OriginalLaunchCommand = $raw
    ServiceName          = $ServiceName
    SanitizedCommandLine = $san
    LauncherExe          = $launcherPath
    LauncherArgs         = $launcherArgs
    PayloadType          = $payloadType
    PayloadPath          = $payloadPath
    PayloadDetails       = $payloadDetails
    Warnings             = @($warnings)
  }
}


function Resolve-ExecutablePath {
<#
.SYNOPSIS
  Locate the actual executable file that Windows would run.

.DESCRIPTION
  This function wraps the Win32 API SearchPathW to locate the actual executable file that Windows would run,
  while adding important safety, correctness, and robustness features expected in modern PowerShell tooling.
  It provides behavior closely aligned with CreateProcess and CMD executable resolution.     If no executable is found, the function returns $null.
   - It never throws exceptions for normal resolution failures.
   - If input is path-like AND NOT rooted, returns $null (refuses relative paths)

  The function follows a strict, deterministic resolution strategy with literal semantics (no wildcard expansion),
  predictable behavior, and explicit PATHEXT probing.
  If the input looks like a path (rooted, relative with \ or /, or \SystemRoot\... after normalization), 
  the function does not search $env:PATH, System32, Windows, or the current directory to 
  "find something else". It only checks whether the explicit path exists as given and, if the input has 
  no extension, it performs extension probing (PATHEXT or -ExtsIfMissing) against that same explicit path.
  If no match is found, it returns $null.

  Resolution proceeds through these stages:

  - If the input appears to be a path but contains illegal filesystem characters it returns $null instead 
  of throwing.
  - If the input does not include an extension, the function probes all extensions in $env:PATHEXT
     (plus .EXE to guarantee coverage), exactly like CMD and CreateProcess.
  - Wildcard characters (* ? [ ]) are treated as literal filename characters, not patterns.

.PARAMETER NameOrPath
  The executable string to resolve. May be:

.OUTPUTS
  System.String or $null

  The fully qualified path of the resolved executable, or $null if resolution fails.

.EXAMPLE
        - 'notepad' -> C:\Windows\System32\notepad.exe
        - 'script'  -> C:\Tools\script.bat   (if present and PATHEXT includes .BAT)
        - 'tool'    -> C:\Bin\tool.cmd       (if present and PATHEXT includes .CMD)
        - 'tool*.exe'  -> resolves only if a file literally named "tool*.exe" exists
		- Command name:        netsh, git, cmd
		- Absolute path:       C:\Windows\System32\cmd.exe
		- Absolute path w/o ext: C:\Windows\System32\cmd
		- Relative path:       .\tools\build.cmd
		- Environment path:    %WINDIR%\system32\cmd
  Resolve-ExecutablePath netsh
  -> C:\Windows\System32\netsh.exe

  Resolve-ExecutablePath cmd
  -> C:\Windows\System32\cmd.exe

  Resolve-ExecutablePath C:\Windows\System32\cmd
  -> C:\Windows\System32\cmd.exe

  Resolve-ExecutablePath '%WINDIR%\System32\WindowsPowerShell\v1.0\powershell'
  -> C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe

  Resolve-ExecutablePath 'nonexistenttool'
  -> $null
#>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$NameOrPath,
    [string[]]$ExtsIfMissing
  )

  $s = Normalize-CommandText $NameOrPath
  if ($null -eq $s) { return $null }

  $looksLikePath = Test-LooksLikePath $s
  if ($looksLikePath) {
    if (Test-HasInvalidPathChars $s) { return $null }
    $isRooted=$false
    try { $isRooted=[IO.Path]::IsPathRooted($s) } catch { $isRooted=$false }
    if(-not $isRooted){ return $null }  # <-- your requirement: refuse relative path-like inputs
  }

  $sys32  = [Environment]::SystemDirectory
  $windir = $env:WINDIR
  if ([string]::IsNullOrWhiteSpace($windir)) { $windir = $env:SystemRoot }
  if ([string]::IsNullOrWhiteSpace($windir)) { $windir = 'C:\Windows' }

  $searchPath = Expand-EnvVarsWin32 "$sys32;$windir;$env:PATH"

  $sb = New-Object System.Text.StringBuilder 32768
  $call = {
    param([string]$name,[string]$ext)
    $sb.Length = 0
    $rc = [Win32SvcPath]::SearchPathW($searchPath,$name,$ext,[uint32]$sb.Capacity,$sb,[IntPtr]::Zero)
    if ($rc -gt 0 -and $rc -le $sb.Capacity) { $sb.ToString() } else { $null }
  }

  $ext=''
  try { $ext=[IO.Path]::GetExtension($s) } catch { $ext='' }

  if ($ext) {
    $r = & $call $s $null
    if ($r) { return $r }
    return $null
  }

  if (-not $ExtsIfMissing -or $ExtsIfMissing.Count -eq 0) {
    $ExtsIfMissing = Get-PathExtList
  } else {
    $ExtsIfMissing = $ExtsIfMissing |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ } |
      ForEach-Object { if ($_.StartsWith('.')) { $_ } else { ".$_" } } |
      Select-Object -Unique
  }

  foreach ($e in $ExtsIfMissing) {
    $r = & $call $s $e
    if ($r) { return $r }
  }

  $null
}

function Start-HealthTestVeeamRecentBackupsExist{
<#
.SYNOPSIS
Tests if recent enough Veeam VM backups exist and have reasonable sizes and returns Log-objects.
Expects at least on .VBK file and a fresh .VBM and either a fresh .VIB or a fresh .VBK

.DESCRIPTION

Needs a config file (e.g. C:\it\config\HealthTest-RecentBackupsExist.config)
Config file is json based. Examples:
	{
	  "RootPath": "\\\\10.1.2.3\\share\\path\\to\\Backups",
	  "Username": "foo",
	  "Password": "bar"
	}
Or:
	{
	  "RootPath": "C:\\path\\to\\Backups"
	}

.EXAMPLE

	Start-HealthTestVeeamRecentBackupsExist `
		-ConfigPath 'C:\it\config\HealthTest-RecentBackupsExist.config' `
		-MaxAgeHoursForVibVbm 23 `
		-MaxAgeHoursForVBK 480

#>
[CmdletBinding()]
param(
    [string]$ConfigPath = 'C:\it\config\HealthTest-RecentBackupsExist.config',
	[int]$MaxAgeHoursForVBK = 480,
	[int]$MaxAgeHoursForVibVbm=23
)

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Warning "[notice] Not running HealthTest-RecentBackupsExist because settings file does not exist: $ConfigPath"
        return
    }

    $settings = Read-JsonFile -Path $ConfigPath -Encoding UTF8

    $rootPath= $settings.RootPath
    $username=""
    $password=""
    try {
        $username = $settings.Username
        $password = $settings.Password
    } catch {}

    $driveName = $null
    $root      = $rootPath

    # Create a temp map drive for UNC paths
    if ($rootPath -like '\\*') {
        if ($username) {
            $securePwd = ConvertTo-SecureString -String $password -AsPlainText -Force
            $cred      = New-Object System.Management.Automation.PSCredential($username, $securePwd)

            $driveName = "UNC$(Get-Random -Minimum 1000 -Maximum 9999)"
            Write-Output "Creating temporary PSDrive $driveName for $rootPath using credentials from $secretsPath"
            New-PSDrive -Name $driveName -PSProvider FileSystem -Root $rootPath -Credential $cred -Scope Global -ErrorAction Stop | Out-Null

            $root = "$driveName`:\"
        } else {
            try {
                $null = Get-ChildItem $root
            } catch {
                Write-Warning "[failure] Can't access $root (try adding a username and password to config file $ConfigPath)"
                return
            }
        }
    }

    try {
        # VBM = metadata/index about the backups.
        # VIB = incremental backup (changes since last full).
        # VBK = full backup (also baseline for incremental ones).
        $fresh_vbm       = Get-RecentFilesConditional -Path $root -Pattern '*.vbm' -MinBytes (          10*1024) -MaxAgeHours $MaxAgeHoursForVibVbm
        $fresh_vib       = Get-RecentFilesConditional -Path $root -Pattern '*.vib' -MinBytes ( 1*1024*1024*1024) -MaxAgeHours $MaxAgeHoursForVibVbm
        $fresh_vbk       = Get-RecentFilesConditional -Path $root -Pattern '*.vbk' -MinBytes (10*1024*1024*1024) -MaxAgeHours $MaxAgeHoursForVibVbm
        $atleast_one_vbk = Get-RecentFilesConditional -Path $root -Pattern '*.vbk' -MinBytes (10*1024*1024*1024) -MaxAgeHours $MaxAgeHoursForVBK 

        if ($fresh_vbm -and ($fresh_vib -or $fresh_vbk) -and $atleast_one_vbk) {
            Write-Warning "[pass] Found recent Veeam backups. If you want to change the configuration edit: $ConfigPath"
        } else {
            Write-Warning ("[failure] No recent Veeam backups found at: $rootPath`nIf you want to change the configuration edit: $ConfigPath`n" + `
                "fresh_vbm=$fresh_vbm, fresh_vib=$fresh_vib, fresh_vbk=$fresh_vbk, atleast_one_vbk=$atleast_one_vbk`n" + `
                "Condition for pass is: " + `
                '($fresh_vbm -and ($fresh_vib -or $fresh_vbk) -and $atleast_one_vbk)' + `
                (ls $root|Out-String))
        }
    }
    finally {
        if ($driveName) {
            Write-Output "Removing PSDrive $driveName"
            Remove-PSDrive -Name $driveName -ErrorAction SilentlyContinue
        }
    }
}

<#
.SYNOPSIS
Returns a list of all Domain Controllers(FQDNs) using DNS SRV records.

.DESCRIPTION
Queries _ldap._tcp.dc._msdcs.<domain> via Resolve-DnsName and returns a unique set of DC hostnames.

.OUTPUTS
[System.String[]] hostnames (no trailing dot), case-insensitive unique list.

.EXAMPLE
Get-DomainControllers
Gets DCs for the current logon domain.

.NOTES
Throws if no domain can be inferred. Requires DNS reachability.
#>
function Get-DomainControllers {
  $Domain = (Get-CimInstance Win32_ComputerSystem).Domain

  if (-not $Domain) { throw "No domain detected." }
  $results = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)

  try {
    if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
      $srv = Resolve-DnsName -Type SRV ("_ldap._tcp.dc._msdcs.{0}" -f $Domain) -ErrorAction Stop
      foreach ($r in $srv) {
        if ($r.NameTarget) { [void]$results.Add(($r.NameTarget.TrimEnd('.'))) }
      }
    }
  } catch {}
  return $results
}

<#
.SYNOPSIS
Lists all Windows services along with their executable paths and vendor information. Also detects services with broken executable paths.

.DESCRIPTION
Enumerates all services on the system using Win32_Service, resolves each service's executable path from its PathName,
and inspects the executable's Authenticode signature to extract the vendor/publisher name.
Also emits failures if the executable is missing.
Returns a list of objects with ServiceName, Vendor, and ExePath properties.
#>
function Get-ServiceVendors {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param()

  $services = Get-CimInstance Win32_Service | Select-Object Name,PathName,DisplayName

  foreach($s in $services){
    $ExceptionsThrown = ""
    $exe = $null
    try {
		$rse = Resolve-ServiceExecutable $s.PathName $s.Name
		if (-not ($null -eq $rse)) {$exe = $rse.PayloadPath}
    } catch {
        $ExceptionsThrown += "[Get-ServiceVendors] Resolve failed for service [$($s.Name)]: $($_.Exception.Message)."
    }
    if([string]::IsNullOrWhiteSpace($exe)){ $exe = $null }

    $vendor = $null; $exeSHA256 = $null
    if($exe -and (Test-Path -LiteralPath $exe)){
      $r = Get-ExeVendor -Exe $exe
      $vendor = $r.Vendor
      $exeSHA256 = $r.ExeSHA256
    } else {
      $ExceptionsThrown += "Service $($s.Name) points to missing executable. Exe='$exe' PathName='$($s.PathName)'."
    }

    [pscustomobject]@{
      ServiceName = $s.Name
      Vendor      = $vendor
      ExePath     = $exe
      ExeSHA256   = $exeSHA256
      DisplayName = $s.DisplayName
      ExceptionsThrown  = $ExceptionsThrown
    }
  }
}

<#
.SYNOPSIS
 Return free space in GB for a drive or path.
.OUTPUTS   System.Double (GB) or $null if undeterminable.
.NOTES     Resolves a path to its drive root; tries PSDrive then .NET DriveInfo.
#>
function Get-FreeGB {
    param([Parameter(Mandatory)][string]$PathOrDrive)

    # Resolve to a drive root like 'C:\'
    $root = $null
    if ($PathOrDrive -match '^[A-Za-z]:\\?$' -or $PathOrDrive -match '^[A-Za-z]:$') {
        $root = ($PathOrDrive.Substring(0,2) + '\')
    } else {
        try {
            $resolved = Resolve-Path -LiteralPath $PathOrDrive -ErrorAction Stop
            $root = [System.IO.Path]::GetPathRoot($resolved.Path)
        } catch { return $null }
    }

    # Try PSDrive first
    try {
        $name = $root.TrimEnd('\').TrimEnd(':')
        $psd  = Get-PSDrive -Name $name -PSProvider FileSystem -ErrorAction Stop
        if ($null -ne $psd.Free) { return [math]::Round(([double]$psd.Free)/1GB,2) }
    } catch {}

    # Fallback to .NET DriveInfo
    try {
        $di = [System.IO.DriveInfo]::new($root)
        if ($di.IsReady) { return [math]::Round($di.AvailableFreeSpace/1GB,2) }
    } catch {}

    return $null
}

Function Get-WindowsOriginalInstallDate {
    <#
    .SYNOPSIS
        Robustly determines the Windows Installation date.
    .DESCRIPTION
        Aggregates dates from Registry History (for original install),
        Current Registry, and WMI. Returns the oldest valid date found.
        If history is missing, it gracefully falls back to the latest
        feature update date.
    #>
    [CmdletBinding()]
    param()

    process {
        # List to hold all potential dates found
        $candidateDates = New-Object System.Collections.Generic.List[DateTime]

        # Unix Epoch for converting Registry timestamps
        $unixEpoch = (Get-Date -Date "01/01/1970").ToLocalTime()

        # --- LAYER 1: The "Source OS" History (The Real Original Date) ---
        # Windows archives old install dates here during feature updates.
        try {
            $setupKey = "HKLM:\SYSTEM\Setup"
            if (Test-Path $setupKey) {
                # Find keys like "Source OS (Updated on...)"
                $sourceKeys = Get-ChildItem -Path $setupKey -ErrorAction SilentlyContinue |
                              Where-Object { $_.Name -like "*Source OS*" }

                foreach ($key in $sourceKeys) {
                    $prop = Get-ItemProperty -Path $key.PSPath -Name "InstallDate" -ErrorAction SilentlyContinue
                    if ($prop -and $prop.InstallDate -is [Int32] -or $prop.InstallDate -is [Int64]) {
                        # Add to candidates
                        $candidateDates.Add($unixEpoch.AddSeconds($prop.InstallDate))
                    }
                }
            }
        }
        catch {
            Write-Verbose "Could not access Registry History: $_"
        }

        # --- LAYER 2: The Current Registry (The Feature Update Date) ---
        # Usually represents the last major update (e.g., 22H2).
        try {
            $currentPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
            $currentProp = Get-ItemProperty -Path $currentPath -Name "InstallDate" -ErrorAction SilentlyContinue

            if ($currentProp -and $currentProp.InstallDate) {
                $candidateDates.Add($unixEpoch.AddSeconds($currentProp.InstallDate))
            }
        }
        catch {
            Write-Verbose "Could not access Current Registry: $_"
        }

        # --- LAYER 3: WMI Fallback (The Safety Net) ---
        # If Registry is totally unreadable, WMI usually works.
        # This usually matches Layer 2, but serves as a backup.
        try {
            $wmiOS = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
            if ($wmiOS -and $wmiOS.InstallDate) {
                $candidateDates.Add($wmiOS.InstallDate)
            }
        }
        catch {
            Write-Verbose "Could not access WMI: $_"
        }

        # --- FINAL DECISION ---
        # 1. Remove duplicates and Sort
        # 2. Pick the FIRST one (The Oldest)

        if ($candidateDates.Count -gt 0) {
            $finalDate = ($candidateDates | Sort-Object)[0]

            # Determine confidence level for the output
            $methodUsed = if ($candidateDates.Count -gt 1) { "Historical Analysis" } else { "Current Feature Update (Fallback)" }

            return [PSCustomObject]@{
                InstallDate = $finalDate
                Confidence  = $methodUsed
                AgeDays     = (New-TimeSpan -Start $finalDate -End (Get-Date)).Days
            }
        }
        else {
            # Absolute worst case: return current time (should theoretically never happen on a working OS)
            Write-Warning "Critical Failure: No install date found in Registry or WMI."
            return [PSCustomObject]@{
                InstallDate = (Get-Date)
                Confidence  = "Error - Date Not Found"
                AgeDays     = 0
            }
        }
    }
}

function Get-PropValue {
# returns a default value if object does not have a property with that name.
# The default value for the default value returned is $null but you can Set
# $default to anything else.
    param($obj, [string]$name, $default=$null)
    if ($obj -and $obj.PSObject -and $obj.PSObject.Properties[$name]) {
        return $obj.PSObject.Properties[$name].Value
    }
    return $default
}

function Test-IsRdsLicensingServer {
  [CmdletBinding()]
  [OutputType([bool])]
  param()

  # 1 = Workstation 2 = Domain Controller 3 = Windows Server
  $host_type = (Get-CimInstance Win32_OperatingSystem).ProductType
  if ($host_type -eq 1) { return $false }

  # Detect by service first (works on Server Core and PS7+)
  try {
    $svc = Get-Service -Name 'TermServLicensing' -ErrorAction SilentlyContinue
    if ($svc) { return $true }
  } catch {}

  # Fallback to ServerManager feature check (only works if ServerManager module exists)
  try {
    Import-Module ServerManager -ErrorAction Stop
    $feat = Get-WindowsFeature -Name RDS-Licensing -ErrorAction SilentlyContinue
    if ($feat -and $feat.Installed) { return $true }
  } catch {}

  return $false
}

<#
.SYNOPSIS  Check a drive/path and emit a status; returns an object with details.
.PARAMETER PathOrDrive  Drive letter or any path.
.PARAMETER WarnPct      Warning threshold (default 10).
.PARAMETER ErrorPct     Error threshold (default 5).
.OUTPUTS   PSCustomObject with Drive,Type,FreeGB,TotalGB,PercentFree,Level; or nothing if not applicable.
#>
function Test-DiskHasFreeSpace {
    param(
        [Parameter(Mandatory)][string]$PathOrDrive,
        [double]$WarnPct = 10,
        [double]$ErrorPct = 5
    )

    $root = $null
    if ($PathOrDrive -match '^[A-Za-z]:\\?$' -or $PathOrDrive -match '^[A-Za-z]:$') {
        $root = ($PathOrDrive.Substring(0,2) + '\')
    } else {
        try {
            $resolved = Resolve-Path -LiteralPath $PathOrDrive -ErrorAction Stop
            $root = [System.IO.Path]::GetPathRoot($resolved.Path)
        } catch { return }
    }

    try {
        $di = [System.IO.DriveInfo]::new($root)
    } catch { return }

    if (-not $di.IsReady) { return }

    $freeGB  = Get-FreeGB -PathOrDrive $root
    $totalGB = [math]::Round($di.TotalSize/1GB, 2)
    if ($di.TotalSize -le 0) { return }

    $pctFree = [math]::Round(($di.AvailableFreeSpace / $di.TotalSize) * 100, 2)
    if ($pctFree -lt $ErrorPct) {
        $level = 'Error'
    } elseif ($pctFree -lt $WarnPct) {
        $level = 'Warning'
    } else {
        $level = 'OK'
    }

    [pscustomobject]@{
        Drive        = $di.Name
        DriveType    = $di.DriveType.ToString()
        FreeGB       = $freeGB
        TotalGB      = $totalGB
        PercentFree  = $pctFree
        Level        = $level
    }
}

<#
.SYNOPSIS
Returns directories under Path whose observed child-item count is greater
than Threshold.

.OUTPUTS
Produces a psCustomObject for each qualifying directory:
  Path       : Full directory path
  ItemsCount : Observed count of immediate child items

.DESCRIPTION
Recursively scans the directory tree rooted at Path.
Directories that cannot be enumerated or read are skipped without a
terminating error, and results may be incomplete for that reason.
#>
function Find-LargeDirectory {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string[]]$Path = @('C:\'),

        [Parameter(Mandatory = $false)]
        [int]$Threshold = 10000,

        [Parameter(Mandatory = $false)]
        [string[]]$SkipPaths = @()
    )

    function Normalize-DirectoryPath {
        param(
            [Parameter(Mandatory)]
            [string]$CandidatePath
        )

        if ($CandidatePath -match '^[a-zA-Z]:\\$') {
            return $CandidatePath
        }

        return $CandidatePath.TrimEnd('\\')
    }

    $normalizedSkipPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($skipPath in $SkipPaths) {
        if ([string]::IsNullOrWhiteSpace($skipPath)) { continue }

        try {
            $resolvedSkipPath = Normalize-DirectoryPath -CandidatePath (Resolve-Path -LiteralPath $skipPath -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Path)
            [void]$normalizedSkipPaths.Add($resolvedSkipPath)
        }
        catch {}
    }

    function Visit-DirectoryForLargeCount {
        param (
            [Parameter(Mandatory)]
            [string]$CurrentPath
        )

        $normalizedCurrentPath = Normalize-DirectoryPath -CandidatePath $CurrentPath
        if ($normalizedSkipPaths.Contains($normalizedCurrentPath)) {
            return
        }

        try {
            $children = @(Get-ChildItem -LiteralPath $CurrentPath -ErrorAction Stop)
        }
        catch {
            return
        }

        $count = ($children | Measure-Object).Count
        if ($count -gt $Threshold) {
            [PSCustomObject]@{
                Path       = $CurrentPath
                ItemsCount = $count
            }
        }

        foreach ($childDir in $children) {
            if (-not $childDir.PSIsContainer) { continue }

            $childPath = Normalize-DirectoryPath -CandidatePath $childDir.FullName
            if ($normalizedSkipPaths.Contains($childPath)) {
                continue
            }

            Visit-DirectoryForLargeCount -CurrentPath $childDir.FullName
        }
    }

    foreach ($rootPath in $Path) {
        if ([string]::IsNullOrWhiteSpace($rootPath)) { continue }

        try {
            $resolvedRootPath = Normalize-DirectoryPath -CandidatePath (Resolve-Path -LiteralPath $rootPath -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Path)
            Write-Verbose "Scanning '$resolvedRootPath' for directories with > $Threshold items..."
            Visit-DirectoryForLargeCount -CurrentPath $resolvedRootPath
        }
        catch {}
    }
}

<#
.SYNOPSIS
Tests if the most recent Windows Defender scan is within a given number of days.

.DESCRIPTION
This function queries Microsoft Defender Antivirus status with Get-MpComputerStatus.
It checks available scan end times (Full and Quick scans) and falls back to age counters
if no timestamps exist. It then compares the most recent scan against a threshold.
Returns this info:
[pscustomobject]@{Pass=$true/$false; DaysSinceScan=N; Details='Human readable details'}

.PARAMETER Days
Number of days allowed since the last scan (default 3).

.NOTES
- On Windows Server, Defender does not schedule scans by default. If none were run,
  this function may report "No scan timestamps or ages".
- Requires Microsoft Defender Antivirus (Get-MpComputerStatus).
#>
function Get-DaysSinceLastVirusScan {
  [CmdletBinding()] param([int]$Days=3)
  try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch {
    return [pscustomobject]@{DaysSinceScan=$null;Details="Get-MpComputerStatus failed with error $_.Exception.Message"}
  }

  $ts = @()
  foreach($p in 'FullScanEndTime','QuickScanEndTime','FullScanStartTime','QuickScanStartTime'){
    $v = $mp.$p
    if ($v) { try { $ts += [datetime]$v } catch {} }
  }
  $last = $null
  if ($ts.Count -gt 0) { $last = ($ts | Sort-Object -Descending)[0] }

  if ($last) {
    $ageDays = ((Get-Date) - $last).TotalDays
    $ok = ($ageDays -le $Days)
    return [pscustomobject]@{DaysSinceScan=[math]::Round($ageDays,1);Details='Source: Time'}
  }

  $ages = @()
  foreach($ap in 'FullScanAge','QuickScanAge'){
    $av = $mp.$ap
    if ($null -ne $av) { $ages += [int64]$av }
  }
  if ($ages.Count -gt 0) {
    $minAge = ($ages | Measure-Object -Minimum).Minimum
    $ok = ($minAge -le $Days)
    return [pscustomobject]@{DaysSinceScan=$minAge;Details='Source: Age'}
  }

  return [pscustomobject]@{DaysSinceScan=$null;Details='No scan timestamps or ages'}
}


function Split-FirstToken {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$CommandLine)

  $c = $CommandLine.Trim()
  if ([string]::IsNullOrWhiteSpace($c)) { return ,@($null,'') }

  if ($c[0] -eq '"' -or $c[0] -eq "'") {
    $q = $c[0]; $i = 1
    while ($i -lt $c.Length -and $c[$i] -ne $q) { $i++ }
    $tok = if ($i -lt $c.Length) { $c.Substring(1,$i-1) } else { $c.Substring(1) }
    $rest = if ($i -lt $c.Length) { $c.Substring($i+1).Trim() } else { '' }
    return ,@($tok,$rest)
  }

  $i=0
  while ($i -lt $c.Length -and -not [char]::IsWhiteSpace($c[$i])) { $i++ }
  ,@($c.Substring(0,$i), $c.Substring($i).Trim())
}


function Split-FirstTokenSmart {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$CommandLine)

  $c=$CommandLine
  if([string]::IsNullOrWhiteSpace($c)){ return ,@($null,'') }

  $useWin32 = $false
  $t = $c.TrimStart()
  if($t.StartsWith('"')){ $useWin32 = $true }        # common service form: "C:\Path\svc.exe" args...

  if($useWin32){
    try {
      $argv = Split-FirstTokenWin32Argv $c
      if($argv -and $argv.Count -ge 1 -and $argv[0]){
        $tok = $argv[0]

        # Best-effort: find end of the first token in the ORIGINAL string to preserve "rest" verbatim-ish.
        $u = $c.TrimStart()
        if($u.StartsWith('"')){
          $pos=1
          while($true){
            $q = $u.IndexOf('"',$pos)
            if($q -lt 0){ break }
            $inside = $u.Substring(1,$q-1)
            if($inside -ieq $tok){
              $rest = $u.Substring($q+1).Trim()
              return ,@($tok,$rest)
            }
            $pos = $q+1
          }
        } else {
          if($u.StartsWith($tok,[StringComparison]::OrdinalIgnoreCase)){
            $rest = $u.Substring($tok.Length).Trim()
            return ,@($tok,$rest)
          }
        }
      }
    } catch {}
  }

  Split-FirstToken $c
}


function Split-FirstTokenWin32Argv {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$CommandLine)
  $n=0; $p=[IntPtr]::Zero
  try {
    $p = [Win32SvcPath]::CommandLineToArgvW($CommandLine, [ref]$n)
    if ($p -eq [IntPtr]::Zero -or $n -le 0) { return $null }
    $argv = New-Object string[] $n
    for($i=0;$i -lt $n;$i++){
      $argv[$i] = [Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::ReadIntPtr($p, $i*[IntPtr]::Size))
    }
    $argv
  } finally {
    if ($p -ne [IntPtr]::Zero) { [void][Win32SvcPath]::LocalFree($p) }
  }
}


function Split-Rundll32DllToken {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Token)

  $t = Strip-SurroundingQuotes $Token
  $inQ=$false; $q=[char]0
  for($i=0;$i -lt $t.Length;$i++){
    $c=$t[$i]
    if ($c -eq '"' -or $c -eq "'") {
      if (-not $inQ) { $inQ=$true; $q=$c }
      elseif ($q -eq $c) { $inQ=$false }
    } elseif ($c -eq ',' -and -not $inQ) {
      return ,@($t.Substring(0,$i).Trim(), $t.Substring($i+1).Trim())
    }
  }
  ,@($t.Trim(), $null)
}


function Strip-SurroundingQuotes {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Text)

  $s=$Text.Trim()
  if($s.Length -ge 2 -and (($s[0] -eq '"' -and $s[$s.Length-1] -eq '"') -or ($s[0] -eq "'" -and $s[$s.Length-1] -eq "'"))){
    $q=$s[0]
    $inner=$s.Substring(1,$s.Length-2)
    if($q -eq '"'){
      if($inner -match '(?<!\\)"'){ return $s }  # don't strip if inner has a "
    } else {
      if($inner -match "'"){ return $s }         # conservative for single quotes
    }
    return $inner
  }
  $s
}

# --- Resolve-ServiceExecutable Helper:
# Identify path-like strings (rooted, contains slash, or \SystemRoot\...) ---
function Test-LooksLikePath {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Text)
  $s=$Text
  $isRooted=$false
  try { $isRooted=[IO.Path]::IsPathRooted($s) } catch { $isRooted=$false }
  ($isRooted -or ($s -match '[\\/]') -or $s.StartsWith('\SystemRoot\',[StringComparison]::OrdinalIgnoreCase))
}

# --- Resolve-ServiceExecutable Helper:
# Strict invalid-path-char check for *paths* (returns $true => treat as invalid => return $null) ---
function Test-HasInvalidPathChars {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Text)
  if ($Text -match '[\x00-\x1F"<>|]') { return $true }     # control chars + common illegal
  if ($Text -match '[*?]') { return $true }               # wildcard chars are illegal in Win paths (and we treat as literal)
  $i = $Text.IndexOf(':')
  if ($i -ge 0) {
    if ($i -ne 1 -or $Text.Length -lt 2 -or $Text[0] -notmatch '[A-Za-z]') { return $true }
    if ($Text.IndexOf(':', 2) -ge 0) { return $true }
  }
  $false
}

# --- Resolve-ServiceExecutable Helper:
# PATHEXT list normalized (always includes .EXE) ---
function Get-PathExtList {
  [CmdletBinding()]
  param()
  $exts=@()
  if ($env:PATHEXT) { $exts += ($env:PATHEXT -split ';') }
  $exts += '.EXE'
  $exts | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { if ($_.StartsWith('.')) { $_ } else { ".$_" } } | Select-Object -Unique
}

# --- Resolve-ServiceExecutable Helper: 
# Split the first token from a command line (handles leading quotes); returns @($token,$rest) ---
function Split-FirstToken {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$CommandLine)

  $c = $CommandLine.Trim()
  if ([string]::IsNullOrWhiteSpace($c)) { return ,@($null,'') }

  if ($c[0] -eq '"' -or $c[0] -eq "'") {
    $q = $c[0]; $i = 1
    while ($i -lt $c.Length -and $c[$i] -ne $q) { $i++ }
    $tok = if ($i -lt $c.Length) { $c.Substring(1,$i-1) } else { $c.Substring(1) }
    $rest = if ($i -lt $c.Length) { $c.Substring($i+1).Trim() } else { '' }
    return ,@($tok,$rest)
  }

  $i=0
  while ($i -lt $c.Length -and -not [char]::IsWhiteSpace($c[$i])) { $i++ }
  ,@($c.Substring(0,$i), $c.Substring($i).Trim())
}

# --- Resolve-ServiceExecutable Helper: 
# Progressive probing for unquoted path-with-spaces ambiguity (audit + best-effort resolution) ---
function Probe-UnquotedServicePath {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$CommandLineDequoted,
    [Parameter(Mandatory)][string[]]$Exts
  )
  $c=$CommandLineDequoted.Trim()
  if ([string]::IsNullOrWhiteSpace($c)) { return $null }
  if ($c -notmatch '\s') { return $null }

  $spaces=@()
  for($i=0;$i -lt $c.Length;$i++){ if($c[$i] -eq ' '){ $spaces += $i } }

  foreach($pos in $spaces){
    $cand = $c.Substring(0,$pos).Trim()
    if (-not (Test-LooksLikePath $cand)) { continue }
    $resolved = Resolve-ExecutablePath $cand -ExtsIfMissing $Exts
    if ($resolved) {
      $rest = $c.Substring($pos).Trim()
      return ,@($resolved,$rest)
    }
  }
  $null
}

# ---Resolve-ServiceExecutable  Helper: 
# Parse rundll32's "dll,EntryPoint" token safely (comma outside quotes) ---
function Split-Rundll32DllToken {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Token)

  $t = Strip-SurroundingQuotes $Token
  $inQ=$false; $q=[char]0
  for($i=0;$i -lt $t.Length;$i++){
    $c=$t[$i]
    if ($c -eq '"' -or $c -eq "'") {
      if (-not $inQ) { $inQ=$true; $q=$c }
      elseif ($q -eq $c) { $inQ=$false }
    } elseif ($c -eq ',' -and -not $inQ) {
      return ,@($t.Substring(0,$i).Trim(), $t.Substring($i+1).Trim())
    }
  }
  ,@($t.Trim(), $null)
}

function Get-ServiceDllFromReg {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$SvcName)

  $svcKey="Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$SvcName"

  $candidates=@(
    @{Path="$svcKey\Parameters"; Name='ServiceDll'},
    @{Path="$svcKey\Parameters"; Name='ServiceDllEx'},
    @{Path="$svcKey";           Name='ServiceDll'},
    @{Path="$svcKey";           Name='ServiceDllEx'}
  )

  foreach($c in $candidates){
    try{
      $v=(Get-ItemProperty -Path $c.Path -Name $c.Name -ErrorAction SilentlyContinue).($c.Name)
      if($v){ return [pscustomobject]@{ Value=$v; Where="$($c.Path)\$($c.Name)" } }
    } catch {}
  }

  $null
}

# --- Resolve service launcher EXE and (when possible) the real payload (EXE/DLL/SYS) ---
function Resolve-ServiceExecutable {
<#
.SYNOPSIS
  Resolve the launcher executable and the underlying payload referenced by a service launch command.

.DESCRIPTION
  Input:
    - LaunchCommand: a service ImagePath/PathName-style command line (may include quotes, env vars, args, rundll32, svchost, etc.)
    - ServiceName  : short service name (used for registry lookups like Parameters\ServiceDll and service Type)

  Output:
    - LauncherExe, LauncherArgs
    - PayloadType: Exe | DllViaRundll32 | DllViaSvchost | DriverSys | Unknown
    - PayloadPath (when determinable)
    - Warnings (e.g., unquoted path ambiguity)

  Debugging:
    Use -Verbose or set $VerbosePreference='Continue' to see step-by-step resolution decisions.

.EXAMPLE
  Resolve-ServiceExecutable -LaunchCommand '"C:\Program Files\App\svc.exe" -k run' -ServiceName 'AppSvc' -Verbose
#>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$LaunchCommand,
    [Parameter(Mandatory)][string]$ServiceName
  )
  
  function Get-BaseServiceName {
    param([Parameter(Mandatory)][string]$ServiceName)
  
    $m=[regex]::Match($ServiceName,'^(?<base>.+?)_(?<hex>[0-9a-fA-F]{5,16})$')
    if(-not $m.Success){ return $ServiceName }
  
    $base=$m.Groups['base'].Value
    $baseKey="Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$base"
    if(Test-Path -LiteralPath $baseKey){ return $base }
  
    $ServiceName
  }


  $warnings = New-Object System.Collections.Generic.List[string]

  $raw = $LaunchCommand
  $san = Normalize-CommandText $raw -NoDequote
  Write-Verbose "[Resolve-ServiceExecutable] OriginalLaunchCommand=<$raw>"
  Write-Verbose "[Resolve-ServiceExecutable] SanitizedCommandLine=<$san>"

  if ([string]::IsNullOrWhiteSpace($san)) {
    $warnings.Add("LaunchCommand is empty; cannot determine launcher or payload.")
    return [pscustomobject]@{
      OriginalLaunchCommand = $raw
      ServiceName          = $ServiceName
      SanitizedCommandLine = $san
      LauncherExe          = $null
      LauncherArgs         = ''
      PayloadType          = 'Unknown'
      PayloadPath          = $null
      PayloadDetails       = $null
      Warnings             = @($warnings)
    }
  }

  $extsExe = Get-PathExtList

  $launcherToken = $null
  $launcherArgs  = ''
  $launcherPath  = $null

  $sanDequoted = Normalize-CommandText $san -NoDequote -NoExpandEnv -NoNormalizeSystemRoot
  Write-Verbose "[Resolve-ServiceExecutable] SanitizedDequoted=<$sanDequoted>"

  if (Test-LooksLikePath $sanDequoted) {
    Write-Verbose "[Resolve-ServiceExecutable] BypassCheck: looks like path"
    if (Test-HasInvalidPathChars $sanDequoted) {
      Write-Verbose "[Resolve-ServiceExecutable] BypassCheck: invalid path chars -> return null launcher"
    } elseif (Test-Path -LiteralPath $sanDequoted -PathType Leaf) {
      $launcherToken = $sanDequoted
      $launcherArgs  = ''
      $launcherPath  = (Get-Item -LiteralPath $sanDequoted).FullName
      Write-Verbose "[Resolve-ServiceExecutable] BypassCheck: existing file -> launcherPath=<$launcherPath> (skip parsing)"
    }
  }

  if (-not $launcherPath) {
    $pair = Split-FirstTokenSmart $san
    $launcherToken = $pair[0]
    $launcherArgs  = $pair[1]
    Write-Verbose "[Resolve-ServiceExecutable] ParsedFirstToken: token=<$launcherToken> args=<$launcherArgs>"
  }

  # Warn only for the classic case: the EXE PATH itself contains spaces and wasn't quoted
  # (i.e., ambiguous "C:\Program Files\..." style)
  if ($san -match '\s' -and -not $san.TrimStart().StartsWith('"') -and -not $san.TrimStart().StartsWith("'")) {
    $first = $launcherToken
    if ($first -and (Test-LooksLikePath $first) -and ($first -match '\s')) {
      $warnings.Add("Unquoted executable path contains spaces; command line is ambiguous (classic 'unquoted service path' pattern). Attempting progressive probing.")
      Write-Verbose "[Resolve-ServiceExecutable] Warning: unquoted executable path with spaces detected"
    }
  }


  Write-Verbose "[Resolve-ServiceExecutable] LauncherToken=<$launcherToken>"
  if (-not $launcherPath) {
    $launcherPath = Resolve-ExecutablePath -NameOrPath $launcherToken -ExtsIfMissing $extsExe
  }
  Write-Verbose "[Resolve-ServiceExecutable] LauncherPath=<$launcherPath>"

  if (-not $launcherPath) {
    $pp = Probe-UnquotedServicePath -CommandLineDequoted $sanDequoted -Exts $extsExe
    if ($pp) {
      $launcherPath = $pp[0]
      $launcherArgs = $pp[1]
      Write-Verbose "[Resolve-ServiceExecutable] ProgressiveProbe: launcherPath=<$launcherPath> args=<$launcherArgs>"
    }
  }

  # (payload logic unchanged from your version)
  $payloadType='Unknown'; $payloadPath=$null; $payloadDetails=$null
  if ($launcherPath) {
    $launcherLeaf = [IO.Path]::GetFileName($launcherPath)
    $svcKey  = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$ServiceName"
    $svcType = $null
    try { $svcType = (Get-ItemProperty -Path $svcKey -Name Type -ErrorAction SilentlyContinue).Type } catch {}
    $isDriver=$false
    if ($svcType -ne $null) { if (($svcType -band 1) -or ($svcType -band 2)) { $isDriver=$true } }

    if ($isDriver -or ($launcherLeaf -match '\.sys$')) {
      $payloadType='DriverSys'; $payloadPath=$launcherPath; $payloadDetails='Driver-style service (kernel/filesystem driver).'
    } elseif ($launcherLeaf -ieq 'rundll32.exe') {
      $payloadType='DllViaRundll32'
      $pair2 = Split-FirstTokenSmart $launcherArgs
      $dllTokenPlus = $pair2[0]
      if ($dllTokenPlus) {
        $dllPair = Split-Rundll32DllToken $dllTokenPlus
        $dllToken=$dllPair[0]; $entry=$dllPair[1]
        $dllPath = Resolve-ExecutablePath -NameOrPath $dllToken -ExtsIfMissing @('.DLL','.CPL')
        $payloadPath = $dllPath
        $payloadDetails = [pscustomobject]@{ DllToken=$dllToken; EntryPoint=$entry }
      } else {
        $warnings.Add("rundll32.exe detected but DLL token could not be parsed from arguments.")
      }
    } elseif ($launcherLeaf -ieq 'svchost.exe') {
      $payloadType='DllViaSvchost'
    
      $svcDll=$null; $svcDllWhere=$null
    
      $hit = Get-ServiceDllFromReg -SvcName $ServiceName
      if($hit){ $svcDll=$hit.Value; $svcDllWhere=$hit.Where }
    
      if(-not $svcDll){
        $base = Get-BaseServiceName $ServiceName
        if($base -and $base -ne $ServiceName){
          $hit2 = Get-ServiceDllFromReg -SvcName $base
          if($hit2){ $svcDll=$hit2.Value; $svcDllWhere="$($hit2.Where) (base of $ServiceName)" }
        }
      }
    
      if ($svcDll) {
        $svcDllNorm = Normalize-CommandText $svcDll -NoDequote
        $dllPath = Resolve-ExecutablePath -NameOrPath $svcDllNorm -ExtsIfMissing @('.DLL')
        $payloadPath = $dllPath
        $payloadDetails = [pscustomobject]@{ ServiceDll=$svcDllNorm; Registry=$svcDllWhere }
      } else {
        $warnings.Add("svchost.exe detected but ServiceDll/ServiceDllEx not found for '$ServiceName' (checked service key + Parameters, and base service if applicable). Falling back to launcher executable as payload path.")
        $payloadPath = $launcherPath
        $payloadDetails = [pscustomobject]@{ Fallback='LauncherExe'; Reason='No ServiceDll/ServiceDllEx found' }
      }
    } else {
      $payloadType='Exe'; $payloadPath=$launcherPath
    }
  } else {
    $warnings.Add("Launcher executable could not be resolved from LaunchCommand.")
  }

  [pscustomobject]@{
    OriginalLaunchCommand = $raw
    ServiceName          = $ServiceName
    SanitizedCommandLine = $san
    LauncherExe          = $launcherPath
    LauncherArgs         = $launcherArgs
    PayloadType          = $payloadType
    PayloadPath          = $payloadPath
    PayloadDetails       = $payloadDetails
    Warnings             = @($warnings)
  }
}


function Resolve-ExecutablePath {
<#
.SYNOPSIS
  Locate the actual executable file that Windows would run.

.DESCRIPTION
  This function wraps the Win32 API SearchPathW to locate the actual executable file that Windows would run,
  while adding important safety, correctness, and robustness features expected in modern PowerShell tooling.
  It provides behavior closely aligned with CreateProcess and CMD executable resolution.     If no executable is found, the function returns $null.
   - It never throws exceptions for normal resolution failures.
   - If input is path-like AND NOT rooted, returns $null (refuses relative paths)

  The function follows a strict, deterministic resolution strategy with literal semantics (no wildcard expansion),
  predictable behavior, and explicit PATHEXT probing.
  If the input looks like a path (rooted, relative with \ or /, or \SystemRoot\... after normalization), 
  the function does not search $env:PATH, System32, Windows, or the current directory to 
  "find something else". It only checks whether the explicit path exists as given and, if the input has 
  no extension, it performs extension probing (PATHEXT or -ExtsIfMissing) against that same explicit path.
  If no match is found, it returns $null.

  Resolution proceeds through these stages:

  - If the input appears to be a path but contains illegal filesystem characters it returns $null instead 
  of throwing.
  - If the input does not include an extension, the function probes all extensions in $env:PATHEXT
     (plus .EXE to guarantee coverage), exactly like CMD and CreateProcess.
  - Wildcard characters (* ? [ ]) are treated as literal filename characters, not patterns.

.PARAMETER NameOrPath
  The executable string to resolve. May be:

.OUTPUTS
  System.String or $null

  The fully qualified path of the resolved executable, or $null if resolution fails.

.EXAMPLE
        - 'notepad' -> C:\Windows\System32\notepad.exe
        - 'script'  -> C:\Tools\script.bat   (if present and PATHEXT includes .BAT)
        - 'tool'    -> C:\Bin\tool.cmd       (if present and PATHEXT includes .CMD)
        - 'tool*.exe'  -> resolves only if a file literally named "tool*.exe" exists
		- Command name:        netsh, git, cmd
		- Absolute path:       C:\Windows\System32\cmd.exe
		- Absolute path w/o ext: C:\Windows\System32\cmd
		- Relative path:       .\tools\build.cmd
		- Environment path:    %WINDIR%\system32\cmd
  Resolve-ExecutablePath netsh
  -> C:\Windows\System32\netsh.exe

  Resolve-ExecutablePath cmd
  -> C:\Windows\System32\cmd.exe

  Resolve-ExecutablePath C:\Windows\System32\cmd
  -> C:\Windows\System32\cmd.exe

  Resolve-ExecutablePath '%WINDIR%\System32\WindowsPowerShell\v1.0\powershell'
  -> C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe

  Resolve-ExecutablePath 'nonexistenttool'
  -> $null
#>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$NameOrPath,
    [string[]]$ExtsIfMissing
  )

  $s = Normalize-CommandText $NameOrPath
  if ($null -eq $s) { return $null }

  $looksLikePath = Test-LooksLikePath $s
  if ($looksLikePath) {
    if (Test-HasInvalidPathChars $s) { return $null }
    $isRooted=$false
    try { $isRooted=[IO.Path]::IsPathRooted($s) } catch { $isRooted=$false }
    if(-not $isRooted){ return $null }  # <-- your requirement: refuse relative path-like inputs
  }

  $sys32  = [Environment]::SystemDirectory
  $windir = $env:WINDIR
  if ([string]::IsNullOrWhiteSpace($windir)) { $windir = $env:SystemRoot }
  if ([string]::IsNullOrWhiteSpace($windir)) { $windir = 'C:\Windows' }

  $searchPath = Expand-EnvVarsWin32 "$sys32;$windir;$env:PATH"

  $sb = New-Object System.Text.StringBuilder 32768
  $call = {
    param([string]$name,[string]$ext)
    $sb.Length = 0
    $rc = [Win32SvcPath]::SearchPathW($searchPath,$name,$ext,[uint32]$sb.Capacity,$sb,[IntPtr]::Zero)
    if ($rc -gt 0 -and $rc -le $sb.Capacity) { $sb.ToString() } else { $null }
  }

  $ext=''
  try { $ext=[IO.Path]::GetExtension($s) } catch { $ext='' }

  if ($ext) {
    $r = & $call $s $null
    if ($r) { return $r }
    return $null
  }

  if (-not $ExtsIfMissing -or $ExtsIfMissing.Count -eq 0) {
    $ExtsIfMissing = Get-PathExtList
  } else {
    $ExtsIfMissing = $ExtsIfMissing |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ } |
      ForEach-Object { if ($_.StartsWith('.')) { $_ } else { ".$_" } } |
      Select-Object -Unique
  }

  foreach ($e in $ExtsIfMissing) {
    $r = & $call $s $e
    if ($r) { return $r }
  }

  $null
}

function Start-HealthTestVeeamRecentBackupsExist{
<#
.SYNOPSIS
Tests if recent enough Veeam VM backups exist and have reasonable sizes and returns Log-objects.
Expects at least on .VBK file and a fresh .VBM and either a fresh .VIB or a fresh .VBK

.DESCRIPTION

Needs a config file (e.g. C:\it\config\HealthTest-RecentBackupsExist.config)
Config file is json based. Examples:
	{
	  "RootPath": "\\\\10.1.2.3\\share\\path\\to\\Backups",
	  "Username": "foo",
	  "Password": "bar"
	}
Or:
	{
	  "RootPath": "C:\\path\\to\\Backups"
	}

.EXAMPLE

	Start-HealthTestVeeamRecentBackupsExist `
		-ConfigPath 'C:\it\config\HealthTest-RecentBackupsExist.config' `
		-MaxAgeHoursForVibVbm 23 `
		-MaxAgeHoursForVBK 480

#>
[CmdletBinding()]
param(
    [string]$ConfigPath = 'C:\it\config\HealthTest-RecentBackupsExist.config',
	[int]$MaxAgeHoursForVBK = 480,
	[int]$MaxAgeHoursForVibVbm=23
)

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Warning "[notice] Not running HealthTest-RecentBackupsExist because settings file does not exist: $ConfigPath"
        return
    }

    $settings = Read-JsonFile -Path $ConfigPath -Encoding UTF8

    $rootPath= $settings.RootPath
    $username=""
    $password=""
    try {
        $username = $settings.Username
        $password = $settings.Password
    } catch {}

    $driveName = $null
    $root      = $rootPath

    # Create a temp map drive for UNC paths
    if ($rootPath -like '\\*') {
        if ($username) {
            $securePwd = ConvertTo-SecureString -String $password -AsPlainText -Force
            $cred      = New-Object System.Management.Automation.PSCredential($username, $securePwd)

            $driveName = "UNC$(Get-Random -Minimum 1000 -Maximum 9999)"
            Write-Output "Creating temporary PSDrive $driveName for $rootPath using credentials from $secretsPath"
            New-PSDrive -Name $driveName -PSProvider FileSystem -Root $rootPath -Credential $cred -Scope Global -ErrorAction Stop | Out-Null

            $root = "$driveName`:\"
        } else {
            try {
                $null = Get-ChildItem $root
            } catch {
                Write-Warning "[failure] Can't access $root (try adding a username and password to config file $ConfigPath)"
                return
            }
        }
    }

    try {
        # VBM = metadata/index about the backups.
        # VIB = incremental backup (changes since last full).
        # VBK = full backup (also baseline for incremental ones).
        $fresh_vbm       = Get-RecentFilesConditional -Path $root -Pattern '*.vbm' -MinBytes (          10*1024) -MaxAgeHours $MaxAgeHoursForVibVbm
        $fresh_vib       = Get-RecentFilesConditional -Path $root -Pattern '*.vib' -MinBytes ( 1*1024*1024*1024) -MaxAgeHours $MaxAgeHoursForVibVbm
        $fresh_vbk       = Get-RecentFilesConditional -Path $root -Pattern '*.vbk' -MinBytes (10*1024*1024*1024) -MaxAgeHours $MaxAgeHoursForVibVbm
        $atleast_one_vbk = Get-RecentFilesConditional -Path $root -Pattern '*.vbk' -MinBytes (10*1024*1024*1024) -MaxAgeHours $MaxAgeHoursForVBK 

        if ($fresh_vbm -and ($fresh_vib -or $fresh_vbk) -and $atleast_one_vbk) {
            Write-Warning "[pass] Found recent Veeam backups. If you want to change the configuration edit: $ConfigPath"
        } else {
            Write-Warning ("[failure] No recent Veeam backups found at: $rootPath`nIf you want to change the configuration edit: $ConfigPath`n" + `
                "fresh_vbm=$fresh_vbm, fresh_vib=$fresh_vib, fresh_vbk=$fresh_vbk, atleast_one_vbk=$atleast_one_vbk`n" + `
                "Condition for pass is: " + `
                '($fresh_vbm -and ($fresh_vib -or $fresh_vbk) -and $atleast_one_vbk)' + `
                (ls $root|Out-String))
        }
    }
    finally {
        if ($driveName) {
            Write-Output "Removing PSDrive $driveName"
            Remove-PSDrive -Name $driveName -ErrorAction SilentlyContinue
        }
    }
}

<#
.SYNOPSIS
Returns a list of all Domain Controllers(FQDNs) using DNS SRV records.

.DESCRIPTION
Queries _ldap._tcp.dc._msdcs.<domain> via Resolve-DnsName and returns a unique set of DC hostnames.

.OUTPUTS
[System.String[]] hostnames (no trailing dot), case-insensitive unique list.

.EXAMPLE
Get-DomainControllers
Gets DCs for the current logon domain.

.NOTES
Throws if no domain can be inferred. Requires DNS reachability.
#>
function Get-DomainControllers {
  $Domain = (Get-CimInstance Win32_ComputerSystem).Domain

  if (-not $Domain) { throw "No domain detected." }
  $results = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)

  try {
    if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
      $srv = Resolve-DnsName -Type SRV ("_ldap._tcp.dc._msdcs.{0}" -f $Domain) -ErrorAction Stop
      foreach ($r in $srv) {
        if ($r.NameTarget) { [void]$results.Add(($r.NameTarget.TrimEnd('.'))) }
      }
    }
  } catch {}
  return $results
}

<#
.SYNOPSIS
Lists all Windows services along with their executable paths and vendor information. Also detects services with broken executable paths.

.DESCRIPTION
Enumerates all services on the system using Win32_Service, resolves each service's executable path from its PathName,
and inspects the executable's Authenticode signature to extract the vendor/publisher name.
Also emits failures if the executable is missing.
Returns a list of objects with ServiceName, Vendor, and ExePath properties.
#>
function Get-ServiceVendors {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param()

  $services = Get-CimInstance Win32_Service | Select-Object Name,PathName,DisplayName

  foreach($s in $services){
    $ExceptionsThrown = ""
    $exe = $null
    try {
		$rse = Resolve-ServiceExecutable $s.PathName $s.Name
		if (-not ($null -eq $rse)) {$exe = $rse.PayloadPath}
    } catch {
        $ExceptionsThrown += "[Get-ServiceVendors] Resolve failed for service [$($s.Name)]: $($_.Exception.Message)."
    }
    if([string]::IsNullOrWhiteSpace($exe)){ $exe = $null }

    $vendor = $null; $exeSHA256 = $null
    if($exe -and (Test-Path -LiteralPath $exe)){
      $r = Get-ExeVendor -Exe $exe
      $vendor = $r.Vendor
      $exeSHA256 = $r.ExeSHA256
    } else {
      $ExceptionsThrown += "Service $($s.Name) points to missing executable. Exe='$exe' PathName='$($s.PathName)'."
    }

    [pscustomobject]@{
      ServiceName = $s.Name
      Vendor      = $vendor
      ExePath     = $exe
      ExeSHA256   = $exeSHA256
      DisplayName = $s.DisplayName
      ExceptionsThrown  = $ExceptionsThrown
    }
  }
}

<#
.SYNOPSIS
 Return free space in GB for a drive or path.
.OUTPUTS   System.Double (GB) or $null if undeterminable.
.NOTES     Resolves a path to its drive root; tries PSDrive then .NET DriveInfo.
#>
function Get-FreeGB {
    param([Parameter(Mandatory)][string]$PathOrDrive)

    # Resolve to a drive root like 'C:\'
    $root = $null
    if ($PathOrDrive -match '^[A-Za-z]:\\?$' -or $PathOrDrive -match '^[A-Za-z]:$') {
        $root = ($PathOrDrive.Substring(0,2) + '\')
    } else {
        try {
            $resolved = Resolve-Path -LiteralPath $PathOrDrive -ErrorAction Stop
            $root = [System.IO.Path]::GetPathRoot($resolved.Path)
        } catch { return $null }
    }

    # Try PSDrive first
    try {
        $name = $root.TrimEnd('\').TrimEnd(':')
        $psd  = Get-PSDrive -Name $name -PSProvider FileSystem -ErrorAction Stop
        if ($null -ne $psd.Free) { return [math]::Round(([double]$psd.Free)/1GB,2) }
    } catch {}

    # Fallback to .NET DriveInfo
    try {
        $di = [System.IO.DriveInfo]::new($root)
        if ($di.IsReady) { return [math]::Round($di.AvailableFreeSpace/1GB,2) }
    } catch {}

    return $null
}

Function Get-WindowsOriginalInstallDate {
    <#
    .SYNOPSIS
        Robustly determines the Windows Installation date.
    .DESCRIPTION
        Aggregates dates from Registry History (for original install),
        Current Registry, and WMI. Returns the oldest valid date found.
        If history is missing, it gracefully falls back to the latest
        feature update date.
    #>
    [CmdletBinding()]
    param()

    process {
        # List to hold all potential dates found
        $candidateDates = New-Object System.Collections.Generic.List[DateTime]

        # Unix Epoch for converting Registry timestamps
        $unixEpoch = (Get-Date -Date "01/01/1970").ToLocalTime()

        # --- LAYER 1: The "Source OS" History (The Real Original Date) ---
        # Windows archives old install dates here during feature updates.
        try {
            $setupKey = "HKLM:\SYSTEM\Setup"
            if (Test-Path $setupKey) {
                # Find keys like "Source OS (Updated on...)"
                $sourceKeys = Get-ChildItem -Path $setupKey -ErrorAction SilentlyContinue |
                              Where-Object { $_.Name -like "*Source OS*" }

                foreach ($key in $sourceKeys) {
                    $prop = Get-ItemProperty -Path $key.PSPath -Name "InstallDate" -ErrorAction SilentlyContinue
                    if ($prop -and $prop.InstallDate -is [Int32] -or $prop.InstallDate -is [Int64]) {
                        # Add to candidates
                        $candidateDates.Add($unixEpoch.AddSeconds($prop.InstallDate))
                    }
                }
            }
        }
        catch {
            Write-Verbose "Could not access Registry History: $_"
        }

        # --- LAYER 2: The Current Registry (The Feature Update Date) ---
        # Usually represents the last major update (e.g., 22H2).
        try {
            $currentPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
            $currentProp = Get-ItemProperty -Path $currentPath -Name "InstallDate" -ErrorAction SilentlyContinue

            if ($currentProp -and $currentProp.InstallDate) {
                $candidateDates.Add($unixEpoch.AddSeconds($currentProp.InstallDate))
            }
        }
        catch {
            Write-Verbose "Could not access Current Registry: $_"
        }

        # --- LAYER 3: WMI Fallback (The Safety Net) ---
        # If Registry is totally unreadable, WMI usually works.
        # This usually matches Layer 2, but serves as a backup.
        try {
            $wmiOS = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
            if ($wmiOS -and $wmiOS.InstallDate) {
                $candidateDates.Add($wmiOS.InstallDate)
            }
        }
        catch {
            Write-Verbose "Could not access WMI: $_"
        }

        # --- FINAL DECISION ---
        # 1. Remove duplicates and Sort
        # 2. Pick the FIRST one (The Oldest)

        if ($candidateDates.Count -gt 0) {
            $finalDate = ($candidateDates | Sort-Object)[0]

            # Determine confidence level for the output
            $methodUsed = if ($candidateDates.Count -gt 1) { "Historical Analysis" } else { "Current Feature Update (Fallback)" }

            return [PSCustomObject]@{
                InstallDate = $finalDate
                Confidence  = $methodUsed
                AgeDays     = (New-TimeSpan -Start $finalDate -End (Get-Date)).Days
            }
        }
        else {
            # Absolute worst case: return current time (should theoretically never happen on a working OS)
            Write-Warning "Critical Failure: No install date found in Registry or WMI."
            return [PSCustomObject]@{
                InstallDate = (Get-Date)
                Confidence  = "Error - Date Not Found"
                AgeDays     = 0
            }
        }
    }
}

function Get-PropValue {
# returns a default value if object does not have a property with that name.
# The default value for the default value returned is $null but you can Set
# $default to anything else.
    param($obj, [string]$name, $default=$null)
    if ($obj -and $obj.PSObject -and $obj.PSObject.Properties[$name]) {
        return $obj.PSObject.Properties[$name].Value
    }
    return $default
}

function Test-IsRdsLicensingServer {
  [CmdletBinding()]
  [OutputType([bool])]
  param()

  # 1 = Workstation 2 = Domain Controller 3 = Windows Server
  $host_type = (Get-CimInstance Win32_OperatingSystem).ProductType
  if ($host_type -eq 1) { return $false }

  # Detect by service first (works on Server Core and PS7+)
  try {
    $svc = Get-Service -Name 'TermServLicensing' -ErrorAction SilentlyContinue
    if ($svc) { return $true }
  } catch {}

  # Fallback to ServerManager feature check (only works if ServerManager module exists)
  try {
    Import-Module ServerManager -ErrorAction Stop
    $feat = Get-WindowsFeature -Name RDS-Licensing -ErrorAction SilentlyContinue
    if ($feat -and $feat.Installed) { return $true }
  } catch {}

  return $false
}

<#
.SYNOPSIS  Check a drive/path and emit a status; returns an object with details.
.PARAMETER PathOrDrive  Drive letter or any path.
.PARAMETER WarnPct      Warning threshold (default 10).
.PARAMETER ErrorPct     Error threshold (default 5).
.OUTPUTS   PSCustomObject with Drive,Type,FreeGB,TotalGB,PercentFree,Level; or nothing if not applicable.
#>
function Test-DiskHasFreeSpace {
    param(
        [Parameter(Mandatory)][string]$PathOrDrive,
        [double]$WarnPct = 10,
        [double]$ErrorPct = 5
    )

    $root = $null
    if ($PathOrDrive -match '^[A-Za-z]:\\?$' -or $PathOrDrive -match '^[A-Za-z]:$') {
        $root = ($PathOrDrive.Substring(0,2) + '\')
    } else {
        try {
            $resolved = Resolve-Path -LiteralPath $PathOrDrive -ErrorAction Stop
            $root = [System.IO.Path]::GetPathRoot($resolved.Path)
        } catch { return }
    }

    try {
        $di = [System.IO.DriveInfo]::new($root)
    } catch { return }

    if (-not $di.IsReady) { return }

    $freeGB  = Get-FreeGB -PathOrDrive $root
    $totalGB = [math]::Round($di.TotalSize/1GB, 2)
    if ($di.TotalSize -le 0) { return }

    $pctFree = [math]::Round(($di.AvailableFreeSpace / $di.TotalSize) * 100, 2)
    if ($pctFree -lt $ErrorPct) {
        $level = 'Error'
    } elseif ($pctFree -lt $WarnPct) {
        $level = 'Warning'
    } else {
        $level = 'OK'
    }

    [pscustomobject]@{
        Drive        = $di.Name
        DriveType    = $di.DriveType.ToString()
        FreeGB       = $freeGB
        TotalGB      = $totalGB
        PercentFree  = $pctFree
        Level        = $level
    }
}

<#
.SYNOPSIS
Returns directories under Path whose observed child-item count is greater
than Threshold.

.OUTPUTS
Produces a psCustomObject for each qualifying directory:
  Path       : Full directory path
  ItemsCount : Observed count of immediate child items

.DESCRIPTION
Recursively scans the directory tree rooted at Path.
Directories that cannot be enumerated or read are skipped without a
terminating error, and results may be incomplete for that reason.
#>
function Find-LargeDirectory {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string[]]$Path = @('C:\'),

        [Parameter(Mandatory = $false)]
        [int]$Threshold = 10000,

        [Parameter(Mandatory = $false)]
        [string[]]$SkipPaths = @()
    )

    function Normalize-DirectoryPath {
        param(
            [Parameter(Mandatory)]
            [string]$CandidatePath
        )

        if ($CandidatePath -match '^[a-zA-Z]:\\$') {
            return $CandidatePath
        }

        return $CandidatePath.TrimEnd('\\')
    }

    $normalizedSkipPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($skipPath in $SkipPaths) {
        if ([string]::IsNullOrWhiteSpace($skipPath)) { continue }

        try {
            $resolvedSkipPath = Normalize-DirectoryPath -CandidatePath (Resolve-Path -LiteralPath $skipPath -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Path)
            [void]$normalizedSkipPaths.Add($resolvedSkipPath)
        }
        catch {}
    }

    function Visit-DirectoryForLargeCount {
        param (
            [Parameter(Mandatory)]
            [string]$CurrentPath
        )

        $normalizedCurrentPath = Normalize-DirectoryPath -CandidatePath $CurrentPath
        if ($normalizedSkipPaths.Contains($normalizedCurrentPath)) {
            return
        }

        try {
            $children = @(Get-ChildItem -LiteralPath $CurrentPath -ErrorAction Stop)
        }
        catch {
            return
        }

        $count = ($children | Measure-Object).Count
        if ($count -gt $Threshold) {
            [PSCustomObject]@{
                Path       = $CurrentPath
                ItemsCount = $count
            }
        }

        foreach ($childDir in $children) {
            if (-not $childDir.PSIsContainer) { continue }

            $childPath = Normalize-DirectoryPath -CandidatePath $childDir.FullName
            if ($normalizedSkipPaths.Contains($childPath)) {
                continue
            }

            Visit-DirectoryForLargeCount -CurrentPath $childDir.FullName
        }
    }

    foreach ($rootPath in $Path) {
        if ([string]::IsNullOrWhiteSpace($rootPath)) { continue }

        try {
            $resolvedRootPath = Normalize-DirectoryPath -CandidatePath (Resolve-Path -LiteralPath $rootPath -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Path)
            Write-Verbose "Scanning '$resolvedRootPath' for directories with > $Threshold items..."
            Visit-DirectoryForLargeCount -CurrentPath $resolvedRootPath
        }
        catch {}
    }
}

<#
.SYNOPSIS
Tests if the most recent Windows Defender scan is within a given number of days.

.DESCRIPTION
This function queries Microsoft Defender Antivirus status with Get-MpComputerStatus.
It checks available scan end times (Full and Quick scans) and falls back to age counters
if no timestamps exist. It then compares the most recent scan against a threshold.
Returns this info:
[pscustomobject]@{Pass=$true/$false; DaysSinceScan=N; Details='Human readable details'}

.PARAMETER Days
Number of days allowed since the last scan (default 3).

.NOTES
- On Windows Server, Defender does not schedule scans by default. If none were run,
  this function may report "No scan timestamps or ages".
- Requires Microsoft Defender Antivirus (Get-MpComputerStatus).
#>
function Get-DaysSinceLastVirusScan {
  [CmdletBinding()] param([int]$Days=3)
  try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch {
    return [pscustomobject]@{DaysSinceScan=$null;Details="Get-MpComputerStatus failed with error $_.Exception.Message"}
  }

  $ts = @()
  foreach($p in 'FullScanEndTime','QuickScanEndTime','FullScanStartTime','QuickScanStartTime'){
    $v = $mp.$p
    if ($v) { try { $ts += [datetime]$v } catch {} }
  }
  $last = $null
  if ($ts.Count -gt 0) { $last = ($ts | Sort-Object -Descending)[0] }

  if ($last) {
    $ageDays = ((Get-Date) - $last).TotalDays
    $ok = ($ageDays -le $Days)
    return [pscustomobject]@{DaysSinceScan=[math]::Round($ageDays,1);Details='Source: Time'}
  }

  $ages = @()
  foreach($ap in 'FullScanAge','QuickScanAge'){
    $av = $mp.$ap
    if ($null -ne $av) { $ages += [int64]$av }
  }
  if ($ages.Count -gt 0) {
    $minAge = ($ages | Measure-Object -Minimum).Minimum
    $ok = ($minAge -le $Days)
    return [pscustomobject]@{DaysSinceScan=$minAge;Details='Source: Age'}
  }

  return [pscustomobject]@{DaysSinceScan=$null;Details='No scan timestamps or ages'}
}


function Test-HasInvalidPathChars {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Text)
  if ($Text -match '[\x00-\x1F"<>|]') { return $true }     # control chars + common illegal
  if ($Text -match '[*?]') { return $true }               # wildcard chars are illegal in Win paths (and we treat as literal)
  $i = $Text.IndexOf(':')
  if ($i -ge 0) {
    if ($i -ne 1 -or $Text.Length -lt 2 -or $Text[0] -notmatch '[A-Za-z]') { return $true }
    if ($Text.IndexOf(':', 2) -ge 0) { return $true }
  }
  $false
}


function Test-LooksLikePath {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Text)
  $s=$Text
  $isRooted=$false
  try { $isRooted=[IO.Path]::IsPathRooted($s) } catch { $isRooted=$false }
  ($isRooted -or ($s -match '[\\/]') -or $s.StartsWith('\SystemRoot\',[StringComparison]::OrdinalIgnoreCase))
}
