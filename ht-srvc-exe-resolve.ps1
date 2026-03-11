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
<#
.SYNOPSIS
Verifies DFS Namespace (domain-based) objects enumerate without error. OnlyForDomainServers
#>
<#
.SYNOPSIS
Lists SYSTEM-scheduled tasks that are disabled, stale, or failing.
#>

<#
.SYNOPSIS
Checks SYSVOL NTFS ACLs do not grant write to broad principals. OnlyForDCs
#>

<#
.SYNOPSIS
Reports accounts permitting RC4 via msDS-SupportedEncryptionTypes. OnlyForDomainServers
#>

<#
.SYNOPSIS
Ensures DHCP server presence/authorization sane if role installed. OnlyForDomainServers
#>

<#
.SYNOPSIS
Flags enabled NICs that are disconnected (cleanup). OnlyForDomainServers
#>

<#
.SYNOPSIS
Checks active interface metrics for sane binding preference. OnlyForDomainServers
#>

<#
.SYNOPSIS
Detects disabled GPO links at domain root (policy choice). OnlyForDCs
#>
<#
.SYNOPSIS
Ensures event log max sizes meet baseline without reading events. OnlyForDomainServers
#>

<#
.SYNOPSIS
Runs DCDIAG RIDManager and checks for failures or low pool signals. OnlyForDCs
#>

<#
.SYNOPSIS
Checks presence of EFS Data Recovery Agents policy/certs. OnlyForDomainServers
#>

<#
.SYNOPSIS
Verifies DNS zone transfers are restricted. OnlyForDCs
#>

<#
.SYNOPSIS
Flags stale krbtgt (pwdLastSet age above threshold). OnlyForDomainServers
.NOTES
What a failure means: The KRBTGT account key hasn't been rotated for years. Windows keeps the previous KRBTGT key to validate existing TGTs; never rotating extends the window for 'golden ticket' persistence if the key ever leaked.
Risk: If an attacker ever accessed the KRBTGT key, they can mint TGTs and persist. Rotating twice (with replication time in between) is the standard mitigation.
Severity: Critical.
#>
<#
.SYNOPSIS
Ensures NTDS log volume free space above threshold. OnlyForDCs
#>
<#
.SYNOPSIS
Verifies required hotfix baseline is present. OnlyForDomainServers
#>

<#
.SYNOPSIS
Validates DHCP DNS update credential account health. OnlyForDomainServers
#>

<#
.SYNOPSIS
Validates GPT vs GPC version numbers for GPO consistency. OnlyForDomainServers
#>

<#
.SYNOPSIS
Compares SYSVOL policy tree manifest across DCs (count+hash). OnlyForDCs
.NOTES 
Stresses Network: SMB directory tree walks to each DC's SYSVOL\Policies across sites.
#>
<#
.SYNOPSIS
Reviews RODC PRP (allow/deny) presence where RODCs exist. OnlyForDomainServers
#>

<#
.SYNOPSIS
Reports members of 'Pre-Windows 2000 Compatible Access' (should be empty). OnlyForDomainServers
#>

<#
.SYNOPSIS
Validates GP WMI filters use namespaces that exist on this host. OnlyForDomainServers
#>
<#
.SYNOPSIS
Verifies Windows are Licensed.
#>
<#
.SYNOPSIS
Checks if TPM is activated. OnlyForMobile
#>



<#
.SYNOPSIS
Checks DNS suffix for the AD domain. OnlyForDomain,NotForDCs
#>
<#
.SYNOPSIS
Checks that the domain DNS name A record points to at least one DC IP. OnlyForDomain,NotForDCs

IMPORTANT: Invoke-GetHealthDomainComputers.ps1 must pass all DC IPs via
	`-IpsOfAllDcs`. E.g:
	@("192.168.0.1","192.168.0.2")
#>
<#
.SYNOPSIS
Ensures each interface DNS server list contains only DC IPs. OnlyForDomain,NotForDCs

IMPORTANT: Invoke-GetHealthDomainComputers.ps1 must pass all DC IPs via
	`-IpsOfAllDcs`. E.g:
	@("192.168.0.1","192.168.0.2")
#>
<#
.SYNOPSIS
Verifies NLTEST /dsgetsite can determine the client AD site. OnlyForDomain,NotForDCs
#>
<#
.SYNOPSIS
Runs gpupdate and validates computer and user policy application. OnlyForDomain,NotForDCs
#>
#--------------------------------------------------------
# xxx new tests 20205-11-26

<# .SYNOPSIS Checks recent critical disk/NTFS/storage errors in the System event log. #>

<# .SYNOPSIS Looks for crash dumps and bugcheck events as indicators of recent system crashes. #>
<# .SYNOPSIS Detects unexpected members in the local Administrators group. #>

<# .SYNOPSIS Checks physical NICs for link problems and significant error rates. #>
<# .SYNOPSIS Summarizes BitLocker protection status for local volumes. #>
<# .SYNOPSIS Detects DHCP scopes whose utilization is close to exhaustion. #>
<#
.SYNOPSIS
  Verifies key DNS suffix/devolution/registration settings for a small, single-domain AD.
#>
<#
.SYNOPSIS
HealthTest-ADReplicationDomainRepadmin: Domain-wide AD replication health using repadmin.exe (replsum + showreps). DC-only; fails if repadmin or AD DS prerequisites are missing.
#>

<#
.SYNOPSIS
HealthTest-ADReplicationLocalRSAT: Local DC AD replication partner health using RSAT AD cmdlets (Get-ADReplicationPartnerMetadata). DC-only; fails if AD module/ADWS prerequisites are missing.
#>

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
<#
.SYNOPSIS
Lists all Windows services along with their executable paths and vendor information. Also detects services with broken executable paths.

.DESCRIPTION
Enumerates all services on the system using Win32_Service, resolves each service's executable path from its PathName,
and inspects the executable's Authenticode signature to extract the vendor/publisher name.
Also emits failures if the executable is missing.
Returns a list of objects with ServiceName, Vendor, and ExePath properties.
#>
<#
.SYNOPSIS
 Return free space in GB for a drive or path.
.OUTPUTS   System.Double (GB) or $null if undeterminable.
.NOTES     Resolves a path to its drive root; tries PSDrive then .NET DriveInfo.
#>
<#
.SYNOPSIS  Check a drive/path and emit a status; returns an object with details.
.PARAMETER PathOrDrive  Drive letter or any path.
.PARAMETER WarnPct      Warning threshold (default 10).
.PARAMETER ErrorPct     Error threshold (default 5).
.OUTPUTS   PSCustomObject with Drive,Type,FreeGB,TotalGB,PercentFree,Level; or nothing if not applicable.
#>
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
# --- Resolve-ServiceExecutable Helper:
# Strict invalid-path-char check for *paths* (returns $true => treat as invalid => return $null) ---
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
<#
.SYNOPSIS  Check a drive/path and emit a status; returns an object with details.
.PARAMETER PathOrDrive  Drive letter or any path.
.PARAMETER WarnPct      Warning threshold (default 10).
.PARAMETER ErrorPct     Error threshold (default 5).
.OUTPUTS   PSCustomObject with Drive,Type,FreeGB,TotalGB,PercentFree,Level; or nothing if not applicable.
#>
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
                    Write-Warning "[info] This service is stoped but its last execution terminated NORMALY and it's one of the services that are often stopped: Service '$($_.Name)', StartMode=$($_.StartMode), DelayedAutoStart=$($_.DelayedAutoStart), last ExitCode=$($_.ExitCode)($exitCodeMeaning)."} else {
                if ($_.ExitCode  -in (0,1077)) {
                    Write-Warning "[notice] Service '$($_.Name)' which is set to automatically start is not running; calmingly its last execution terminated normally: ExitCode=$($_.ExitCode)($exitCodeMeaning).`nDisplay name: $($_.DisplayName), StartMode=$($_.StartMode), DelayedAutoStart=$($_.DelayedAutoStart), last ExitCode=$($_.ExitCode)($exitCodeMeaning)."
                } else {
                    Write-Warning "[failure] Service '$($_.Name)' which is set to automatically start is not running; alarmingly its last execution terminated abnormally: ExitCode=$($_.ExitCode)($exitCodeMeaning).`nDisplay name: $($_.DisplayName), StartMode=$($_.StartMode), DelayedAutoStart=$($_.DelayedAutoStart), last ExitCode=$($_.ExitCode)($exitCodeMeaning)."
                }
            }
        }
    } else {
        Write-Warning "[pass] All services that are set to automatically start are running"}
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
            Write-Warning "[warning] Either something's wrong with service '$($_.ServiceName)' or there's a bug in Get-ServiceVendors.`n$($_.ExceptionsThrown)"
        } else {
            if ($isHostServer -or ($_.Vendor -notin $COMMON_VENDORS_FOR_WORKSTATIONS)) {
                $comment = "Admin must verify if service is legit and needed. Service Description: '$($_.DisplayName)'`nExecutable: '$($_.ExePath)'."
                Write-Warning "[warning] Found service that is not a core Microsoft service: Vendor='$($_.Vendor)' Name='$TrimmdServiceName'$extra_msg`n$comment"
            } else {
                $comment = "It is however from a common vendor. Admin must verify if service is legit and needed. Service Description: '$($_.DisplayName)'`nExecutable: '$($_.ExePath)'."
                Write-Warning "[notice] Found service that is not a core Microsoft service: Vendor='$($_.Vendor)' Name='$TrimmdServiceName'$extra_msg`n$comment"
            }
        }
    }
    if ($ok) {Write-Warning "[pass] Found no service except Microsoft ones"}
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
