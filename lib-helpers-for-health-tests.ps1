<#
This is a library with the helper functions for the HealthTest- functions
#>

# Win32 interop used by helper functions (documented APIs)
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

<# 
.SYNOPSIS
Builds a time-bucketed profile of files in a directory.

.OUTPUTS
Produces a psCustomObject for each time period bucket:
  period   : Period key as a string (YYYY, YYYY-MM, or YYYY-MM-DD)
  count    : Number of files in the period
  total_mb : Total size (MB) of files in the period
  top_exts : Text summary of the most common extensions in the period
  oldest   : Oldest LastWriteTime observed in the input set
  newest   : Newest LastWriteTime observed in the input set

.DESCRIPTION
Enumerates files under the provided directory and groups them by a
computed period derived from LastWriteTime. The grouping granularity
depends on the time span between the oldest and newest file:
- < 15 days: group by YYYY-MM-DD
- >= 15 days and < 12 months: group by YYYY-MM
- >= 12 months: group by YYYY

May throw on invalid paths, access failures, or file enumeration errors.

.EXAMPLE
Get-DirFileProfile "C:\Windows\" | ft

period count total_mb top_exts                    oldest              newest
------ ----- -------- --------                    ------              ------
2026      10    18.46 5 .exe, 3 .log, 1 .dll, ... 2019-12-07 11:10:06 2026-02-27 11:14:04
2021       8     9.94 4 .log, 1 .xml, 1 .txt, ... 2019-12-07 11:10:06 2026-02-27 11:14:04
2024       5     0.39 2 .log, 1 .xml, 1 .prx, ... 2019-12-07 11:10:06 2026-02-27 11:14:04
2025       5     1.62 3 .exe, 2 .log              2019-12-07 11:10:06 2026-02-27 11:14:04
2023       4     1.51 2 .exe, 1 .ini, 1 .dll      2019-12-07 11:10:06 2026-02-27 11:14:04
2022       3   1809.9 1 .zip, 1 .txt, 1 .dmp      2019-12-07 11:10:06 2026-02-27 11:14:04
2019       3     0.03 2 .ini, 1 .xml              2019-12-07 11:10:06 2026-02-27 11:14:04

#>
function Get-DirFileProfile {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Path
  )

  $files = Get-ChildItem -LiteralPath $Path -File -ErrorAction Stop
  if (-not $files) { return @() }

  $oldest = ($files | Sort-Object LastWriteTime | Select-Object -First 1).LastWriteTime
  $newest = ($files | Sort-Object LastWriteTime | Select-Object -Last 1).LastWriteTime

  $spanDays = [math]::Abs((New-TimeSpan -Start $oldest -End $newest).TotalDays)

  if ($spanDays -lt 15) { $fmt = 'yyyy-MM-dd' }
  elseif ($spanDays -lt 365) { $fmt = 'yyyy-MM' }
  else { $fmt = 'yyyy' }

  function _FormatTopExts {
    param([object[]]$GroupFiles)

    $extGroups =
      $GroupFiles |
      Group-Object { if ($_.Extension) { $_.Extension.ToLowerInvariant() } else { '(noext)' } } |
      Sort-Object Count,Name -Descending

    if (-not $extGroups -or $extGroups.Count -eq 0) { return "" }

    if ($extGroups.Count -eq 1) {
      $only = $extGroups[0].Name
      if ($only -eq '(noext)') { return "all (noext)" }
      return "all $only"
    }

    $top3 = $extGroups | Select-Object -First 3
    $s = ($top3 | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
    if ($extGroups.Count -gt 3) { $s += ", ..." }
    $s
  }

  $files |
    Group-Object { $_.LastWriteTime.ToString($fmt) } |
    ForEach-Object {
      $sum = ($_.Group | Measure-Object Length -Sum).Sum
      [pscustomobject]@{
        period   = $_.Name
        count    = $_.Count
        total_mb = [math]::Round($sum / 1MB, 2)
        top_exts = _FormatTopExts -GroupFiles $_.Group
        oldest   = $oldest
        newest   = $newest
      }
    } |
    Sort-Object Count,Name -Descending
}


<#
.SYNOPSIS
Formats a directory file profile into a concise narrative string.

.OUTPUTS
Produces a string containing:
- Oldest and newest timestamps taken from the provided profile objects
- One sentence per included period with size, file count, and top_exts

.DESCRIPTION
May throw if the pipeline input cannot be enumerated or if required
fields are not present.

.INPUTS
Accepts profile objects from the pipeline.

.PARAMETER Profile
The profile objects to summarize. Each object should include:
period, count, total_mb, top_exts, oldest, newest.

.PARAMETER MaxPeriods
When greater than 0, limits the number of period sentences emitted.

.PARAMETER SingleLine
When set, emits a single-line narrative; otherwise emits multiple lines.

.EXAMPLE
Get-DirFileProfile "C:\Windows\" | Format-DirFileProfileNarrative

Oldest file at 12/07/2019 11:10:06. Newest at 02/27/2026 11:20:25.
0.03 MB in 3 files during 2019 (2 .ini, 1 .xml).
9.94 MB in 8 files during 2021 (4 .log, 1 .xml, 1 .txt, ...).
1809.9 MB in 3 files during 2022 (1 .zip, 1 .txt, 1 .dmp).
1.51 MB in 4 files during 2023 (2 .exe, 1 .ini, 1 .dll).
0.39 MB in 5 files during 2024 (2 .log, 1 .xml, 1 .prx, ...).
1.62 MB in 5 files during 2025 (3 .exe, 2 .log).
18.46 MB in 10 files during 2026 (5 .exe, 3 .log, 1 .dll, ...).
#>
function Format-DirFileProfileNarrative {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
    [object[]]$Profile,

    [int]$MaxPeriods = 0,

    [switch]$SingleLine
  )

  begin { $all = New-Object System.Collections.Generic.List[object] }
  process { foreach ($p in $Profile) { [void]$all.Add($p) } }
  end {
    if ($all.Count -eq 0) { return "" }

    $oldest = ($all | Select-Object -First 1).oldest
    $newest = ($all | Select-Object -First 1).newest

    $periods = $all | Sort-Object period
    if ($MaxPeriods -gt 0 -and $periods.Count -gt $MaxPeriods) {
      $periods = $periods | Select-Object -First $MaxPeriods
    }

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add("Oldest file at $oldest. Newest at $newest.")

    foreach ($p in $periods) {
      $mb = $p.total_mb
      $cnt = $p.count
      $per = $p.period
      $exts = $p.top_exts
      if ($exts) { $parts.Add("$mb MB in $cnt files during $per ($exts).") }
      else { $parts.Add("$mb MB in $cnt files during $per.") }
    }

    if ($SingleLine) { return ($parts -join ' ') }
    ($parts -join [Environment]::NewLine)
  }
}

function Get-AllDCIPs {
<#
.SYNOPSIS
  Loads and validates the list of Domain Controller IPv4 addresses from a JSON config file.

.DESCRIPTION
  Expected file format:
    {"ips":["192.168.0.1","192.168.0.2"]}

.OUTPUTS
  [string[]]  List of validated IPv4 addresses
#>

  [CmdletBinding()]
  param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Path
  )

  function Test-IPv4 {
    param([Parameter(Mandatory)][string]$IP)

    $null -ne (
      $IP -as [ipaddress]
    ) -and (
      ([ipaddress]$IP).AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
    )
  }

  try { $null = Get-Item -LiteralPath $Path -ErrorAction Stop }
  catch {
    $e = New-Object System.Management.Automation.ErrorRecord(
      $_.Exception, "DcIpConfigNotAccessible", [System.Management.Automation.ErrorCategory]::OpenError, $Path
    )
    $e.ErrorDetails = New-Object System.Management.Automation.ErrorDetails(
      "DC IP config file not accessible: $Path. $($_.Exception.Message)"
    )
    throw $e
  }

  $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop

  if ([string]::IsNullOrWhiteSpace($text)) {
    throw "DC IP config file is empty: $Path --  File should contain the IPs of all DCs in json format. Example:`n{`"ips`":[`"192.168.0.1`",`"192.168.0.2`"]}"
  }

  try { 
    $json = ConvertFrom-Json -InputObject $text -ErrorAction Stop 
  } catch {
    $msg = "Invalid JSON in $Path. Expected format:`n{`"ips`":[`"192.168.0.1`",`"192.168.0.2`"]}"
    throw (New-Object System.Exception($msg, $_.Exception))
  }

  if (-not ($json.PSObject.Properties.Name -contains 'ips')) {
    throw "Config missing required property 'ips'. Expected format:`n{`"ips`":[`"192.168.0.1`",`"192.168.0.2`"]}"
  }

  $ips = @($json.ips | Where-Object { $_ -and $_.ToString().Trim() })

  if ($ips.Count -eq 0) {
    throw "No DC IPs discovered in $Path. Expected format:`n{`"ips`":[`"192.168.0.1`",`"192.168.0.2`"]}"
  }

  $valid = New-Object System.Collections.Generic.List[string]
  $invalid = New-Object System.Collections.Generic.List[string]
  
  foreach ($ip in $ips) {
    $ipStr = $ip.ToString().Trim()
    if ((Test-IPv4 $ipStr) -and (-not $valid.Contains($ipStr))) { $null = $valid.Add($ipStr) }
    else { $null = $invalid.Add($ipStr) }
  }
  
  $valid = $valid.ToArray()
  $invalid = $invalid.ToArray()

  if ($invalid.Count -gt 0) {
    throw "Invalid IPv4 address(es) in $($Path): $($invalid -join ', '). Expected format:`n{`"ips`":[`"192.168.0.1`",`"192.168.0.2`"]}"
  }

  if (-not $valid -or $valid.Count -eq 0) {
      throw "No DC IPs discovered. $Path should contain the IPs of all DCs in json format. Example:`n{`"ips`":[`"192.168.0.1`",`"192.168.0.2`"]}"
  }

  return $valid
}

# --- Win32 argv helper 
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

<#
.SYNOPSIS
Translates a Scheduled Task LastTaskResult/exit code to a friendly message.

.DESCRIPTION
Maps common Task Scheduler result codes to readable meanings (success, refused, access denied,
service not started, lifecycle states 267008-267014, and common Win32 error wrappers). Falls back
to decoding 0x8007xxxx into Win32 and, when possible, retrieving a system message.

.PARAMETER Code
The numeric result/exit code from Scheduled Tasks.

.OUTPUTS
[string] A short description including the hex form when useful.

.EXAMPLE
Convert-TaskResultCode 2147942405
Access denied (0x80070005)

.EXAMPLE
Get-ScheduledTask | % { $_.TaskName, (Convert-TaskResultCode (Get-ScheduledTaskInfo $_.TaskName).LastTaskResult) }

.NOTES
Used by HealthTest-ScheduledTasks
#>
function Convert-TaskResultCode{
  param([int64]$Code)
  $hex = ('0x{0:X8}' -f $Code)
  switch($Code){
    0{"Success (0)"}
    2147750687{"Operator/admin refused ($hex)"}
    2147942402{"File not found ($hex)"}
    2147942403{"Path not found ($hex)"}
    2147942405{"Access denied ($hex)"}
    2147954402{"Service not started ($hex)"}
    267008{"Ready ($hex)"}
    267009{"Running ($hex)"}
    267010{"Disabled ($hex)"}
    267011{"Not yet run ($hex)"}
    267012{"No more runs ($hex)"}
    267013{"Terminated ($hex)"}
    267014{"No active triggers ($hex)"}
    2147946720{"Either wrong password or win32 error 0x800710E0('The operator or administrator has refused the request')"}
    default{
          $win32 = if ($Code -band 0x80070000) { $Code -band 0xFFFF } else { $Code }
          try {
            $win32msg = (New-Object ComponentModel.Win32Exception ([int]$win32)).Message
          } catch {
            $win32msg = ""
          }
          if ($win32msg) {"Possible win32 error $hex('$win32msg')"} else {"Non standard code hex=$hex"}
    }
  }
}

<#
.SYNOPSIS
Parses dcdiag output and returns only failed test blocks. Will either run dcdiag or use an existing file with dcdiag output.

.DESCRIPTION
Parses dcdiag's output looking for failed tests.
If no File is given, it runs dcdiag.
If a File is given it reads that assuming its the output of dcdiag > File.
For each failed test it finds it outputs a structured object including the
phase where the failure occured, server, test name,
path, status, failure line, and the full block text of the failed test.

.PARAMETER File
Optional path to a dcdiag output file to parse.

.PARAMETER Comprehensive
Switch: set to perform comprehensive diagnostics (/c).

.OUTPUTS
[pscustomobject] with properties:
Phase, Server, Test, Path, Status, FailureLine, BlockText

.EXAMPLE
Get-DcDiagFailures -Comprehensive

Runs dcdiag /c and returns all failed tests.

.EXAMPLE
Get-DcDiagFailures -Path .\dcdiag.txt

Parses a saved dcdiag log and returns all failed tests.

.NOTES
Only tests that explicitly end with "failed test <name>" are returned.
Tests that pass or only contain warnings are ignored.

TODO:
1) verify that at list one line that contains "Starting test"
is contained in the output. If not raise exception "unrecognised dcdiag output"
2) If dcdiag returns a useful exit code use it to raise a suitable exception.
#>
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

function Get-RecentFilesConditional {
<#
.SYNOPSIS
Tests whether a directory contains a number of recent files within given size and age bounds, and if it does returns them ordered by LastWriteTime.

.DESCRIPTION
Counts files in a directory that:
 - Match one or more DOS patterns (e.g. "*.vbk", "*.vib").
 - Are at least MinBytes in size (if specified).
 - Were created within the last MaxAgeHours hours (if specified).
It returns $true if the final count is between MinCount and MaxCount (inclusive), otherwise $false.

If the path does not exist, the function always returns $false, regardless of MinCount/MaxCount.

PARAMETERS
 -Path
    The directory to search. Must exist; otherwise the function returns $false.

 -Pattern
    One or more DOS wildcards (e.g. "*.vbk", "*.vib").
    A single string or an array of strings is allowed.
    Files matching ANY of the patterns are counted (logical OR).

 -MinBytes
    Minimum file size in bytes. Only files with Length -ge MinBytes are counted.
    If omitted, size is not checked.

 -MaxAgeHours
    Only files with CreationTime within the last MaxAgeHours hours are counted.
    If omitted, age is not checked.

 -MinCount
    Minimum number of matching files required (inclusive).
    Defaults to 1 if not specified.

 -MaxCount
    Maximum number of matching files allowed (inclusive).
    Defaults to [int]::MaxValue if not specified.

 -Recurse
    If supplied, search subfolders recursively; otherwise only the top-level folder is searched.

RETURN VALUE
    The matching files ordered by LastWriteTime, if their number is between MinCount
    and MaxCount (inclusive), otherwise $null. You can use the return value as a boolean
    because $null is falsy and 1 or more items are truthy

EXAMPLE
    # At least one .vbk in C:\Backups, >= 100 GB, created within the last 24 hours
    Get-RecentFilesConditional -Path 'C:\Backups' -Pattern '*.vbk' -MinBytes 100GB -MaxAgeHours 24

EXAMPLE
    # Any combination of .vbk or .vib files, >= 1 GB, in the last 12 hours, including subfolders
    Get-RecentFilesConditional -Path 'C:\Backups' -Pattern '*.vbk','*.vib' -MinBytes 1GB -MaxAgeHours 12 -Recurse

EXAMPLE
    # Check there are between 3 and 10 recent *.log files of any size in the last 2 hours
    Get-RecentFilesConditional -Path 'C:\Logs' -Pattern '*.log' -MaxAgeHours 2 -MinCount 3 -MaxCount 10

EXAMPLE
    # Treat "any files at all in the folder" as success (MinCount = 1 by default)
    Get-RecentFilesConditional -Path 'C:\SomeFolder'

EXAMPLE
    # Path does not exist: always returns $false, regardless of MinCount/MaxCount
    Get-RecentFilesConditional -Path 'C:\NotARealFolder' -MinCount 0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]  $Path,
    [string[]]                      $Pattern    = '*',
    [Nullable[long]]                $MinBytes,
    [Nullable[double]]              $MaxAgeHours,
    [Nullable[int]]                 $MinCount,
    [Nullable[int]]                 $MaxCount,
    [switch]                        $Recurse
)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    if ($MinCount -eq $null) { $MinCount = 1 }
    if ($MaxCount -eq $null) { $MaxCount = [int]::MaxValue }

    $items = @()
    foreach ($p in $Pattern) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $items += Get-ChildItem -LiteralPath $Path -Filter $p -File -Recurse:$Recurse -ErrorAction SilentlyContinue
    }

    if (-not $items) {
        $count = 0
        return ($count -ge $MinCount -and $count -le $MaxCount)
    }

    $items = $items | Sort-Object FullName -Unique

    if ($MinBytes -ne $null) {
        $items = $items | Where-Object { $_.Length -ge $MinBytes }
    }

    if ($MaxAgeHours -ne $null) {
        $cutoff = (Get-Date).AddHours(-$MaxAgeHours)
        $items = $items | Where-Object { $_.CreationTime -ge $cutoff }
    }

    $count = ($items | Measure-Object | Select-Object -ExpandProperty Count)

    if ($count -ge $MinCount -and $count -le $MaxCount) {
        return ($items | Sort-Object -Property LastWriteTime)
    } else {
        return $null
    }
}

<#
.SYNOPSIS
Fast Test-NetConnection implementation with one exception: it doesn't ping by default.

.DESCRIPTION
Resolves a host and attempts a TCP connect with a short timeout. Supports either a specific -Port
or a friendly -CommonTCPPort (HTTP, RDP, SMB, WINRM). If -InformationLevel Quiet is used,
returns only $true/$false for TCP success. Optionally tries a single ICMP echo via Test-Connection
when -TryPingingHost is provided.

.PARAMETER ComputerName
Target host or FQDN. Defaults to 'localhost'. Alias: -TargetName (compat with Test-NetConnection).

.PARAMETER Port
TCP port number to test. Mutually exclusive with -CommonTCPPort.

.PARAMETER CommonTCPPort
One of HTTP(80), RDP(3389), SMB(445), WINRM(5985). Mutually exclusive with -Port.

.PARAMETER InformationLevel
Detailed (default) returns an object with fields similar to Test-NetConnection; Quiet returns [bool].

.PARAMETER TryPingingHost
When present, issues a single ping; result is reflected in PingSucceeded.

.OUTPUTS
When -InformationLevel Detailed: PSCustomObject { ComputerName, RemoteAddress, RemotePort, ..., TcpTestSucceeded }.
When -InformationLevel Quiet: [bool] indicating TCP connect success.

.EXAMPLE
Test-NetConnectionFast -ComputerName srv1 -Port 445
Tests TCP 445 on srv1 and returns a detailed object.

.EXAMPLE
Test-NetConnectionFast api.example.com -CommonTCPPort HTTP -InformationLevel Quiet
Returns $true if TCP 80 connects within the timeout; otherwise $false.

.NOTES
Does not send/receive payload; uses TcpClient.BeginConnect with ~100 ms default timeout.
#>
function Test-NetConnectionFast {
  [CmdletBinding()]
  param(
    [Parameter(ValueFromPipelineByPropertyName=$true)]
    [Alias('TargetName')]
    [string]$ComputerName = 'localhost',

    [Parameter(ParameterSetName='ByPort')]
    [int]$Port,

    [Parameter(ParameterSetName='ByCommon')]
    [ValidateSet('HTTP','RDP','SMB','WINRM')]
    [string]$CommonTCPPort,

    [ValidateSet('Detailed','Quiet')]
    [string]$InformationLevel = 'Detailed',

    [switch]$TryPingingHost
  )

  begin {
    $COMMON_MAP = @{
      HTTP = 80; RDP = 3389; SMB = 445; WINRM = 5985
    }
    $TIMEOUT_MS = 100
  }

  process {
    $remoteAddr = $null
    try {
      $ips = [System.Net.Dns]::GetHostAddresses($ComputerName)
      if ($ips) {
        $ipv4 = @($ips | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork })
        if ($ipv4 -and $ipv4.Count -gt 0) { $remoteAddr = $ipv4[0].ToString() }
        else { $remoteAddr = $ips[0].ToString() }
      }
    } catch {}

    $resolvedPort = $null
    if ($PSCmdlet.ParameterSetName -eq 'ByCommon') { $resolvedPort = $COMMON_MAP[$CommonTCPPort] }
    elseif ($PSCmdlet.ParameterSetName -eq 'ByPort') { $resolvedPort = $Port }

    if ($TryPingingHost) {
        $pingOk = $false
        try { $pingOk = Test-Connection -ComputerName $ComputerName -Count 1 -Quiet -ErrorAction SilentlyContinue } catch {}
    } else {
        $pingOk = $null
    }

    $tcpOk = $false
    if ($resolvedPort) {
      $client = New-Object System.Net.Sockets.TcpClient
      try {
        $ar = $client.BeginConnect($ComputerName, $resolvedPort, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($TIMEOUT_MS)) {
          try { $client.EndConnect($ar); $tcpOk = $true } catch {}
        }
      } finally {
        try { $client.Close() } catch {}
      }
    }

    if ($InformationLevel -eq 'Quiet') { return $tcpOk }

    [pscustomobject]@{
      ComputerName      = $ComputerName
      RemoteAddress     = $remoteAddr
      RemotePort        = $resolvedPort
      InterfaceAlias    = $null
      SourceAddress     = $null
      PingSucceeded     = $pingOk
      PingReplyDetails  = $null
      TcpTestSucceeded  = $tcpOk
    }
  }
}

<#
.SYNOPSIS
Converts an ISO-8601 duration to a concise human string.

.DESCRIPTION
Parses a subset of ISO-8601 durations like 'PT5M', 'PT1H30M', 'P2DT10S'. Returns a space-separated,
pluralized string (e.g., '5 minutes', '1 hour 30 minutes'). If input is $null returns $null.
If parsing fails, returns the original string unchanged.

.PARAMETER Iso
ISO-8601 duration (e.g., 'PT45S', 'PT2H', 'P1DT5M').

.OUTPUTS
[string] humanized duration, $null if input is $null.

.EXAMPLE
Convert-ISODuration -Iso 'PT45S'
45 seconds

.EXAMPLE
Convert-ISODuration 'P1DT2H'
1 day 2 hours

.NOTES
Intended for summarizing Task Scheduler repetition/limits; supports Days/Hours/Minutes/Seconds.
#>
function Convert-ISODuration{
  param([string]$Iso)
  if(-not $Iso){return $null}
  $m=[regex]::Match($Iso,'^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$')
  if(-not $m.Success){return $Iso}
  $parts=@()
  if($m.Groups[1].Value){$n=[int]$m.Groups[1].Value;$parts+=("$n day"+($(if($n-ne 1){'s'}else{''})))}
  if($m.Groups[2].Value){$n=[int]$m.Groups[2].Value;$parts+=("$n hour"+($(if($n-ne 1){'s'}else{''})))}
  if($m.Groups[3].Value){$n=[int]$m.Groups[3].Value;$parts+=("$n minute"+($(if($n-ne 1){'s'}else{''})))}
  if($m.Groups[4].Value){$n=[int]$m.Groups[4].Value;$parts+=("$n second"+($(if($n-ne 1){'s'}else{''})))}
  if($parts.Count -eq 0){return $Iso}
  $parts -join ' '
}

<#
.SYNOPSIS
Returns rich details about a Scheduled Task, including actions, triggers, settings, and recent runs.

.DESCRIPTION
Finds one or more tasks by -TaskName (optionally restricting with -TaskPath). For each, collects:
state, enablement, author/principal, last/next run info, actions, triggers (with repetition,
durations, summaries), and key settings. Attempts to read the task's RegistrationInfo.Description
via Export-ScheduledTask for better fidelity.

.PARAMETER TaskName
Exact task name to query. Mandatory.

.PARAMETER TaskPath
Optional task path (e.g., '\Microsoft\Windows\Defrag\'). If omitted, searches all tasks with the name.

.OUTPUTS
PSCustomObject per task with properties: PathPlusName, State, Enabled, Actions[], Triggers[],
Settings, LastTaskResult (both code and decoded), Description, Principal*, LastRunTime, NextRunTime, etc.

.EXAMPLE
Get-ScheduledTaskDeepInfo -TaskName 'Restart'
Shows a detailed view for any task named 'Restart'.

.EXAMPLE
Get-ScheduledTaskDeepInfo -TaskName 'Defrag' -TaskPath '\Microsoft\Windows\Defrag\'
Restricts to the specified path.

.NOTES
Uses Export-ScheduledTask to capture description; may require admin rights for some tasks.
#>
function Get-ScheduledTaskDeepInfo{
  [CmdletBinding()]param(
    [Parameter(Mandatory=$true)][string]$TaskName,
    [string]$TaskPath
  )

  function _TaskDesc($n,$p){
    try{([xml](Export-ScheduledTask -TaskName $n -TaskPath $p -ErrorAction Stop)).Task.RegistrationInfo.Description}
    catch{$null}
  }
  function _TrigType($tr){
    if($tr.PSObject.Properties.Match('TriggerType').Count -and $tr.TriggerType){return $tr.TriggerType}
    if($tr.PSObject.Properties.Match('CimClass').Count -and $tr.CimClass){return ($tr.CimClass.CimClassName -replace '^MSFT_Task','')}
    ($tr.PSObject.TypeNames|Select-Object -First 1)
  }

  $tasks = if($TaskPath){
    Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
  }else{
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -eq $TaskName }
  }
  if(-not $tasks){ throw "Task '$TaskName' not found." }

  $out=@()
  foreach($t in $tasks){
    $info=Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue
    $full="$($t.TaskPath)$($t.TaskName)"
    $desc=_TaskDesc $t.TaskName $t.TaskPath

    $acts=@()
    foreach($a in $t.Actions){
      $acts+=[pscustomobject]@{
        Type=$a.ActionType
        Execute=$a.Execute
        Arguments=$a.Arguments
        WorkingDirectory=$a.WorkingDirectory
      }
    }

    $trigs=@()
    foreach($tr in $t.Triggers){
      $rep=$null
      if($tr.PSObject.Properties.Match('Repetition').Count -and $tr.Repetition){
        $rep=[pscustomobject]@{
          Interval=$tr.Repetition.Interval
          Duration=$tr.Repetition.Duration
          StopAtDurationEnd=$tr.Repetition.StopAtDurationEnd
        }
      }
      $sumParts=@()
      if($rep -and $rep.Interval){$sumParts+="Every $(Convert-ISODuration $rep.Interval)"}
      if($tr.StartBoundary){$sumParts+="from $([datetime]$tr.StartBoundary)"}
      if($tr.EndBoundary){$sumParts+="until $([datetime]$tr.EndBoundary)"}
      if($tr.Enabled -ne $null){$sumParts+="enabled: $($tr.Enabled)"}

      $trigs+=[pscustomobject]@{
        Type=_TrigType $tr
        Start=$tr.StartBoundary
        End=$tr.EndBoundary
        Enabled=$tr.Enabled
        Every = $( if($rep -and $rep.Interval){ Convert-ISODuration $rep.Interval } else { $null } )
        Duration = $( if($rep -and $rep.Duration){ Convert-ISODuration $rep.Duration } else { $null } )
        StopAtDurationEnd = $( if($rep){ $rep.StopAtDurationEnd } else { $null } )
        RandomDelay = $( Convert-ISODuration $tr.RandomDelay )
        ExecutionTimeLimit = $( Convert-ISODuration $tr.ExecutionTimeLimit )
        DaysOfWeek=$tr.DaysOfWeek
        DaysOfMonth=$tr.DaysOfMonth
        MonthsOfYear=$tr.MonthsOfYear
        Summary=($sumParts -join ' ')
      }
    }

    [pscustomobject]@{
      PathPlusName=$full
      State=$t.State
      Enabled=($t.State -ne 'Disabled')
      Actions=$acts
      LastTaskResult="$($info.LastTaskResult); $(Convert-TaskResultCode $info.LastTaskResult)"
      Description=$desc
      Author=$t.Author
      RunAcntUserId="$($t.Principal.UserId) $($t.Principal.DisplayName)"
      RunLevel=$t.Principal.RunLevel
      RunLogonType=$t.Principal.LogonType
      LastRunTime=$info.LastRunTime
      NextRunTime=$info.NextRunTime
      NumberOfMissedRuns=$info.NumberOfMissedRuns
      Triggers=$trigs
      Settings=[pscustomobject]@{
        AllowDemandStart=$t.Settings.AllowDemandStart
        StartWhenAvailable=$t.Settings.StartWhenAvailable
        MultipleInstances=$t.Settings.MultipleInstances
        WakeToRun=$t.Settings.WakeToRun
        DisallowStartIfOnBatteries=$t.Settings.DisallowStartIfOnBatteries
        StopIfGoingOnBatteries=$t.Settings.StopIfGoingOnBatteries
        ExecutionTimeLimit=$( Convert-ISODuration $t.Settings.ExecutionTimeLimit )
        Priority=$t.Settings.Priority
      }
    }
  }
}

<#
.SYNOPSIS
  Derives vendor (signer) info and optionally SHA256 hash from an executable.

.DESCRIPTION
  Examines the Authenticode signature of the given executable. Uses internal static
  caches to avoid recomputing vendor or hash data across calls. Treats the specific
  status message
    "A certificate chain processed, but terminated in a root certificate which is not trusted by the trust provider"
  as effectively Valid, because it can occur with legitimate private-CA signatures.

.PARAMETER Exe
  Full path to the executable file to inspect.

.OUTPUTS
  PSCustomObject with properties:
    Vendor     - The derived vendor name or placeholder.
    ExeSHA256  - The SHA256 hash if applicable, otherwise $null.
#>
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

# smart splitter optimized for Win32_Service.PathName
# Uses Win32 argv when it's likely to help; otherwise uses your tolerant Split-FirstToken
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

# --- Resolve-ServiceExecutable Helper:
# Expand %ENVVARS% using documented API (with safe fallback) ---
function Expand-EnvVarsWin32 {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Text)
  $sb = New-Object System.Text.StringBuilder 32768
  $rc = [Win32SvcPath]::ExpandEnvironmentStringsW($Text, $sb, [uint32]$sb.Capacity)
  if ($rc -gt 0 -and $rc -le $sb.Capacity) { $sb.ToString() } else { [Environment]::ExpandEnvironmentVariables($Text) }
}

# --- Resolve-ServiceExecutable Helper:
# Convert "\SystemRoot\..." prefix to an absolute path (common in services/drivers) ---
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

# --- Resolve-ServiceExecutable Helper:
# Strip one layer of surrounding '...' or "..." (if present) ---
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
        Log-notice "Not running HealthTest-RecentBackupsExist because settings file does not exist: $ConfigPath"
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
            Log-Debug "Creating temporary PSDrive $driveName for $rootPath using credentials from $secretsPath"
            New-PSDrive -Name $driveName -PSProvider FileSystem -Root $rootPath -Credential $cred -Scope Global -ErrorAction Stop | Out-Null

            $root = "$driveName`:\"
        } else {
            try {
                $null = Get-ChildItem $root
            } catch {
                Log-Failure "Can't access $root (try adding a username and password to config file $ConfigPath)"
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
            Log-Pass "Found recent Veeam backups. If you want to change the configuration edit: $ConfigPath"
        } else {
            Log-Failure "No recent Veeam backups found at: $rootPath" -comment ("If you want to change the configuration edit: $ConfigPath`n" + `
                "fresh_vbm=$fresh_vbm, fresh_vib=$fresh_vib, fresh_vbk=$fresh_vbk, atleast_one_vbk=$atleast_one_vbk`n" + `
                "Condition for pass is: " + `
                '($fresh_vbm -and ($fresh_vib -or $fresh_vbk) -and $atleast_one_vbk)' + `
                (ls $root|Out-String))
        }
    }
    finally {
        if ($driveName) {
            Log-Debug "Removing PSDrive $driveName"
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

function Get-SchannelProtocolState {
  [CmdletBinding()]
  param(
    [ValidateSet('Server','Client')] [string]$Role='Server',
    [string[]]$Protocol=@('SSL 3.0','TLS 1.0','TLS 1.1','TLS 1.2','TLS 1.3'),
    [switch]$Detailed
  )

  $base='HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols'
  $results=@()

  $v=[Environment]::OSVersion.Version
  $isServer=$env:ProductName -like '*Server*' -or (Get-Item 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').GetValue('InstallationType') -like '*Server*'
  $tls13Supported = ($isServer -and ($v.Major -ge 10 -and $v.Build -ge 20348)) -or ((-not $isServer) -and ($v.Major -ge 10 -and $v.Build -ge 22000))

  function Get-EffectiveState($keyPath){
    $enabled=$null; $disabledByDefault=$null; $src='OS default'; $state='Enabled'
    if(Test-Path $keyPath){
      try{
        $props=Get-ItemProperty -Path $keyPath -ErrorAction Stop
        if($props.PSObject.Properties.Name -contains 'Enabled'){ $enabled=[uint32]$props.Enabled }
        if($props.PSObject.Properties.Name -contains 'DisabledByDefault'){ $disabledByDefault=[uint32]$props.DisabledByDefault }
      }catch{}
    }
    if($enabled -ne $null){
      if($enabled -eq 0){ $state='Disabled'; $src='Enabled=0' } else { $state='Enabled'; $src='Enabled=1/FFFF' }
    } else {
      if($disabledByDefault -ne $null -and $disabledByDefault -eq 1){ $state='Disabled'; $src='DisabledByDefault=1' } else { $state='Enabled'; $src='OS default' }
    }
    ,@($state,$src,$enabled,$disabledByDefault)
  }

  foreach($proto in $Protocol){
    $key=Join-Path (Join-Path $base $proto) $Role
    $eff = Get-EffectiveState $key
    $current=$eff[0]; $source=$eff[1]; $enabledRaw=$eff[2]; $disabledRaw=$eff[3]

    $rec='No requirement'; $note=''
    if($proto -in 'SSL 3.0','TLS 1.0','TLS 1.1'){ $rec='Disabled'; $note='Disable legacy protocols' }
    elseif($proto -eq 'TLS 1.2'){ $rec='Enabled'; $note='Keep TLS 1.2 enabled' }
    elseif($proto -eq 'TLS 1.3'){
      if($tls13Supported){ $rec='Enabled'; $note='OS supports TLS 1.3: enable it' }
      else { $rec='No requirement'; $note='TLS 1.3 not required on this OS' }
    }

    $results += [pscustomobject]@{
      Computer=$env:COMPUTERNAME
      Protocol=$proto
      Role=$Role
      CurrentState=$current
      Source=$source
      RecomendedState=$rec
      Note=$note
      Key=$key
      EnabledRaw=$enabledRaw
      DisabledByDefaultRaw=$disabledRaw
    }
  }

  if($Detailed){ $results }
  else { $results | Select-Object Computer,Protocol,Role,CurrentState,Source,RecomendedState,Note }
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

