<#
System Configuration & Feature Discovery
#>

function HealthTest-AdminSDHolderCoverage{
  $prot=Get-ADUser -LDAPFilter '(adminCount=1)' -Properties MemberOf | Select-Object -ExpandProperty SamAccountName
  if($prot){ Write-Warning "[pass] AdminSDHolder applied; protected users: $($prot -join ", ")" } else { Write-Warning "[pass] No users currently protected by AdminSDHolder" }
}


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


function HealthTest-DhcpInAd{
  $dhcp=Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
  if(-not $dhcp -or -not $dhcp.Installed){ Write-Warning "[pass] DHCP role not installed on this server"; return }
  $auth=Get-DhcpServerInDC -ErrorAction SilentlyContinue
  $fqdn=[System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName
  $isAuth=($auth | Where-Object { $_.DnsName -ieq $fqdn })
  if($isAuth){ Write-Warning "[pass] DHCP server is authorized in AD ($fqdn)" } else { Write-Warning "[failure] DHCP server is NOT authorized in AD ($fqdn)" }
}


function HealthTest-IisBindings {
    # Skip test on workstations
    # 1 = Workstation 2 = Domain Controller 3 = Windows Server
    $host_type = (Get-CimInstance Win32_OperatingSystem).ProductType
    if ($host_type -eq 1) {
        Write-Output "ProductType=$host_type; skiping HealthTest-IisBindings"
        return
    }

    $role = Get-WindowsFeature Web-Server -ErrorAction SilentlyContinue

    if (-not($role -and $role.Installed)) {
        Write-Warning "[info] No IIS installed; skiping HealthTest-IisBindings"
        return
    }
    $problem_found = $false
    $sites = Get-Website
    foreach ($s in $sites) {
      $b = Get-WebBinding -Name $s.Name
      foreach ($x in $b) {
        if ($x.protocol -eq 'http' -and ($x.bindingInformation -like '*:80:*') -and ($sites.count -gt 1)) {
            $commnet = ""
            if ($sites.count -gt 1) {$comment = "Since multiple sites are hosted, wildcard bindins may expose unintended content"}
            Write-Warning "[notice] $("$($s.Name): site serves plain HTTP with wildcard bindings")`n$($comment)"
            $problem_found = $true
        }
        if ($x.protocol -eq 'https' -and ($x.bindingInformation -like '*:443:*') -and -not $x.certificateHash) {
            Write-Warning "[warning] $($s.Name): site is configured for HTTPS, but it has no certificate assigned"
            $problem_found = $true
        }
      }
    }
    if ($problem_found) {return}
    Write-Warning "[pass] IIS bindings look sane"
}


function HealthTest-InstalledRolesFeatures {
  [CmdletBinding()]
  param([string[]]$DisallowedRoles = @('Web-Server','DHCP','WDS'))

  $roles = $null
  try { $roles = Get-WindowsFeature -ErrorAction Stop | Where-Object { $_.Installed } }
  catch {
    Write-Output "Get-WindowsFeature not available on this OS; skipping role/feature check"
    return
  }

  $hit = @($roles | Where-Object { $DisallowedRoles -contains $_.Name })
  if ($hit.Count -gt 0) {
    foreach ($h in $hit) { Write-Warning "[failure] Unintended role/feature installed: $($h.Name)" }
  } else {
    Write-Warning "[pass] No unintended roles/features installed"
  }
}


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


function HealthTest-ServiceAccountsPwdNeverExpires{
  $filter='(servicePrincipalName=*)'
  $objs=Get-ADUser -LDAPFilter $filter -Properties PasswordNeverExpires,PasswordLastSet
  $bad=@($objs | Where-Object {$_.PasswordNeverExpires -eq $true})
  if($bad.Count -gt 0){
    foreach($u in $bad){ Write-Warning "[failure] $("Service account password set to never expire")`n$($u.SamAccountName)" }
  } else {
    Write-Warning "[pass] Service accounts have expiring passwords"
  }
}


function HealthTest-ShareReasonableness {
  [CmdletBinding()]param(
    [string[]]$BroadPrincipals = @(
      'Everyone',
      'Authenticated Users',
      'Domain Users',
      'Users',
      'Guests',
      'BUILTIN\Users',
      'BUILTIN\Power Users',
      'NT AUTHORITY\INTERACTIVE',
      'NT AUTHORITY\NETWORK',
      'NT AUTHORITY\ANONYMOUS LOGON',
      'NT AUTHORITY\SYSTEM'
    ),
    [switch]$IncludeAdminShares
  )
  # Regarding BUILTIN\Power Users:
  # I have included it in the list allthough it's not a Broad group (in fact it's usually empty).
  # It is a legacy local group from pre-Vista/XP era. On modern Windows, it exists but is empty by default.
  # If it appears, it often indicates old misapplied permissions and that's the reason I left it.

  # 0(Workstation standalone),  1(Workstation domain joined), 2(Server standalone), 3(Server joined), 4(DC non-FSMO), 5(DC with FSMO role)
  $domainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole
  $isHostDC = ($domainRole -in 4,5)

  if ((Get-PropValue -obj (Get-Service -Name LanmanServer) -name Status) -ne 'running') {
      Write-Warning "[pass] Skipping HealthTest-ShareReasonableness; LanmanServer service not running."
      return
  }

  $shares = Get-SmbShare | Where-Object {
    ($IncludeAdminShares -or ($_.Name -notmatch '^\w+\$$')) -and
    $_.ShareType -eq 'FileSystemDirectory'
  }

  $riskFound = $false
  foreach($s in $shares){
    $shareAces = Get-SmbShareAccess -Name $s.Name -ErrorAction SilentlyContinue
    $path = $s.Path
    if(-not (Test-Path $path)){ Write-Warning "[warning] Share '$($s.Name)' points to missing path '$path'"; $riskFound = $true; continue }

    $ntfsAcl = Get-Acl -LiteralPath $path

    # List principals at share and NTFS layers and a coarse "effective" overlap
    #-------------------------------------------------------------------------------
    $sharePrincipals = @()
    foreach($ace in $shareAces){ if($ace.AccountName){ $sharePrincipals += $ace.AccountName } }
    $sharePrincipals = $sharePrincipals | Sort-Object -Unique

    $ntfsPrincipals = @()
    foreach($ace in $ntfsAcl.Access){ if($ace.IdentityReference -and $ace.IdentityReference.Value){ $ntfsPrincipals += $ace.IdentityReference.Value } }
    $ntfsPrincipals = $ntfsPrincipals | Sort-Object -Unique

    # Coarse overlap: exact-name intersection (does not resolve group nesting)
    $effectivePrincipals = @()
    foreach($sp in $sharePrincipals){ if($ntfsPrincipals -contains $sp){ $effectivePrincipals += $sp } }
    $effectivePrincipals = $effectivePrincipals | Sort-Object -Unique

    if ($s.Name -notin @('SYSVOL','NETLOGON','ADMIN$')){
        Write-Warning "[info] Accounts for share '$($s.Name)' (Path: $path)"
        Write-Warning "[info] $(("    Share-level : {0}" -f ($(if($sharePrincipals){ $sharePrincipals -join ', ' } else { '<none>' }))))"
        Write-Warning "[info] $(("    NTFS-level  : {0}" -f ($(if($ntfsPrincipals){ $ntfsPrincipals -join ', ' } else { '<none>' }))))"
        Write-Warning "[info] $(("    Effective(*) : {0}" -f ($(if($effectivePrincipals){ $effectivePrincipals -join ', ' } else { '<none>' }))))"
        Write-Warning "[info]     (*) Effective here means present on both lists; this is a coarse check without group nesting resolution."
    }

    # Identify cases of broad access to the share
    #-------------------------------------------------------------------------------
    $report = @()
    foreach($p in $BroadPrincipals){
      $shareRights = @()
      foreach($ace in $shareAces){ if($ace.AccountName -match "^(.*\\)?$([regex]::Escape($p))$"){ $shareRights += $ace.AccessRight } }
      $ntfsRights = @()
      foreach($ace in $ntfsAcl.Access){
        if($ace.IdentityReference -match "^(.*\\)?$([regex]::Escape($p))$"){
          if(-not $ace.IsInherited){ }
          $ntfsRights += $ace.FileSystemRights.ToString()
        }
      }

      if($shareRights.Count -eq 0 -and $ntfsRights.Count -eq 0){ continue }

      $effRead  = ($shareRights -match 'Read|Full|Change|All').Count -gt 0 -and ($ntfsRights -match 'Read|ReadAndExecute|ListDirectory|Modify|FullControl|All').Count -gt 0
      $effWrite = ($shareRights -match 'Change|Full|All').Count -gt 0 -and ($ntfsRights -match 'Write|Modify|Create|Delete|FullControl|All').Count -gt 0
      $effFull  = ($shareRights -match 'Full|All').Count -gt 0 -and ($ntfsRights -match 'FullControl|All').Count -gt 0

      $report += [pscustomobject]@{
        Share=$s.Name; Path=$path; Principal=$p
        SharePerms=($shareRights -join ','); NtfsPerms=($ntfsRights -join ',')
        Effective = if($effFull){'Full'} elseif($effWrite){'Write'} elseif($effRead){'Read'} else {'None'}
      }
    }

    if($report.Count -eq 0){
      Write-Warning "[pass] $("Share '{0}' has no broad-principal read or write access; ABE={1}; EncryptData={2}" -f $s.Name,$s.FolderEnumerationMode,$s.EncryptData)"
    } else {
      foreach($r in $report){
        if($r.Effective -eq 'Full' -or $r.Effective -eq 'Write'){
          Write-Warning (("[failure] '{1}' can write share '{0}'('$path')`n" -f $r.Share,$r.Principal) + ("Restrict to specific groups; ensure share grants Read or None to broad principals and tighten NTFS. Path: {0}" -f $r.Path))
          $riskFound = $true
        } elseif($r.Effective -eq 'Read') {
            if ($r.Share -ne 'SYSVOL'){
                Write-Warning "[warning] $(("'$($r.Principal)' can read share '$($r.Share)'('$path')"))"
            }
        } else {
          Write-Warning "[pass] $(("No effective access for {0} on '{1}' (blocked by layer intersection)" -f $r.Principal,$r.Share))"
        }
      }
      # Log-Info ("ABE={0}; EncryptData={1}; Caching={2}" -f $s.FolderEnumerationMode,$s.EncryptData,$s.CachingMode)
    }

    # Hygiene extras
    # if($s.FolderEnumerationMode -ne 'AccessBased'){ Write-Warning "[warning] $(("Enable Access-Based Enumeration on '{0}' if multi-tenant" -f $s.Name))" }
    # if(-not $s.EncryptData){ Write-Warning "[warning] $(("Consider SMB encryption on '{0}' for sensitive data" -f $s.Name))" }
    # if($s.CachingMode -ne 'None'){ Write-Warning "[warning] $(("Offline caching is {0} on '{1}' - assess if appropriate" -f $s.CachingMode,$s.Name))" }
  }

  # Global checks
  #--------------------------
  $srv = Get-SmbServerConfiguration
  if($srv.EnableSMB1Protocol){
    Write-Warning "[warning] SMB1 is enabled; disable unless really needed`nYou can disable it by running: Set-SmbServerConfiguration -EnableSMB1Protocol `$false"
  }
  if($srv.RequireSecuritySignature -eq $false){
    if ($isHostDC) {
      Write-Warning "[warning] SMB signing not required and this is a DC. It is recomended to enable`nYou can enable it by running: Set-SmbServerConfiguration -RequireSecuritySignature `$true"
    } else {
      Write-Warning "[info] SMB signing not required; You may want to consider enabling it. It helps avoid sophisticated internal data integrity attacks."
    }
  }

  # Null session shares
  $nullShares = @()
  try{
    $reg = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -ErrorAction SilentlyContinue
    if ($reg -and ($reg.PSObject.Properties.Name -contains 'NullSessionShares')) {
      $val = $reg.NullSessionShares
      if ($null -ne $val) {
        if ($val -is [array]) { $nullShares = $val }
        elseif ([string]::IsNullOrWhiteSpace([string]$val) -eq $false) { $nullShares = @([string]$val) }
      }
    }
  } catch {}
  if($nullShares -and $nullShares.Count -gt 0){
    Write-Warning "[failure] Null session shares configured: $($nullShares -join ', ')`nRemove unless a documented legacy requirement exists."
    $riskFound = $true
  }

  # Null session pipes
  $nullPipes = @()
  try{
    $reg = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -ErrorAction SilentlyContinue
    if ($reg -and ($reg.PSObject.Properties.Name -contains 'NullSessionPipes')) {
      $val = $reg.NullSessionPipes
      if ($null -ne $val) {
        if ($val -is [array]) { $nullPipes = $val }
        elseif ($val -is [string]) { $nullPipes = $val -split ',' }
      }
    }
  } catch {}

  $nullPipes = $nullPipes | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ } | Sort-Object -Unique
  if ($isHostDC) {
      # these are recomended by Microsoft to be kept in DCs
      $nullPipes = $nullPipes | ?{$_ -notin @('lsarpc', 'netlogon', 'samr')}
  }
  if (Test-IsRdsLicensingServer) {
      # these are by default present in RDS servers (Terminal Services)
      $nullPipes = $nullPipes | ?{$_ -notin @('HydraLsPipe','TermServLicensing')}
  }

  if ($nullPipes -and $nullPipes.Count -gt 0) {
    Write-Warning (("[notice] Null session pipes (Named Pipes that can be accessed anonymously) found: {0}`n" -f ($nullPipes -join ', ')) + "Anonymous users are allowed to open those pipes. Modern domains don't need null pipes and they increase attack surface if other policies are loose. If you don't have legacy (pre-Windows 2000-era) trusts/clients, it's recommended to keep Null session pipes empty. Change Local Security Policy > Security Options > 'Network access: Named Pipes that can be accessed anonymously' (set to None), or the equivalent GPO.")
  }

  if (!$riskFound) {Write-Warning "[pass] No risks related to SMB shares were detected"}
}

<#
.SYNOPSIS
Checks if there are any non-default file or print shares on this machine.

.DESCRIPTION
Warns if any non-hidden shares (not ending in $) exist besides SYSVOL.
If none exist, outputs a good status. Also suggests disabling the LanmanServer
service if file and print sharing is not needed on non-domain controllers.
#>
function HealthTest-NonDefaultShares {
  # 0(Workstation standalone),  1(Workstation domain joined), 2(Server standalone), 3(Server joined), 4(DC non-FSMO), 5(DC with FSMO role)
  $domainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole
  $isHostDC = ($domainRole -in 4,5)

    $lanManServer_service = (get-service -Name "LanmanServer")
    $shares_beside_the_system_ones = Get-CimInstance -ClassName Win32_Share | Select-Object Name, Path | ?{$_.name -notlike '*$' -and $_.path -notlike 'C:\Windows\SYSVOL\sysvol*'}
    if ($shares_beside_the_system_ones) {
        $shares_beside_the_system_ones | %{Write-Warning "[warning] Found a share named '$($_.name)' that shares '$($_.Path)'"}
    } else {
        if ((Get-Service  -Name "LanmanServer").status -eq 'Stopped') {
            Write-Warning "[pass] No shares except the defaults and LanMan service is stopped."
        } else {
            Write-Warning "[pass] Found no shares except the default ones (like C$, ADMIN$)."
            if (!$isHostDC -and ($lanManServer_service.status -ne 'stopped' -or $lanManServer_service.StartType -ne 'Disabled')) {
                if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 2) { # server
                    Write-Warning "[warning] File & print sharing is enabled. It's recomended to disable it unless you really need it`nRun this if you want to disable:`n   Set-Service -Name 'LanmanServer' -StartupType Disabled; Stop-Service -Name 'LanmanServer'"
                } else { # workstation
                    Write-Output "File & print sharing is enabled on a workstation.`nYou may consider disabling it to reduce the attack surface"
                }
            }
        }
    }
}

<#
.SYNOPSIS
Checks for services set to start automatically but are not currently running.

.DESCRIPTION
Warns about any services with StartType=Automatic that are stopped (excluding a few known exceptions).
Reports success if all automatic services are running.
#>
function HealthTest-AutoStartServicesRunning {
  function Get-ServiceExitCodeMessage {
      param([int]$ExitCode)

      $known = $null
      switch ($ExitCode) {
          0    { $known = 'The operation completed successfully.'; break }
          1077 { $known = 'No attempts to start the service have been made since the last boot.'; break }
          1    { $known = 'Incorrect function.'; break }
          2    { $known = 'The system cannot find the file specified.'; break }
          3    { $known = 'The system cannot find the path specified.'; break }
          5    { $known = 'Access is denied.'; break }
          13   { $known = 'The data is invalid.'; break }
          14   { $known = 'Not enough storage is available to complete this operation.'; break }
          87   { $known = 'The parameter is incorrect.'; break }
          1053 { $known = 'The service did not respond to the start or control request in a timely fashion.'; break }
          1058 { $known = 'The service cannot be started because it is disabled or has no enabled devices associated with it.'; break }
          1067 { $known = 'The process terminated unexpectedly.'; break }
          1068 { $known = 'A dependency service or group failed to start.'; break }
          1075 { $known = 'The dependency service does not exist or has been marked for deletion.'; break }
          1114 { $known = 'A dynamic link library (DLL) initialization routine failed.'; break }
      }

      if ($known) { return $known }

      try {
          $raw = (& cmd.exe /c "net helpmsg $ExitCode" 2>$null)
          if ($raw) {
              $msg = ($raw -join ' ') -replace '\s+$',''
              if ($msg -and $msg -notmatch 'is not a valid Windows|more help is available') {
                  return $msg
              }
          }
      } catch {}

      "Unknown Windows service exit code."
  }

    <#
    SERVICES_THAT_ARE_OFTEN_STOPPED

    edgeupdate: Microsoft Edge Update Service
    InventorySvc: Inventory and Compatibility Appraisal service
    MapsBroker: Downloaded Maps Manager
    sppsvc: Software Protection
    gupdate: Google Update Service
    dmwappushservice: Device Management Wireless Application Protocol (WAP) Push message Routing Service
    gpsvc: Group Policy Client
    AppXSvc: AppX Deployment Service (for installing/updating .appx Microsoft Store apps)
    TrustedInstaller: windows updates service
    #>
    $SERVICES_THAT_ARE_OFTEN_STOPPED=@('edgeupdate', 'InventorySvc', 'MapsBroker', 'sppsvc',
        'gupdate', 'dmwappushservice', 'RemoteRegistry', 'StateRepository', 'gpsvc', 'AppXSvc',
        'TrustedInstaller')
    # The regex below is more powerful but more difficult to update correctly.
    $SERVICES_THAT_ARE_OFTEN_STOPPED_REGEX = '^(GoogleUpdaterInternalService[0-9.]+|GoogleUpdaterService[0-9.]+)$'

    $not_started_services = (Get-CimInstance Win32_Service -Filter "StartMode='Auto' and State!='Running'" |
        select Name,DisplayName,State,StartMode,DelayedAutoStart,ExitCode)

    if ($not_started_services) {
        $not_started_services | %{
            # TODO: consider exitcode 1077 practicly equivalent to 0 (no problem)
            # 1077 = No attempts to start the service have been made since the last boot.
            $exitCodeMeaning = Get-ServiceExitCodeMessage $_.ExitCode
            $serviceInListOfOftenStoped = (
                ($_.name -in $SERVICES_THAT_ARE_OFTEN_STOPPED) -or
                ($_.name -match $SERVICES_THAT_ARE_OFTEN_STOPPED_REGEX)
            )
            if ($serviceInListOfOftenStoped -and ($_.ExitCode -in (0,1077))) {
                    Write-Warning "[info] This service is stoped but its last execution terminated NORMALY and it's one of the services that are often stopped: Service '$($_.Name)', StartMode=$($_.StartMode), DelayedAutoStart=$($_.DelayedAutoStart), last ExitCode=$($_.ExitCode)($exitCodeMeaning)."
            } else {
                if ($_.ExitCode  -in (0,1077)) {
                    Write-Warning "[notice] Service '$($_.Name)' which is set to automatically start is not running; calmingly its last execution terminated normally: ExitCode=$($_.ExitCode)($exitCodeMeaning).`nDisplay name: $($_.DisplayName), StartMode=$($_.StartMode), DelayedAutoStart=$($_.DelayedAutoStart), last ExitCode=$($_.ExitCode)($exitCodeMeaning)."
                } else {
                    Write-Warning "[failure] Service '$($_.Name)' which is set to automatically start is not running; alarmingly its last execution terminated abnormally: ExitCode=$($_.ExitCode)($exitCodeMeaning).`nDisplay name: $($_.DisplayName), StartMode=$($_.StartMode), DelayedAutoStart=$($_.DelayedAutoStart), last ExitCode=$($_.ExitCode)($exitCodeMeaning)."
                }
            }
        }
    } else {
        Write-Warning "[pass] All services that are set to automatically start are running"
    }
}

<#
.SYNOPSIS
Checks if the system default locale (ACP/OEMCP) matches expected values.

.DESCRIPTION
Validates the system's ANSI (ACP) and OEM code pages. Warns if they are not the usual Greek (1253/737) or English (1252/437) combinations.
#>
function HealthTest-DefaultLocale {
    # see https://newbedev.com/how-can-i-manually-determine-the-codepage-and-locale-of-the-current-os
    $loc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' | Select-Object ACP,OEMCP
    $loc_acp = $loc.ACP; $loc_oemcp = $loc.OEMCP
    if($loc_acp -eq 1253 -and $loc_oemcp -eq 737){
      Write-Warning "[pass] Host supports legacy Greek (ACP/OEMCP 1253/737)."
    }elseif($loc_acp -eq 1252 -and $loc_oemcp -eq 437){
      Write-Warning "[notice] This host uses default English/ANSI (1252/437), so legacy Greek apps may fail."
    }else{
      Write-Warning "[warning] Unusual non-Unicode locale: $loc_acp / $loc_oemcp (ACP/OEMCP). Greek is 1253/737; Default english is 1252/437."
    }
}

<#
.SYNOPSIS
Checks if any local user accounts have PasswordRequired set to False.

.DESCRIPTION
Finds enabled local accounts without required passwords and reports them as failures.
#>
function HealthTest-LocalAcntRequirePass {
    $ok = $true
    $no_req_pass_accounts=Get-CimInstance -Class Win32_UserAccount -Filter `
        "LocalAccount=True AND Disabled=False AND PasswordRequired=False"
    if ($no_req_pass_accounts) {
        $no_req_pass_accounts | %{
            try {$account_name = $_.name} catch {$account_name="(FAILED_TO_GET_NAME)"}
            $ok = $false
            Write-Warning "[failure] This local account has the property PasswordRequired set to false: $account_name`nMake sure the account password is set and then run this command:`n& cmd /c 'net user `"$($_.name)`" /passwordreq:yes'"
        }
    }
    if ($ok) {Write-Warning "[pass] All local accounts have PasswordRequired True"}
}

<#
.SYNOPSIS
Checks if any fixed, removable, or network drives are low on free space.

.NOTES
Relies on Test-DiskHasFreeSpace to perform the actual threshold check.
#>
function HealthTest-DisksHaveFreeSpace {
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $d.IsReady) { continue }
        $t = $d.DriveType.ToString()
        if (@('Fixed','Removable','Network') -notcontains $t) { continue }
        # emmits Log-failure/warning/pass
        $out = Test-DiskHasFreeSpace -PathOrDrive $d.Name
        if ($out.level -eq 'Error') {
            Write-Warning "[failure] Disk is critically low on free space`n$out"
        } elseif ($out.level -eq 'Warning') {
            Write-Warning "[warning] Disk is low on free space`n$out"
        } else {
            Write-Warning "[pass] Disk has enough free space`n$out"
        }
    }
}

<#
.SYNOPSIS
Warns for every directory that has more than 10,000 immediate child items.

.DESCRIPTION
Uses Find-LargeDirectory to locate directories with high item counts under C:\.
Each matching directory is logged as a warning with the item count in -Comment.
#>
function HealthTest-LargeDirectories {
    $foundLargeDirectory = $false

    foreach ($dir in Find-LargeDirectory -Path 'C:\' -Threshold 10000 -SkipPaths @("C:\windows\servicing","C:\windows\WinSxS")) {
        $foundLargeDirectory = $true
        $comment = "$($dir.ItemsCount) items found"
        try {
            $profileComment = Get-DirFileProfile $dir.Path | Format-DirFileProfileNarrative -SingleLine -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($profileComment)) {
                $comment = $profileComment
            }
        }
        catch {}

        Write-Warning "[warning] $("Directory $($dir.Path) has more than 10000 child items")`n$($comment)"
    }

    if (-not $foundLargeDirectory) {
        Write-Warning "[pass] No large directories found over threshold"
    }
}

<#
.SYNOPSIS
Reports a warning for any non Microsoft service it finds
#>
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

<#
.SYNOPSIS
Checks if any Hyper-V VMs that should auto-start are not currently running.

.DESCRIPTION
Lists all VMs where AutomaticStartAction is "Start" but their state is not "Running" and reports them as failures.
#>
function HealthTest-HyperVRunningVMs {
    $ok=$true
    $all_vm = get-vm
    $all_vm |?{$_.state -ne 'Running' -and $_.AutomaticStartAction -eq 'Start'} | %{
        Write-Warning "[failure] VM $($_.name) should be running but is not"
        $ok=$false
    }
    if ($all_vm |?{$_.AutomaticStartAction -eq 'Start'}) {
        if ($ok) {Write-Warning "[pass] All VMs that are set to always auto-start are running"}
    } else {
        Write-Warning "[info] No VM is set to always auto-start"
    }
}

<#
.SYNOPSIS
Checks running Hyper-V VMs for unexpected property values.

.DESCRIPTION
Iterates through running VMs and compares selected properties against the expected values stored in $EXPECTED_VALUES_FOR_VM_PROPERTIES.
Warns if any property value does not match the expected value.
#>
function HealthTest-HyperVVMProperties {
    # For Hyper-V hosts put here the expected values for these VM properties
    $EXPECTED_VALUES_FOR_VM_PROPERTIES = @{
        ReplicationHealth        = 'Normal'
        Status                   = 'Operating normally'
        PrimaryOperationalStatus = 'Ok'
        Heartbeat                = 'Ok*'
        AutomaticStartAction     = 'Start*'
        AutomaticStopAction      = 'Save'
        VMIntegrationService     = 'Guest Service Interface,Heartbeat,Key-Value Pair Exchange,Shutdown,Time Synchronization,VSS'
        Generation               = '2'
        Version                  = '9.0'
    }

    $vms = Get-VM | Where-Object { $_.State -eq 'Running' }
    foreach ($vm in $vms) {
        $EXPECTED_VALUES_FOR_VM_PROPERTIES.Keys | ForEach-Object {
            $prop_name = $_
            $expected_value = $EXPECTED_VALUES_FOR_VM_PROPERTIES[$prop_name]
            # write-host "Checking if $prop_name = $expected_value"

            if ($prop_name -eq 'VMIntegrationService') {
                # for VMIntegrationService we need to canonicalize the values
                $expected_value = ($expected_value -split ',' | % { $_.Trim() } | Sort-Object -Unique)  -join ','
                $actual_value   = ($vm.VMIntegrationService.Name | Sort-Object -Unique) -join ','
            } else {
                # for all other properties we have a simple value we expect them to have
                $actual_value = $vm.$prop_name
            }
            if ($actual_value -notlike $expected_value) {
                Write-Warning "[warning] VM $($vm.Name) has $prop_name='$actual_value' instead of '$expected_value'."
            }
        }
    }
}

<#
.SYNOPSIS
Checks if all Microsoft Defender (Malware Protection) features are enabled.

.DESCRIPTION
Evaluates the output of Get-MpComputerStatus and reports the state of several protection-related properties using Write-BasedOnTestResult.
#>
function HealthTest-MalwareProtectionFeatures {
    # $MPs holds the Malware Protection status
    $MPs=(Get-MpComputerStatus)
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).DefenderSignaturesOutOfDate not true?" -Test (!$MPs.DefenderSignaturesOutOfDate) -Comment "You may run`n  Update-MpSignature`n  to update."
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).AMServiceEnabled true?"                -Test $MPs.AMServiceEnabled
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).AMRunningMode Normal?"                 -Test ($MPs.AMRunningMode -eq 'Normal')
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).RealTimeProtectionEnabled true?"       -Test $MPs.RealTimeProtectionEnabled
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).OnAccessProtectionEnabled true?"       -Test $MPs.OnAccessProtectionEnabled
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).NISEnabled true?"                      -Test $MPs.NISEnabled
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).IoavProtectionEnabled true?"           -Test $MPs.IoavProtectionEnabled
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).BehaviorMonitorEnabled true?"          -Test $MPs.BehaviorMonitorEnabled
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).AntivirusEnabled true?"                -Test $MPs.AntivirusEnabled
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).AntispywareEnabled true?"              -Test $MPs.AntispywareEnabled
}

<#
.SYNOPSIS
Checks if the firewall service is running and enabled for all profiles.

.DESCRIPTION
Confirms the Windows Firewall (mpssvc) service is running and that the firewall is enabled on each network profile.
#>
function HealthTest-FirewallEnabled {
    Write-BasedOnTestResult "Is mpssvc (the firewall service) enabled?" -Test ((Get-Service -name mpssvc).status -eq 'Running')
    Get-NetFirewallProfile | ForEach-Object {
        Write-BasedOnTestResult "Is firewall enabled for the $($_.Name) profile?" -Test ($_.Enabled -eq 1) -comment "To enable firewall for *ALL* profiles run this:`nSet-NetFirewallProfile -Profile Domain,Private,Public -Enabled True"
    }
}

<#
.SYNOPSIS
Checks if Windows Defender performed a quick scan recently
#>
function HealthTest-RecentWindowsScan {
    $MAX_WARN_DAYS = 4
    $MAX_FAILURE_DAYS = 8

    $installationAge = $null
    $o = Get-DaysSinceLastVirusScan

    if ($null -ne $o.DaysSinceScan -and $o.DaysSinceScan -lt 1024*1024) {
        $days = [int]$o.DaysSinceScan
        $installationAge = "n/a"
    } else {
        try {
            $installationAge = (Get-WindowsOriginalInstallDate).agedays
            $days = [int]$installationAge
        } catch {
            $installationAge = "UNKNOWN"
            $days = 99999
        }
    }

    $comment = "Last scan, $days days ago. Windows installation age is $installationAge days."

    if ($days -lt $MAX_WARN_DAYS) {
        Write-Warning "[pass] $("Did windows defender perform a quick scan recently?")`n$($comment)"
    } elseif ($days -lt $MAX_FAILURE_DAYS) {
        Write-Warning "[warning] $("Did windows defender perform a quick scan recently?")`n$($comment)"
    } else {
        Write-Warning "[failure] $("Did windows defender perform a quick scan recently?")`n$($comment)"
    }
}

<#
.SYNOPSIS
Tests SYSVOL/NETLOGON accessibility across DCs.
.DESCRIPTION
Checks UNC reachability for \\<DC>\SYSVOL and \\<DC>\NETLOGON.
#>
function HealthTest-SysvolNetlogonAccessible{
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

<#
.SYNOPSIS
Ensures AD schema objectVersion matches across all DCs.

.DESCRIPTION
Reads objectVersion from the Schema NC via each DC and normalizes to [int].
Passes if there is exactly one distinct version. Returns details per-DC and a summary.
#>
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

<#
.SYNOPSIS
Verifies NTDS.dit and log paths are on intended volumes.
.DESCRIPTION
Reads NTDS parameters and returns their current locations.
#>
function HealthTest-NtdsPathsLocation{
  [CmdletBinding()]
  param(
    [string[]]$ExpectedDbRoots,
    [string[]]$ExpectedLogRoots
  )
  $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
  $db = (Get-ItemProperty -Path $regPath -Name 'DSA Database file' -ErrorAction Stop).'DSA Database file'
  $lg = (Get-ItemProperty -Path $regPath -Name 'Database log files path' -ErrorAction Stop).'Database log files path'

  $dbOk = if($ExpectedDbRoots -and $ExpectedDbRoots.Count){
    ($ExpectedDbRoots | Where-Object { $db -like "$_*" -or ([IO.Path]::GetPathRoot($db) -eq $_) }).Count -gt 0
  } else { $true }
  if(-not $dbOk){ Write-Warning "[failure] NTDS database path not on an expected volume`nDB=$db; Expected roots: $($ExpectedDbRoots -join ', ')" }

  $lgOk = if($ExpectedLogRoots -and $ExpectedLogRoots.Count){
    ($ExpectedLogRoots | Where-Object { $lg -like "$_*" -or ([IO.Path]::GetPathRoot($lg) -eq $_) }).Count -gt 0
  } else { $true }
  if(-not $lgOk){ Write-Warning "[failure] NTDS log path not on an expected volume`nLOGS=$lg; Expected roots: $($ExpectedLogRoots -join ', ')" }

  if($dbOk -and $lgOk){ Write-Warning "[pass] NTDS database/log paths sane (DB=$db; LOGS=$lg)" }
}

<#
.SYNOPSIS
Checks tombstoneLifetime and links interval sanity.
#>
function HealthTest-TombstoneLifetime{
  [CmdletBinding()] param([int]$MinDays=60)
  $ds="CN=Directory Service,CN=Windows NT,CN=Services,$((Get-ADRootDSE).ConfigurationNamingContext)"
  $tl=(Get-ADObject $ds -Properties tombstoneLifetime).tombstoneLifetime
  if(-not $tl){$tl=60}
  if($tl -ge $MinDays){ Write-Warning "[pass] AD tombstoneLifetime is sufficient ($tl days >= $MinDays)" }
  else{ Write-Warning "[failure] AD tombstoneLifetime below threshold`nCurrent=$tl; Min=$MinDays" }
}

<#
.SYNOPSIS
Confirms AD Recycle Bin is enabled.
#>
function HealthTest-RecycleBinEnabled{
  $f=Get-ADOptionalFeature 'Recycle Bin Feature' -ErrorAction Stop
  $enabled=($f.EnabledScopes -ne $null -and $f.EnabledScopes.Count -gt 0)
  if($enabled){ Write-Warning "[pass] AD Recycle Bin enabled" } else { Write-Warning "[notice] AD Recycle Bin is not enabled -- consider enabling it." }
}

<#
.SYNOPSIS
Verifies domain trusts and performs netdom /verify.
#>
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

<#
.SYNOPSIS
Checks replication latency on schema/config partitions.
#>
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

<#
.SYNOPSIS
Validates DNS zone replication scope for AD-integrated zones.
#>
function HealthTest-DnsZoneReplicationScope{
  $zones = Get-DnsServerZone -ErrorAction Stop | Where-Object { $_.IsDsIntegrated }
  if(-not $zones){ Write-Warning "[pass] No AD-integrated zones present"; return }
  $lines = ($zones | ForEach-Object { "{0}:{1}" -f $_.ZoneName, $_.ReplicationScope })
  Write-Warning ("[pass] DNS zone replication scope reviewed`n" + ($lines -join '; '))
}

<#
.SYNOPSIS
Confirms some important SRV records exist:
_ldap._tcp.dc._msdcs.<domain> = where are the Domain Controllers (LDAP over TCP)?
_kerberos._tcp.<domain> = where are Kerberos KDCs over TCP?
_kerberos._udp.<domain> = where are Kerberos KDCs over UDP?
#>
function HealthTest-RequiredSrvRecords{
  $dom=(Get-CimInstance Win32_ComputerSystem).Domain
  $labels=@("_ldap._tcp.dc._msdcs.$dom","_kerberos._tcp.$dom","_kerberos._udp.$dom")
  $missing=$false
  foreach($q in $labels){
    try{ $r=Resolve-DnsName -Type SRV $q -ErrorAction Stop }catch{$r=$null}
    if(-not $r){ $missing=$true; Write-Warning "[failure] $("Required SRV record missing")`n$($q)" }
  }
  if(-not $missing){ Write-Warning "[pass] Required AD SRV records present" }
}

<#
.SYNOPSIS
Checks DNS scavenging/aging configuration (server + per-zone).
.DESCRIPTION
Returns Pass=$true only if server scavenging is enabled AND all AD-integrated primary zones have AgingEnabled=$true.
Details list server state and zones with/without aging.
#>
function HealthTest-DnsScavenging{
  $sv = Get-DnsServerScavenging -ErrorAction Stop
  $zones = Get-DnsServerZone -ErrorAction Stop | Where-Object { $_.IsDsIntegrated -and $_.ZoneType -eq 'Primary' }
  $comment = "Severity: Medium.`nWhat it means: Server-level scavenging is off, so stale dynamic records never age out.`nRisk: Stale A/PTR clutter, service discovery problems, and opportunities for name re-use confusion. In secure-updates AD zones, outright hijack is harder, but operational pain is real."

  $flagged=$false
  if(-not $sv.ScavengingState){ $flagged=$true; Write-Warning "[warning] $("DNS server scavenging is disabled")`n$($comment)" }

  foreach($z in $zones){
    $ai = $null; try { $ai = Get-DnsServerZoneAging -Name $z.ZoneName -ErrorAction Stop } catch {}
    if(-not ($ai -and $ai.AgingEnabled)){ $flagged=$true; Write-Warning "[warning] DNS zone aging is disabled`nzone: $($z.ZoneName) `nNote that scavenging must be enabled both at the server level and at the zone`n$comment"}
  }

  if(-not $flagged){
    $on=@($zones | ForEach-Object { $_.ZoneName })
    Write-Warning "[pass] $("DNS scavenging configured on server and zones")`n$(("Zones: " + ($on -join ', ')))"
  }
}

<#
.SYNOPSIS
Validates DNS forwarders reachability and forbids loopback.
#>
function HealthTest-DnsForwarders{
  $f=Get-DnsServerForwarder -ErrorAction Stop
  if(-not $f -or -not $f.IPAddress){ Write-Warning "[pass] No DNS forwarders configured"; return }
  $ips=$f.IPAddress
  $bad=$false
  foreach($ip in $ips){
    if(($ip -eq '127.0.0.1') -or ($ip -eq '::1')){ $bad=$true; Write-Warning "[failure] $("Loopback address is configured as a DNS forwarder")`n$($ip)"; continue }
    $ok=(Test-Connection -ComputerName $ip -Count 1 -Quiet)
    if(-not $ok){ $bad=$true; Write-Warning "[failure] $("DNS forwarder not reachable")`n$($ip)" }
  }
  if(-not $bad){ Write-Warning "[pass] $("DNS forwarders sane & reachable")`n$(("Forwarders: " + ($ips -join ', ')))" }
}

<#
.SYNOPSIS
Ensures LDAP signing and channel binding settings are enforced.
#>
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

<#
.SYNOPSIS
Requires SMB signing on the server.
#>
function HealthTest-SmbSigningRequired{
  if ((Get-PropValue -obj (Get-Service -Name LanmanServer) -name Status) -ne 'running') {
      Write-Warning "[pass] Skipping HealthTest-SmbSigningRequired; LanmanServer service not running."
      return
  }

  $c=Get-SmbServerConfiguration
  if($c.RequireSecuritySignature){
    Write-Warning "[pass] SMB signing required on the server"
  } else {
    Write-Warning "[warning] SMB signing is not required`nRequireSecuritySignature=$($c.RequireSecuritySignature); EnableSecuritySignature=$($c.EnableSecuritySignature)"
  }
}

# TODO this test is repeated in HealthTest-ShareReasonableness
<#
.SYNOPSIS
Verifies SMBv1 is disabled.
#>
function HealthTest-Smb1Disabled{
  $f=Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -ErrorAction SilentlyContinue
  $state=$f.State
  $disabled=($state -eq 'Disabled' -or -not $f -or $state -eq 'DisabledWithPayloadRemoved')
  if($disabled){ Write-Warning "[pass] SMBv1 is disabled" } else { Write-Warning "[warning] SMBv1 is enabled`nState=$state" }
}

<#
.SYNOPSIS
Finds accounts with unconstrained delegation (excludes DCs by default).

.DESCRIPTION
Flags user/computer objects where userAccountControl has TRUSTED_FOR_DELEGATION (0x80000).
By default excludes Domain Controllers (SERVER_TRUST_ACCOUNT 0x2000), since DCs are inherently trusted.
Use -IncludeDomainControllers to include them in the results.
#>
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

<#
.SYNOPSIS
Flags service accounts with PasswordNeverExpires.
#>
function HealthTest-ServiceAccountsPwdNeverExpires{
  $filter='(servicePrincipalName=*)'
  $objs=Get-ADUser -LDAPFilter $filter -Properties PasswordNeverExpires,PasswordLastSet
  $bad=@($objs | Where-Object {$_.PasswordNeverExpires -eq $true})
  if($bad.Count -gt 0){
    foreach($u in $bad){ Write-Warning "[failure] $("Service account password set to never expire")`n$($u.SamAccountName)" }
  } else {
    Write-Warning "[pass] Service accounts have expiring passwords"
  }
}

<#
.SYNOPSIS
Checks anonymous access hardening against modern baselines.

.DESCRIPTION
Pass when:
  - RestrictAnonymousSAM = 1  (Do not allow anonymous enumeration of SAM accounts)
  - EveryoneIncludesAnonymous = 0 (Anonymous not included in Everyone)
RestrictAnonymous (legacy 'SAM and shares') is informational:
  - 0 (baseline) -> OK
  - 1 (stricter) -> Warn: may break legacy browsing/trust; rarely needed today
  - 2 -> Obsolete/unsupported on modern Windows; treat as warn/fail
#>
function HealthTest-RestrictAnonymous {
  $p  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
  $ra = (Get-ItemProperty $p -Name restrictanonymous      -ErrorAction SilentlyContinue).restrictanonymous
  $rs = (Get-ItemProperty $p -Name restrictanonymoussam   -ErrorAction SilentlyContinue).restrictanonymoussam
  $ea = (Get-ItemProperty $p -Name EveryoneIncludesAnonymous -ErrorAction SilentlyContinue).EveryoneIncludesAnonymous

  $pass = ($rs -eq 1 -and $ea -eq 0)
  $details="RestrictAnonymous=$ra; RestrictAnonymousSAM=$rs; EveryoneIncludesAnonymous=$ea"

  if($pass){
    Write-Warning "[pass] $("Anonymous access hardening (baseline met)")`n$($details)"
  } else {
    Write-Warning "[failure] Anonymous access hardening not at baseline`n$details. Recommendation: Set RestrictAnonymousSAM=1 and EveryoneIncludesAnonymous=0 via GPO."
  }
}

<#
.SYNOPSIS
Checks that a pagefile exists and meets a minimum size.

.DESCRIPTION
Handles both explicit and system-managed pagefiles.
- Primary source: Win32_PageFileUsage (current allocated size).
- Fallback: 'PagingFiles' registry (C:\pagefile.sys 0 0 means system-managed).
Pass=$true when total AllocMB >= MinMB, and (optionally) one pagefile is on the system drive.
#>
function HealthTest-PagefileSanity{
  [CmdletBinding()] param([int]$MinMB=1024,[switch]$RequireOnSystemDrive)
  $cs   = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
  $auto = $cs.AutomaticManagedPagefile
  $usage = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
  $regPath='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
  $pfReg=(Get-ItemProperty -Path $regPath -Name PagingFiles -ErrorAction SilentlyContinue).PagingFiles

  $entries=@()
  if($usage){
    foreach($u in $usage){ $entries += [pscustomobject]@{Name=$u.Name;AllocMB=[int]$u.AllocatedBaseSize;CurrMB=[int]$u.CurrentUsage} }
  }
  if(-not $entries -and $pfReg){
    foreach($line in $pfReg){
      $parts=$line -split '\s+'
      if($parts.Length -ge 1){
        $name=$parts[0]; $min= if($parts.Length -ge 2){ [int]$parts[1] } else { 0 }
        $entries += [pscustomobject]@{Name=$name;AllocMB=$min;CurrMB=$null}
      }
    }
  }

  if(-not $entries){
    Write-Warning "[failure] $("No pagefile detected")`n$(("AutomaticManagedPagefile="+[int]$auto))"
    return
  }

  $sumAlloc=($entries | Measure-Object AllocMB -Sum).Sum
  $okSize = ($sumAlloc -ge $MinMB)
  $okSys  = $true
  if($RequireOnSystemDrive){
    $sys = $env:SystemDrive  # Typically 'C:'
    $okSys = (($entries | Where-Object {$_.Name -like "$sys\*"}).Count -gt 0)
    if(-not $okSys){ Write-Warning "[failure] No pagefile on system drive`nSystemDrive=$sys; Entries="+(($entries | ForEach-Object {"$($_.Name):$($_.AllocMB)MB"}) -join ', ') }
  }
  if(-not $okSize){ Write-Warning "[failure] Total pagefile size below threshold`nTotalAllocMB=$sumAlloc; MinMB=$MinMB" }

  if($okSize -and $okSys){
    Write-Warning ("[pass] Paging file configured sensibly`n" + ("Auto="+[int]$auto+"; TotalAllocMB=$sumAlloc; Entries="+(($entries | ForEach-Object {"$($_.Name):$($_.AllocMB)MB"}) -join ', ')))
  }
}

<#
.SYNOPSIS
Confirms WinRM is running and responsive.
#>
function HealthTest-WinRMListening{
  $svc=Get-Service WinRM -ErrorAction Stop
  if($svc.Status -ne 'Running'){ Write-Warning "[failure] WinRM service is not running`nStatus=$($svc.Status)"; return }
  try{ $null=Test-WSMan -ErrorAction Stop; Write-Warning "[pass] WinRM running and responding" }
  catch{ Write-Warning "[failure] $("WinRM not responding")`n$($_.Exception.Message)" }
}

<#
.SYNOPSIS
Verifies IPv6 binding state per policy (PS5.1-safe).
#>
function HealthTest-IPv6Binding{
  [CmdletBinding()] param([switch]$RequireEnabled)
  $rows = Get-NetAdapterBinding -ComponentID ms_tcpip6 | Select-Object Name,Enabled
  if(-not $rows){ Write-Warning "[failure] No adapters returned for IPv6 binding (ms_tcpip6)"; return }
  $bad=$false
  if($RequireEnabled){
    foreach($r in $rows){
      if(-not $r.Enabled){ $bad=$true; Write-Warning "[failure] $("IPv6 disabled on adapter")`n$($r.Name)" }
    }
    if(-not $bad){ Write-Warning "[pass] IPv6 enabled on all adapters" }
  } else {
    Write-Warning "[pass] $("IPv6 binding state reported")`n$((($rows | ForEach-Object { "$($_.Name)=$($_.Enabled)" }))" -join '; ')
  }
}

<#
.SYNOPSIS
Verifies DNS Client service is running.
#>
function HealthTest-DnsClientService{
  $s=Get-Service Dnscache -ErrorAction Stop
  if($s.Status -eq 'Running'){ Write-Warning "[pass] DNS Client service running" } else { Write-Warning "[failure] DNS Client service is not running`nStatus=$($s.Status)" }
}

<#
.SYNOPSIS
Verifies WMI repository consistency.
#>
function HealthTest-WmiRepository{
  $out=& winmgmt /verifyrepository 2>&1
  $ok=($out -match 'consistent')
  if($ok){ Write-Warning "[pass] WMI repository consistent" } else { Write-Warning "[failure] $("WMI repository inconsistent")`n$(($out -join ' '))" }
}

<#
.SYNOPSIS
Lists VSS writers and flags non-stable states.
#>
function HealthTest-VssWriters{
  $out=& vssadmin list writers 2>&1
  $bad=($out | Select-String -Pattern 'State: \d+ \((?i:Retryable error|Waiting for completion|Failed)\)')
  if($bad){
    foreach($b in $bad){ Write-Warning "[failure] $("VSS writer not healthy")`n$($b.Line)" }
  } else {
    Write-Warning "[pass] All VSS writers report stable states"
  }
}

<#
.SYNOPSIS
Checks shadow storage presence and size info.
#>
function HealthTest-ShadowStorage{
  [CmdletBinding()] param(
    [string[]]$RequireOnVolumes = @()   # e.g. 'D:','E:'; empty = informational only
  )
  $assoc = Get-CimInstance -ClassName Win32_ShadowStorage 2>$null
  $vols  = Get-CimInstance -ClassName Win32_Volume | Select-Object DeviceID, DriveLetter

  $present = @{}
  if ($assoc) {
    foreach($a in $assoc){
      $volRef = [string]$a.Volume
      $devId  = $null
      if ($volRef -match 'DeviceID="([^"]+)"') { $devId = $Matches[1] }
      if ($devId) { $devId = ($devId -replace '\\\\','\') }
      $drive = $null
      if ($devId -and ($devId -match '^[A-Z]:\\')) {
        $drive = $devId.Substring(0,2)
      } else {
        if ($devId) {
          $m = $vols | Where-Object { $_.DeviceID -eq $devId }
          if ($m -and $m.DriveLetter) { $drive = $m.DriveLetter }
        }
      }
      if (-not $drive) { $drive = $devId }
      if ($drive) { $present[$drive.TrimEnd('\')] = $true }
    }
  }

  if ($RequireOnVolumes.Count -gt 0) {
    $missing = @()
    foreach($v in $RequireOnVolumes){
      $k = $v.TrimEnd('\')
      if (-not $present.ContainsKey($k)) { $missing += $k; Write-Warning "[failure] $("Shadow storage not configured on required volume")`n$($k)" }
    }
    if($missing.Count -eq 0){
      Write-Warning "[pass] $("Shadow storage on required volumes")`n$(("Configured on: " + ((@($present.Keys) | Sort-Object) -join ', ')))"
    }
  } else {
    if ($present.Count -gt 0) {
      Write-Warning "[pass] $("Shadow storage configured")`n$(("On: " + ((@($present.Keys) | Sort-Object) -join ', ')))"
    } else {
      Write-Warning "[notice] Shadow storage (Volume Shadow Copies) is not enabled`nUsers won't see Previous Version for files/folders. (Note that this issue is UNRELATED to the VSS service that backup software use.)"
    }
  }
}

<#
.SYNOPSIS
Scrapes common auto-start locations for rogues.
#>
function HealthTest-StartupItems{
  $paths=@(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
  )
  $items=@()
  foreach($p in $paths){
    if(Test-Path $p){
      $props=Get-ItemProperty $p
      $props.PSObject.Properties | Where-Object { $_.Name -notin 'PSPath','PSParentPath','PSChildName','PSDrive','PSProvider' } | ForEach-Object {
        $items += "$p -> $($_.Name)=$($_.Value)"
      }
    }
  }
  if($items.Count -gt 0){
    Write-Warning ("[pass] Startup items reviewed`n" + ($items -join '; '))
  } else {
    Write-Warning "[pass] No startup items found in standard keys"
  }
}

<#
.SYNOPSIS
Detects duplicate SPNs by querying AD directly (no setspn parsing).

.DESCRIPTION
Enumerates all directory objects that have servicePrincipalName, groups by SPN,
and flags any SPN that appears on more than one distinct object.

RETURNS
[pscustomobject]@{ Pass=bool; Details=string }
#>
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


function Test-MultipleGatewayConfiguration {
<#
.SYNOPSIS
  Validates multi-default-gateway setup and reports good/bad.

.DESCRIPTION
  When multiple IPv4 default routes (0.0.0.0/0) exist, compares TotalMetric
  (RouteMetric + InterfaceMetric) to ensure there is a single clear winner and
  that AutomaticMetric is sensibly configured. Emits Log-Info on good setups,
  or Log-Failure with hints on problems. Includes verbose/debug traces.

.NOTES
  Requires NetTCPIP module (Get-NetRoute/Get-NetIPInterface).
  Uses external Log-Info / Log-Failure helpers.
#>
  [CmdletBinding()]
  param()

  Write-Verbose "[Test-MultipleGatewayConfiguration] Gathering active IPv4 default routes..."
  $routes = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.NextHop -and ($_.State -eq 'Active' -or -not $_.State) }

  if (-not $routes -or $routes.Count -lt 2) {
    Write-Verbose "[Test-MultipleGatewayConfiguration] Fewer than 2 default routes; nothing to validate."
    return
  }

  write-verbose ("[DBG] Raw routes:`n" + (
      $routes | Select ifIndex,InterfaceAlias,NextHop,RouteMetric,InterfaceMetric,State |
      Format-Table -AutoSize | Out-String
  ))

  $table = $routes |
    Select-Object InterfaceAlias,ifIndex,NextHop,RouteMetric,InterfaceMetric,
      @{n='TotalMetric';e={($_.RouteMetric + $_.InterfaceMetric)}} |
    Sort-Object TotalMetric, InterfaceAlias

  write-verbose ("[DBG] Computed table (TotalMetric=Route+Interface):`n" + (
      $table | Format-Table InterfaceAlias,NextHop,RouteMetric,InterfaceMetric,TotalMetric -AutoSize | Out-String
  ))

  $ifAliases = $table.InterfaceAlias | Select-Object -Unique
  $ifInfo = Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $ifAliases -contains $_.InterfaceAlias } |
            Select-Object InterfaceAlias,AutomaticMetric,InterfaceMetric,ConnectionState

  write-verbose ("[DBG] Interface metrics:`n" + (
      $ifInfo | Format-Table InterfaceAlias,AutomaticMetric,InterfaceMetric,ConnectionState -AutoSize | Out-String
  ))

  $best  = $table | Select-Object -First 1
  $worst = $table | Select-Object -Last 1
  $ties  = @($table | Where-Object { $_.TotalMetric -eq $best.TotalMetric }).Count

  $autoOk = (@($ifInfo | Where-Object { $_.AutomaticMetric -eq $true }).Count -eq $ifInfo.Count)
  $allUp  = (@($ifInfo | Where-Object { $_.ConnectionState -eq 'Connected' }).Count -eq $ifInfo.Count)

  write-verbose ("[DBG] Best route: {0} -> {1} (TotalMetric={2})" -f $best.InterfaceAlias,$best.NextHop,$best.TotalMetric)
  write-verbose ("[DBG] Worst route: {0} -> {1} (TotalMetric={2})" -f $worst.InterfaceAlias,$worst.NextHop,$worst.TotalMetric)
  write-verbose ("[DBG] Ties on best metric: {0}" -f $ties)
  write-verbose ("[DBG] AutomaticMetric OK on all?: {0}" -f $autoOk)
  write-verbose ("[DBG] All interfaces connected?: {0}" -f $allUp)

  $list = (( $table | ForEach-Object { "$($_.InterfaceAlias)->$($_.NextHop) (metric=$($_.TotalMetric))" } ) -join ', ')
  $desc = "Detected multiple default gateways: $list. Preferred: $($best.InterfaceAlias)."

  # Good if exactly one best metric AND (all AutomaticMetric enabled OR strictly lower best metric)
  $good = (($ties -eq 1) -and ( $autoOk -or ($best.TotalMetric -lt $worst.TotalMetric) ))

  if ($good) {
    $note = ""
    if (-not $allUp) { $note = " Note: one or more interfaces not Connected; failover may be impaired." }
    Write-Warning "[info] Gateway Configuration looks fine - Windows will prefer $($best.InterfaceAlias).$note"
  } else {
    $hints = @()
    if ($ties -gt 1) { $hints += "Multiple routes share the same lowest TotalMetric (tie)"; }
    if (-not $autoOk) {
      $offenders = ($ifInfo | Where-Object { -not $_.AutomaticMetric } | Select-Object -ExpandProperty InterfaceAlias) -join ', '
      if ($offenders) { $hints += ("AutomaticMetric is disabled on: " + $offenders) }
    }
    if ($best.TotalMetric -ge $worst.TotalMetric) { $hints += "No strictly lower preferred metric found" }
    if (-not $allUp) { $hints += "One or more interfaces not Connected" }
    $hintText = if ($hints.Count) { " Hints: " + ($hints -join '; ') + "." } else { "" }

    Write-Warning "[failure] Multiple Gateways with metrics that may cause routing instability.`n$desc`n$hintText"
  }
}

<#
.SYNOPSIS
Ensures the host does not have multiple default gateways.

.DESCRIPTION
Collects IPv4/IPv6 default gateways from Get-NetIPConfiguration. By default Pass=$true only if the
total count of default gateways (v4+v6) <= 1. Use -AllowOnePerFamily to permit up to one v4 and one v6.
#>
function HealthTest-SingleDefaultGateway{
  [CmdletBinding()] param([switch]$AllowOnePerFamily)
  $cfg = Get-NetIPConfiguration
  $gws = @(
    $cfg | ForEach-Object {
      if ($_.IPv4DefaultGateway) { $_.IPv4DefaultGateway }
      if ($_.IPv6DefaultGateway) { $_.IPv6DefaultGateway }
    }
  )
  $nextHops = @($gws | ForEach-Object { $_.NextHop } | Where-Object { $_ })

  if ($AllowOnePerFamily) {
    $v4 = @($nextHops | Where-Object { $_ -notmatch ':' }).Count
    $v6 = @($nextHops | Where-Object { $_ -match ':' }).Count
    if(($v4 -le 1) -and ($v6 -le 1)){
        Write-Warning "[pass] Default gateways: at most one per IP family"
    } else {
        if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 2) { # server -- always considered a failure
            Write-Warning "[failure] Multiple default gateways detected per IP family`nIPv4=$v4; IPv6=$v6; Gateways=$(($nextHops) -join ', ')"
        } else { # workstation
            Test-MultipleGatewayConfiguration
        }
    }
  } else {
    if($nextHops.Count -le 1){
      Write-Warning "[pass] Default gateways: at most one overall"
    } else {
        if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 2) { # server -- always considered a failure
            Write-Warning "[failure] Multiple default gateways configured`nGateways=$(($nextHops) -join ', ')"
        } else { # workstation
            Test-MultipleGatewayConfiguration
        }
    }
  }
}

<#
.SYNOPSIS
Checks for stale/mismatched DC DNS A records vs. AD DC IPs. OnlyForDCs
#>
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

<#
.SYNOPSIS
Validates DNS recursion configuration (enabled/forwarders/EDNS). OnlyForDCs
#>
function HealthTest-DnsRecursionConfig {
    if (-not (Get-Command Get-DnsServerRecursion -ErrorAction SilentlyContinue)) {
        Write-Warning "[notice] DNS Server tools not available`nDNS role/RSAT missing?"
        return
    }

    $rec   = Get-DnsServerRecursion -ErrorAction SilentlyContinue
    $cache = Get-DnsServerCache     -ErrorAction SilentlyContinue
    $edns  = Get-DnsServerEDns      -ErrorAction SilentlyContinue

    $recEnabled = $null
    if ($rec) {
        $p = $rec.PSObject.Properties['EnableRecursion']
        if ($p) { $recEnabled = $p.Value }
    }

    $maxTtl = $null
    if ($cache) {
        $p = $cache.PSObject.Properties['MaxTTL']
        if ($p) { $maxTtl = $p.Value }
    }

    $ecsEnabled = $null
    if ($edns) {
        $p = $edns.PSObject.Properties['EnableEcsClientSubnet']
        if ($p) { $ecsEnabled = $p.Value }
    }

    # --- Normalize for output ---
    if ($recEnabled -ne $null) { $recText = [string]$recEnabled } else { $recText = 'n/a' }

    if ($maxTtl -ne $null) {
        if ($maxTtl -is [TimeSpan]) {
            $ttlText = ("{0}s" -f [int][Math]::Round($maxTtl.TotalSeconds))
        } elseif ($maxTtl -is [int] -or $maxTtl -is [long]) {
            $ttlText = ("{0}s" -f $maxTtl)
        } else {
            $ttlText = [string]$maxTtl
        }
    } else {
        $ttlText = 'n/a'
    }

    if ($ecsEnabled -ne $null) { $ecsText = [string]$ecsEnabled } else { $ecsText = 'n/a' }

    if ($rec -or $cache -or $edns) {
        Write-Warning (("[pass] No issues found in the DNS recursion configuration`nEnableRecursion={0}; MaxTTL={1}; EDNS-ECS={2}" `
                    -f $recText, $ttlText, $ecsText))
    } else {
        Write-Warning "[notice] Unable to read DNS recursion configuration on this host`nHost is probably not a DNS server"
    }
}


<#
.SYNOPSIS
Confirms reverse lookup zones exist for known subnets. OnlyForDCs
#>
function HealthTest-ReverseZonesPresent{
  [CmdletBinding()] param([string[]]$ExpectedReverseZones)
  $zones=Get-DnsServerZone | Where-Object {$_.IsReverseLookupZone} | Select-Object -ExpandProperty ZoneName
  if(-not $ExpectedReverseZones){ Write-Warning "[pass] $(("Reverse zones present: "+(($zones -join ', ')-replace '^$','<none>')))"; return }
  $missing=@()
  foreach($z in $ExpectedReverseZones){
    if($zones -notcontains $z){ $missing+=$z; Write-Warning "[failure] Reverse zone missing: $z" }
  }
  if($missing.Count -eq 0){ Write-Warning "[pass] All expected reverse zones are present" }
}

<#
.SYNOPSIS
Checks GC placement (at least one per site or per-domain policy). OnlyForDCs
#>
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

<#
.SYNOPSIS
Checks AdminSDHolder applied to protected groups reasonably. OnlyForDomainServers
#>
function HealthTest-AdminSDHolderCoverage{
  $prot=Get-ADUser -LDAPFilter '(adminCount=1)' -Properties MemberOf | Select-Object -ExpandProperty SamAccountName
  if($prot){ Write-Warning "[pass] AdminSDHolder applied; protected users: $($prot -join ", ")" } else { Write-Warning "[pass] No users currently protected by AdminSDHolder" }
}

<#
.SYNOPSIS
DFSR backlog for SYSVOL within threshold. OnlyForDCs
.NOTES Stesses Network: Potentially noticeable on the WAN if run frequently or in parallel
#>
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

<#
.SYNOPSIS
Flags unsigned PnP drivers, ignoring common false positives from core system components.
  OnlyForDomainServers
#>
function HealthTest-UnsignedDrivers {
  [CmdletBinding()]
  param([string[]]$WhitelistDeviceIdRegex = @('^BTHENUM\\'))

  $bad=$false
  $drivers = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_.DeviceName) }

  foreach($d in $drivers){
    $isSigned=$false
    if($d.PSObject.Properties.Name -contains 'IsSigned'){ $isSigned=[bool]$d.IsSigned }
    if($isSigned){ continue }

    $provider=''
    if($d.PSObject.Properties.Name -contains 'DriverProviderName' -and $d.DriverProviderName){ $provider=$d.DriverProviderName }
    elseif($d.PSObject.Properties.Name -contains 'Manufacturer' -and $d.Manufacturer){ $provider=$d.Manufacturer }

    $deviceId=''
    if($d.PSObject.Properties.Name -contains 'DeviceID' -and $d.DeviceID){ $deviceId=[string]$d.DeviceID }

    $isMicrosoft=($provider -match '^(Microsoft|Windows)\b')
    $isWhitelisted=$false
    foreach($rx in $WhitelistDeviceIdRegex){ if($deviceId -match $rx){ $isWhitelisted=$true; break } }

    if($isMicrosoft -or $isWhitelisted){
      $provText = if($provider){" (Provider='$provider')"} else {""}
      $manText  = if($d.Manufacturer){ $d.Manufacturer+', ' } else { '' }
      Write-Warning "[notice] $(("Unsigned device instance treated as benign: {0}{1}{2}" -f $manText,$d.DeviceName,$provText))"
      continue
    }

    $dev = $null
    try{ $dev = Get-PnpDevice -InstanceId $deviceId -ErrorAction Stop }catch{}
    if($dev){
      $p = Get-PnpDeviceProperty -InstanceId $deviceId -ErrorAction SilentlyContinue
      $inf = ($p|? KeyName -eq 'DEVPKEY_Device_DriverInfPath').Data
      $prob= ($p|? KeyName -eq 'DEVPKEY_Device_ProblemCode').Data
      $inst= ($p|? KeyName -eq 'DEVPKEY_Device_InstallState').Data

      # Suppress logical child: empty INF + OK state; verify parent's service is signed
      if([string]::IsNullOrWhiteSpace($inf) -and $dev.Status -eq 'OK' -and ($prob -eq 0 -or -not $prob) -and ($inst -eq 0 -or -not $inst)){
        $parent = ($p|? KeyName -eq 'DEVPKEY_Device_Parent').Data
        if($parent){
          $pp = Get-PnpDeviceProperty -InstanceId $parent -ErrorAction SilentlyContinue
          $svc = ($pp|? KeyName -eq 'DEVPKEY_Device_Service').Data
          if($svc){
            $img = (Get-ItemProperty ("HKLM:\SYSTEM\CurrentControlSet\Services\{0}" -f $svc) -ErrorAction SilentlyContinue).ImagePath
            if($img){
              $expanded = ($img -replace '"','') -replace '%SystemRoot%','\SystemRoot'
              $full = $expanded -replace '^\s*\\SystemRoot', "$env:SystemRoot"
              $sysPath = ($full -split '\s+')[0]
              if(Test-Path $sysPath){
                $sig = Get-AuthenticodeSignature $sysPath
                if($sig.Status -eq 'Valid'){
                  Write-Warning "[notice] $(("Benign logical child without INF: {0} (ParentSvc={1}, Signed={2})" -f $d.DeviceName,$svc,$sig.SignerCertificate.Subject))"
                  continue
                }
              }
            }
          }
        }
      }

      # If INF exists, try to find referenced .sys and check signatures
      if(-not [string]::IsNullOrWhiteSpace($inf)){
        $infPath = if(Test-Path $inf){ $inf } else { Join-Path "$env:SystemRoot\INF" $inf }
        if(Test-Path $infPath){
          $sysNames = Select-String -Path $infPath -Pattern '\.sys' -AllMatches -ErrorAction SilentlyContinue |
                      ForEach-Object { $_.Matches.Value.Trim() } | Select-Object -Unique
          $anyBad=$false
          foreach($name in $sysNames){
            $p1 = Join-Path "$env:SystemRoot\System32\drivers" $name
            $p2 = $null
            try{ $p2 = (Resolve-Path "C:\Windows\System32\DriverStore\FileRepository\*\$name" -ErrorAction SilentlyContinue | Select-Object -First 1).Path }catch{}
            $path = $null
            if($p1 -and (Test-Path $p1)){ $path=$p1 } elseif($p2 -and (Test-Path $p2)){ $path=$p2 }
            if($path){
              $sig = Get-AuthenticodeSignature $path
              if($sig.Status -ne 'Valid'){ $anyBad=$true }
            }
          }
          if(-not $anyBad){
            Write-Warning "[notice] $(("Win32 reports unsigned but INF-linked drivers are signed: {0} (INF={1})" -f $d.DeviceName,(Split-Path $infPath -Leaf)))"
            continue
          }
        }
      }
    }

    $bad=$true
    $ver = if($d.DriverVersion){ $d.DriverVersion } else { '' }
    $man = if($d.Manufacturer){ $d.Manufacturer } else { '' }
    $detail = [string]($d | Select-Object Description,DeviceName,DeviceID,Location,DriverVersion,DriverProviderName,InfName)
    Write-Warning (("[failure] Unsigned 3rd-party driver detected: {0}{1} ver [{2}]`n" -f ($(if($man){"$man, "}), $d.DeviceName, $ver)) + ("Details: {0}" -f $detail))
  }

  if(-not $bad){ Write-Warning "[pass] All non-Microsoft PnP drivers appear signed (benign logical/child nodes and whitelisted instances excluded)." }
}

<#
.SYNOPSIS
Flags unexpected listening TCP ports; ignores 49152-65535 and notes optional baseline ports (3389, 47001, 593). OnlyForDomainServers
.DESCRIPTION
Filters out ports listening only on the loopback addresses (127.0.0.1 and ::1) before checking against allowed ports.
#>
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

function HealthTest-SmbSigningRequired{
  if ((Get-PropValue -obj (Get-Service -Name LanmanServer) -name Status) -ne 'running') {
      Write-Warning "[pass] Skipping HealthTest-SmbSigningRequired; LanmanServer service not running."
      return
  }

  $c=Get-SmbServerConfiguration
  if($c.RequireSecuritySignature){
    Write-Warning "[pass] SMB signing required on the server"
  } else {
    Write-Warning "[warning] SMB signing is not required`nRequireSecuritySignature=$($c.RequireSecuritySignature); EnableSecuritySignature=$($c.EnableSecuritySignature)"
  }
}


function HealthTest-SoftwareLicensing{
    Get-SoftwareLicensing | %{
        # ($_ | Format-List * -Force | Out-String).Trim()|write-host -f green
        Write-BasedOnTestResult "Is $($_.ProductName) Licensed?" -Test $_.IsLicensed -comment "$_"
    }
}


function HealthTest-NtdsPathsLocation{
  [CmdletBinding()]
  param(
    [string[]]$ExpectedDbRoots,
    [string[]]$ExpectedLogRoots
  )
  $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
  $db = (Get-ItemProperty -Path $regPath -Name 'DSA Database file' -ErrorAction Stop).'DSA Database file'
  $lg = (Get-ItemProperty -Path $regPath -Name 'Database log files path' -ErrorAction Stop).'Database log files path'

  $dbOk = if($ExpectedDbRoots -and $ExpectedDbRoots.Count){
    ($ExpectedDbRoots | Where-Object { $db -like "$_*" -or ([IO.Path]::GetPathRoot($db) -eq $_) }).Count -gt 0
  } else { $true }
  if(-not $dbOk){ Write-Warning "[failure] NTDS database path not on an expected volume`nDB=$db; Expected roots: $($ExpectedDbRoots -join ', ')" }

  $lgOk = if($ExpectedLogRoots -and $ExpectedLogRoots.Count){
    ($ExpectedLogRoots | Where-Object { $lg -like "$_*" -or ([IO.Path]::GetPathRoot($lg) -eq $_) }).Count -gt 0
  } else { $true }
  if(-not $lgOk){ Write-Warning "[failure] NTDS log path not on an expected volume`nLOGS=$lg; Expected roots: $($ExpectedLogRoots -join ', ')" }

  if($dbOk -and $lgOk){ Write-Warning "[pass] NTDS database/log paths sane (DB=$db; LOGS=$lg)" }
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
