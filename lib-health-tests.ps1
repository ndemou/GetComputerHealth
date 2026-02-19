<#
==============================================================
TODO
===================================================

The function HealthTest-SysvolContentConsistency calculates the size and file count of the entire `\\SYSVOL\...\Policies` tree across **all** Domain Controllers over the network. In a production environment with branch offices or many GPOs, this is dangerous. It generates massive WAN traffic. Since Health Tests are already running on every single DC you could in theory compute the hashes localy on each DC (and compute real hashes instead of the pseudo sigs that this function computes) and then exchange and compare them. This will be super fast even over WAN.

==============================================================
TODO 2: Fix suggestions from Gemini
==============================================================

### 3. Issue 3: Minor Logical Errors (`Test-NetConnectionFast` & `TimeSync`)

**The Fix: Enforce IPv4 and Registry-Based Time Checks**

**A. `Test-NetConnectionFast` (DNS ordering bug)**
The original code fetches all IP addresses and arbitrarily picks the first one or filters clumsily. If a host has IPv6 but the network doesn't route it, the test fails even if IPv4 works.

**Modified Logic:**

```powershell
    # Inside Test-NetConnectionFast process block:
    try {
        # Force IPv4 resolution to match your "IPv4 only is acceptable" requirement
        $ips = [System.Net.Dns]::GetHostAddresses($ComputerName) |
               Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
               Select-Object -ExpandProperty IPAddressToString -First 1

        if ($ips) { $remoteAddr = $ips }
        else {
            # Fallback if no IPv4 found
            $remoteAddr = [System.Net.Dns]::GetHostAddresses($ComputerName) | Select -First 1 -Expand IPAddressToString
        }
    } catch {}

```

**B. `HealthTest-TimeSyncPolicy` (Localization bug)**
The check `$currentTimeSource -eq 'Local CMOS Clock'` fails on non-English Windows (e.g., "Lokale CMOS-Uhr").

**Suggestion:** Instead of parsing the localized text output of `w32tm /query /source`, check the **Registry** configuration, which is language-neutral.

**Modified Logic:**

```powershell
    # Replace the text comparison with a check on the configuration type
    $w32Param = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
    $isNt5Ds  = $w32Param.Type -eq 'NT5DS'

    # If it is configured as NT5DS, it is correct for domain members/DCs.
    # We only alert if it is explicitly using the internal clock while NOT being a PDC.
    if (-not $isNt5Ds -and $currentTimeSource -match 'CMOS|LOCL|Free-running') {
        Log-Failure "Time source is set to Local CMOS/Internal Clock"
    }

```

---

### 4. Issue 4: False Positives in Driver Signing

**The Fix: Use AppLocker or Catalog-Aware Classes**

`Win32_PnPSignedDriver` and `Get-AuthenticodeSignature` are unreliable for modern drivers because they often look for an embedded signature in the `.sys` file. Many valid Microsoft/Intel/Realtek drivers are unsigned binary files whose signature lives in an external `.cat` (Catalog) file.

**Suggestion:** Use the `Get-AppLockerFileInformation` cmdlet (available on most modern Windows versions) to check signatures. It is "Catalog-aware" and will correctly identify a file as signed even if the signature is external.

**Modified Code (`HealthTest-UnsignedDrivers`):**

```powershell
    # Inside the loop where you have the driver path ($sysPath):

    # 1. Try standard Authenticode (fastest)
    $sig = Get-AuthenticodeSignature $sysPath
    if ($sig.Status -eq 'Valid') { continue }

    # 2. If invalid, fallback to AppLocker (slower, but catalog-aware)
    if (Get-Command Get-AppLockerFileInformation -ErrorAction SilentlyContinue) {
        try {
            $appLockerInfo = Get-AppLockerFileInformation -Path $sysPath -ErrorAction Stop
            if ($appLockerInfo.Publisher.PublisherName) {
                # If AppLocker finds a publisher, the system trusts the signature (Catalog or Embedded)
                Log-Notice "Driver validated via Catalog (AppLocker): $($d.DeviceName)"
                continue
            }
        } catch {
            # AppLocker failed to read it, likely actually unsigned or unreadable
        }
    }

    # 3. If both fail, flag it
    $bad = $true
    Log-Failure "Unsigned Driver detected: $sysPath"

```

==============================================================
TODO: Consider if the following health tests are useful
==============================================================

# GPT inspired. I'm not sure of whether it's OK
# Run it and in about half the servers it complained it found "no backup signals"
# .SYNOPSIS Looks for recent backup-related events and highlights failures or missing success signals.
function HealthTest-BackupSignals {
    param(
        [int]$WarnHours = 24,
        [int]$FailHours = 48
    )

    if ($WarnHours -lt 1) { $WarnHours = 1 }
    if ($FailHours -lt $WarnHours) { $FailHours = $WarnHours }

    $failCutoff  = (Get-Date).AddHours(-$FailHours)
    $warnCutoff  = (Get-Date).AddHours(-$WarnHours)

    $events = Get-WinEvent -FilterHashtable @{
            LogName   = 'Application'
            StartTime = $failCutoff
        } -ErrorAction SilentlyContinue

    $events = @($events)
    $backupEvents = @(
        $events | Where-Object {
            $_.ProviderName -match 'VSS|Microsoft\-Windows\-Backup|Windows Server Backup|MSSQLSERVER|VMMS|Veeam|Acronis|DPM'
        }
    )

    if ($backupEvents.Count -eq 0) {
        Log-Warning "No recognizable backup-related events in last $FailHours h"
        return
    }

    $fail = @($backupEvents | Where-Object { $_.LevelDisplayName -match 'Error|Critical' })
    if ($fail.Count -gt 0) {
        Log-failure "Backup-related errors present in last $FailHours h"
        return
    }

    $recentOk = @(
        $backupEvents | Where-Object {
            $_.TimeCreated -gt $warnCutoff -and $_.LevelDisplayName -match 'Information'
        }
    )

    if ($recentOk.Count -gt 0) {
        Log-pass "Backup signals present within last $WarnHours h"
        return
    }

    Log-Warning "No clear successful backup signals within last $WarnHours h (but older backup activity exists)"
}

# GPT inspired. I'm not sure of whether it's OK
# Verify BitLocker recovery objects for specific computer exists in AD
function Test-BitLockerRecoveryInAD($computerName){
  $cn="$($computerName)$"
  $comp=Get-ADComputer -Identity $cn -ErrorAction SilentlyContinue
  if(-not $comp){ Log-pass "Computer account not found in AD (skipping BitLocker recovery check)"; return }
  $ri=Get-ADObject -SearchBase $comp.DistinguishedName -LDAPFilter '(objectClass=msFVE-RecoveryInformation)' -SearchScope OneLevel
  if(($ri | Measure-Object).Count -gt 0){ Log-pass ("BitLocker recovery objects present for this computer ($($ri.Count))") } else { Log-failure "No BitLocker recovery objects found for this computer in AD" }
}


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

############################################################
############################################################
###                                                      ###
###    Helpers for HealthTest- functions                 ###
###                                                      ###
############################################################
############################################################

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


function Test-ResolveServiceExecutable {
<#
.SYNOPSIS
  Runs a test suite for Resolve-ServiceExecutable
.OUTPUTS
  Boolean - Returns $true if ALL tests pass, otherwise $false.
#>
  $return = $true
 
  echo "Testing Resolve-ServiceExecutable"
  Get-CimInstance Win32_Service | Select-Object Name,PathName,DisplayName | %{ 
	$pn=$_.PathName
	$sn=$_.name
	$result=Resolve-ServiceExecutable $pn $sn; 
	if ($null -eq $result -or $null -eq $result.payloadpath -or (-not (test-path $result.payloadpath))) {
		echo ""
		echo "Resolve-ServiceExecutable failed to return payloadpath"
		echo "PathOrName  = ``$pn``"
		echo "ServiceName = ``$sn``"
		Resolve-ServiceExecutable $pn $sn -Verbose
		$return = $false
	} 
  }

 return $return
}

function Test-ResolveExecutablePath {
<#
.SYNOPSIS
  Runs a test suite for Resolve-ExecutablePath.
.OUTPUTS
  Boolean - Returns $true if ALL tests pass, otherwise $false.
#>
  [CmdletBinding()]
  param()

try{
	  Write-Host "Starting Test Suite for Resolve-ExecutablePath..." -ForegroundColor Cyan
	  Write-Host "------------------------------------------------" -ForegroundColor Gray

	  $guid = [Guid]::NewGuid().ToString()
	  $rawTempPath = Join-Path $env:TEMP "ResolveExeTest_$guid"
	  $dirItem = New-Item -ItemType Directory -Path $rawTempPath -Force
	  $tempRoot = $dirItem.FullName

	  $subDir = Join-Path $tempRoot "SubFolder"
	  New-Item -ItemType Directory -Path $subDir -Force | Out-Null

	  $filesToCreate = @(
		"rootTool.exe",
		"script.bat",
		"space tool.exe",
		"SubFolder\deep.com",
		"tool[1].exe"
	  )
	  foreach ($file in $filesToCreate) {
		$fullPath = Join-Path $tempRoot $file
		New-Item -ItemType File -Path $fullPath -Force | Out-Null
	  }

	  $originalLocation = Get-Location
	  $originalPath = $env:PATH
	  $env:PATH = "$tempRoot;$env:PATH"

	  $hasNotepad = Test-Path -LiteralPath (Join-Path $env:WINDIR "System32\notepad.exe") -PathType Leaf
	  $hasNetsh   = Test-Path -LiteralPath (Join-Path $env:WINDIR "System32\netsh.exe")   -PathType Leaf

	  $testCases = @(
		# --- Quote handling (both types) ---
		@{
		  Name="Quotes: Double Quotes + Env"
		  Input="`"%WINDIR%\System32\notepad.exe`""
		  Expected= if($hasNotepad){ (Get-Item -LiteralPath (Join-Path $env:WINDIR "System32\notepad.exe")).FullName } else { $null }
		  WorkDir=$tempRoot
		},
		@{
		  Name="Quotes: Single Quotes + Env"
		  Input="'%WINDIR%\System32\notepad.exe'"
		  Expected= if($hasNotepad){ (Get-Item -LiteralPath (Join-Path $env:WINDIR "System32\notepad.exe")).FullName } else { $null }
		  WorkDir=$tempRoot
		},

		# --- Absolute path, exact match ---
		@{
		  Name="Absolute: Exact Match"
		  Input=(Join-Path $tempRoot "rootTool.exe")
		  Expected=(Join-Path $tempRoot "rootTool.exe")
		  WorkDir=$tempRoot
		},

		# --- Absolute path missing extension: probes PATHEXT (+ ensures .exe) ---
		@{
		  Name="Absolute: Missing Extension (.exe probe)"
		  Input=(Join-Path $tempRoot "rootTool")
		  Expected=(Join-Path $tempRoot "rootTool.exe")
		  WorkDir=$tempRoot
		},
		@{
		  Name="Absolute: Missing Extension (.bat probe)"
		  Input=(Join-Path $tempRoot "script")
		  Expected=(Join-Path $tempRoot "script.bat")
		  WorkDir=$tempRoot
		},

		# --- Bare command name via PATH (Application only) ---
		@{
		  Name="PATH: Command Search (rootTool)"
		  Input="rootTool"
		  Expected=(Join-Path $tempRoot "rootTool.exe")
		  WorkDir=$env:USERPROFILE
		},
		@{
		  Name="PATH: Command with Spaces"
		  Input="space tool"
		  Expected=(Join-Path $tempRoot "space tool.exe")
		  WorkDir=$env:USERPROFILE
		},

		# --- System32/Sysnative fallback (can succeed even if System32 is NOT in PATH) ---
		@{
		  Name="System32/Sysnative fallback: netsh (works even if System32 removed from PATH)"
		  Input="netsh"
		  Expected= if($hasNetsh){ (Get-Item -LiteralPath (Join-Path $env:WINDIR "System32\netsh.exe")).FullName } else { $null }
		  WorkDir=$env:USERPROFILE
		  Before={
			$script:SavedPathForNetshTest = $env:PATH
			$env:PATH = ($env:PATH -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -notin @((Join-Path $env:WINDIR "System32"), (Join-Path $env:WINDIR "Sysnative")) }) -join ';'
		  }
		  After={
			$env:PATH = $script:SavedPathForNetshTest
			Remove-Variable SavedPathForNetshTest -Scope Script -ErrorAction SilentlyContinue
		  }
		},

		# --- Wildcards are LITERAL (no expansion); should resolve literal filename tool[1].exe ---
		@{
		  Name="Wildcards literal: tool[1].exe exact absolute"
		  Input=(Join-Path $tempRoot "tool[1].exe")
		  Expected=(Join-Path $tempRoot "tool[1].exe")
		  WorkDir=$tempRoot
		},
		@{
		  Name="Wildcards literal: tool[1] (absolute, missing ext -> .exe probe)"
		  Input=(Join-Path $tempRoot "tool[1]")
		  Expected=(Join-Path $tempRoot "tool[1].exe")
		  WorkDir=$tempRoot
		},
		@{
		  Name="Wildcards literal: tool*.exe should NOT expand (typically null)"
		  Input=(Join-Path $tempRoot "tool*.exe")
		  Expected=$null
		  WorkDir=$tempRoot
		},

		# --- Illegal path characters in path-like inputs => $null (no throw) ---
		@{
		  Name="Illegal chars: rooted path returns null"
		  Input="C:\Bad|Name\tool.exe"
		  Expected=$null
		  WorkDir=$tempRoot
		},
		@{
		  Name="Illegal chars: relative path returns null"
		  Input=".\Bad|Name\tool.exe"
		  Expected=$null
		  WorkDir=$tempRoot
		},

		# --- Failure ---
		@{
		  Name="Failure: Non-existent command"
		  Input="ghost_file_xyz"
		  Expected=$null
		  WorkDir=$tempRoot
		}
	  )

	  $passed = 0
	  $failed = 0

	  foreach ($t in $testCases) {
		if ($t.Before) { & $t.Before }
		try {
		  Set-Location $t.WorkDir
		  $result = Resolve-ExecutablePath $t.Input
		} catch {
		  $result = "__THREW__ $($_.Exception.GetType().FullName): $($_.Exception.Message)"
		} finally {
		  if ($t.After) { & $t.After }
		}

		$status="FAIL"; $color="Red"
		$exp = $t.Expected

		$ok = $false
		if ($result -eq $exp) { $ok = $true }
		elseif ($result -ne $null -and $exp -ne $null) {
		  try { if ($result.ToString().ToLowerInvariant() -eq $exp.ToString().ToLowerInvariant()) { $ok = $true } } catch {}
		}

		if ($ok) { $status="PASS"; $color="Green"; $passed++ } else { $failed++ }

		Write-Host "[$status] $($t.Name) ``$($t.Input)``" -ForegroundColor $color
		if ($status -eq "FAIL") {
		  Write-Host "      Input:    $($t.Input)"
		  Write-Host "      Expected: $exp"
		  Write-Host "      Got:      $result"
		}
	  }

	  Set-Location $originalLocation
	  $env:PATH = $originalPath

	  try { Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { Write-Warning "Could not fully delete temp dir: $tempRoot" }

	  Write-Host "------------------------------------------------" -ForegroundColor Gray
	  if ($failed -gt 0) { Write-Host "Summary: $passed Passed, $failed Failed." -ForegroundColor Red; return $false }
	  Write-Host "Summary: $passed Passed, $failed Failed." -ForegroundColor Green
  } finally{
    try{ Set-Location $originalLocation } catch {}
    $env:PATH=$originalPath
    if($tempRoot){ try{ Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
  }  
  return $true
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


# helper
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

# --- helper: smart splitter optimized for Win32_Service.PathName
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


############################################################
############################################################
###                                                      ###
###    HealthTest- functions                             ###
###                                                      ###
############################################################
############################################################

<#
.SYNOPSIS
Checks NTLM hardening and emits an advisory when the default (3) is in effect.

.DESCRIPTION
- If LmCompatibilityLevel is missing, Windows defaults to 3 (acceptable, not hardened).
- Best practice: LmCompatibilityLevel=5 and NoLMHash=1.
- Returns Pass=$true only when Level>=5 and NoLMHash=1; otherwise Pass=$false with a clear State/Recommendation.
#>
function HealthTest-NtlmHardening {
  $lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'

  $bag   = Get-ItemProperty -Path $lsa -ErrorAction SilentlyContinue
  $lmVal = if ($bag -and $bag.PSObject.Properties['LmCompatibilityLevel']) { $bag.PSObject.Properties['LmCompatibilityLevel'].Value } else { $null }
  $noLM  = if ($bag -and $bag.PSObject.Properties['NoLMHash'])           { $bag.PSObject.Properties['NoLMHash'].Value }           else { $null }

  $interpreted = $true
  if ($null -ne $lmVal) { $level = [int]$lmVal; $interpreted = $false } else { $level = 3 }
  $suffix  = if ($interpreted) { ' (default)' } else { '' }
  $details = "LmCompatibilityLevel=$level$suffix; NoLMHash=$noLM"

  if ($noLM -ne 1) {
    Log-Warning "NTLM is not fully hardened (NoLMHash is not 1)" -Comment $details
  } elseif ($level -lt 5) {
    Log-Warning "NTLM is not fully hardened (LmCompatibilityLevel<5)" -Comment $details
  } else {
    Log-pass "NTLM is fully hardened" -Comment $details
  }
}

<#
.SYNOPSIS
Checks RDP hardening (NLA enabled and cert bound). OnlyForDomainServers
#>
function HealthTest-RdpHardening {
  $k = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'

  $bag  = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
  $nla  = if ($bag -and $bag.PSObject.Properties['UserAuthentication'])     { $bag.PSObject.Properties['UserAuthentication'].Value }     else { $null }
  $cert = if ($bag -and $bag.PSObject.Properties['SSLCertificateSHA1Hash']) { $bag.PSObject.Properties['SSLCertificateSHA1Hash'].Value } else { $null }

  $certBound = ($null -ne $cert) -and ($cert.Trim() -ne '')

  $isServer = $false
  try { $isServer = ((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).DomainRole -ge 2) } catch {}

  if ($nla -eq 1 -and $certBound) {
    Log-pass "RDP hardened: NLA enabled and a certificate is bound"
  } else {
    $sev = "Severity: Medium. Risk: Users may click through name-mismatch warnings; increases MITM risk on first-connect or via spoofing." + $(if($isServer){ " On a DC this is sensitive." } else { "" })
    if ($isServer) {
      Log-Warning   "RDP is not hardened (NLA and/or TLS certificate binding missing)" -Comment ("NLA=$nla; CertBound="+($(if($certBound){$true}else{$false}))+"`n$sev")
    } else {
      Log-notice "RDP is not hardened (NLA and/or TLS certificate binding missing)" -Comment ("NLA=$nla; CertBound="+($(if($certBound){$true}else{$false}))+"`n$sev")
    }
  }
}

<#
.SYNOPSIS
Reviews installed roles/features against policy.
#>
function HealthTest-InstalledRolesFeatures {
  [CmdletBinding()]
  param([string[]]$DisallowedRoles = @('Web-Server','DHCP','WDS'))

  $roles = $null
  try { $roles = Get-WindowsFeature -ErrorAction Stop | Where-Object { $_.Installed } }
  catch {
    Log-Debug "Get-WindowsFeature not available on this OS; skipping role/feature check"
    return
  }

  $hit = @($roles | Where-Object { $DisallowedRoles -contains $_.Name })
  if ($hit.Count -gt 0) {
    foreach ($h in $hit) { Log-failure "Unintended role/feature installed: $($h.Name)" }
  } else {
    Log-pass "No unintended roles/features installed"
  }
}


<#
.SYNOPSIS
Ensures KCC created inbound connections for every DC. OnlyForDCs
#>
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
      Log-failure "No inbound replication detected for $($dc.HostName)" -Comment ("PartnerMetadata=" + $metaCount + "; EnabledConnectionObjects=" + $enabledCount + "; NTDS=" + $dc.NTDSSettingsObjectDN)
      continue
    }
    if($metaCount -eq 0 -and $enabledCount -gt 0){
      Log-notice ("Inbound connection objects exist but partner metadata returned none for " + $dc.HostName + ". Recheck with: repadmin /showrepl " + $dc.HostName)
    }
    if($metaCount -gt 0 -and $enabledCount -eq 0){
      Log-notice ("Inbound partners reported by " + $dc.HostName + " but no enabled nTDSConnection objects under NTDS Settings. Possible permission/cache/KCC timing; investigate ISTG/KCC.")
    }
  }
  if(-not $anyFail){ Log-pass "Inbound replication present for all DCs (partner metadata OK, NTDS container cross-check performed)" }
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
.SYNOPSIS
Basic Schannel hardening: SSL3/TLS1.0 disabled, TLS1.2 enabled. OnlyForDomainServers
.NOTES
What it means if it fails: The DC hasn't explicitly disabled legacy SSL/TLS (SSL 3.0, TLS 1.0/1.1). LDAP over TLS, WinRM, ADWS, and other Schannel consumers will accept older protocol handshakes if the OS still allows them.
Risk: Protocol downgrade/MITM exposure and weaker cipher use; compliance findings are common. On a DC this touches LDAP over TLS and anything else that negotiates via Schannel.
Severity: High.
#>
function HealthTest-SchanelBaseline{
  $base='HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols'
  function Get-EffState($proto,$role){
    $key=(Join-Path (Join-Path $base $proto) $role)
    $enabled=$null; $disabledByDefault=$null; $src='OS default'; $state='Enabled'
    if(Test-Path $key){
      try{
        $p=Get-ItemProperty -Path $key -ErrorAction Stop
        if($p.PSObject.Properties.Name -contains 'Enabled'){ $enabled=[uint32]$p.Enabled }
        if($p.PSObject.Properties.Name -contains 'DisabledByDefault'){ $disabledByDefault=[uint32]$p.DisabledByDefault }
      }catch{}
    }
    if($enabled -ne $null){
      if($enabled -eq 0){ $state='Disabled'; $src='Enabled=0' } else { $state='Enabled'; $src='Enabled=1/FFFF' }
    } else {
      if($disabledByDefault -ne $null -and $disabledByDefault -eq 1){ $state='Disabled'; $src='DisabledByDefault=1' } else { $state='Enabled'; $src='OS default' }
    }
    [pscustomobject]@{ Protocol=$proto; Role=$role; CurrentState=$state; Source=$src; EnabledRaw=$enabled; DisabledByDefaultRaw=$disabledByDefault; Key=$key }
  }

  $items=@()
  $items += Get-EffState 'SSL 3.0' 'Server'
  $items += Get-EffState 'TLS 1.0' 'Server'
  $items += Get-EffState 'TLS 1.1' 'Server'
  $items += Get-EffState 'TLS 1.2' 'Server'

  $should=@{
    'SSL 3.0'='Disabled'
    'TLS 1.0'='Disabled'
    'TLS 1.1'='Disabled'
    'TLS 1.2'='Enabled'
  }

  $bad=@()
  foreach($it in $items){
    $want=$should[$it.Protocol]
    if($it.CurrentState -ne $want){ $bad += $it }
  }

  $det=""
  foreach($it in $items){
    $e=$it.EnabledRaw; if($null -eq $e){ $e='<absent>' }
    $d=$it.DisabledByDefaultRaw; if($null -eq $d){ $d='<absent>' }
    $det += "    {0}\Server: Current={1}; Source={2}; Enabled={3}; DisabledByDefault={4}`n" -f $it.Protocol,$it.CurrentState,$it.Source,$e,$d
  }

  if($bad.Count -eq 0){
    Log-pass ("Schannel baseline OK (SSL3/TLS1.0/TLS1.1 disabled, TLS1.2 enabled)")
  } else {
    $why="LDAP over TLS, WinRM, ADWS, and other Schannel consumers may negotiate legacy handshakes/ciphers if enabled."
    Log-failure "Schannel baseline not hardened" -Comment ("Detected mismatches:`n"+($bad | ForEach-Object { "  - {0}: Current={1}, Recommended={2}" -f $_.Protocol,$_.CurrentState,$should[$_.Protocol] } | Out-String) + "`nRegistry snapshot:`n"+$det+$why)
  }
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
Connectivity health check for all Domain Controllers.

.DESCRIPTION
Builds the DC list (Get-DomainControllers), then for each DC:
1) Validates DNS resolution;
2) Tests core TCP ports (53, 389, 636, 88, 135, 9389) via Test-NetConnectionFast;
3) Verifies presence in _ldap._tcp.dc._msdcs SRV set.
Emits Log-pass/Log-Failure messages for each check and returns $true only if all DCs pass.

.NOTES
Intended for quick, firewall/DNS sanity validation; not a substitute for deep AD diagnostics.
#>
function HealthTest-ConnectivityToDCs {

  $dcs  = Get-DomainControllers

  foreach ($s in $dcs) {
    $fqdn = $s.ToLower()
    # 1) DNS resolution
    try {
      [System.Net.Dns]::GetHostAddresses($fqdn) | Out-Null
      Log-pass "DNS resolved for $fqdn"
    } catch {
      Log-failure "DNS resolution failed for $fqdn" -comment "Check forward/reverse lookup zones and _msdcs records. Command: nslookup $fqdn"
      continue
    }

    # 2) Core ports
    $ports =  @(
      @{Port=53;  Proto='TCP'; Name='DNS'},
      @{Port=389; Proto='TCP'; Name='LDAP'},
      @{Port=636; Proto='TCP'; Name='LDAPS'},
      @{Port=88;  Proto='TCP'; Name='Kerberos'},
      @{Port=135; Proto='TCP'; Name='RPC endpoint mapper'},
      @{Port=9389;Proto='TCP'; Name='AD Web Services'}
    )
    foreach ($p in $ports) {
      $res = Test-NetConnectionFast -ComputerName $fqdn -Port $p.Port -WarningAction SilentlyContinue
      if ($res.TcpTestSucceeded) {
        Log-pass "$($p.Name) port open on $fqdn"
      } else {
        Log-failure "TCP port $($p.Port)($($p.Name)) unreachable on $fqdn" -comment "Port $($p.Port)/$($p.Proto) blocked or service down. Check firewall and service status."
      }
    }

    # 3) SRV records check for LDAP
    $domainName=(Get-CimInstance Win32_ComputerSystem).Domain
    try {
      $srv = Resolve-DnsName -Type SRV "_ldap._tcp.dc._msdcs.$domainName" -ErrorAction Stop
      if ($srv.Name -contains $fqdn) {
        Log-pass "SRV record present for $fqdn"
      } else {
        Log-failure "Missing SRV record for $fqdn" -comment "DC not registered in _ldap._tcp.dc._msdcs. Run ipconfig /registerdns on $fqdn."
      }
    } catch {
      Log-failure "Could not query SRV records." -comment "Check DNS service and replication for zone _msdcs.$((Get-ADForest).RootDomain)."
    }
  }
}

<#
.SYNOPSIS
Cross-checks AD "view" consistency across DCs (DC list and all FSMO holders).

.DESCRIPTION
Queries each specified DC (or discovers DCs) using the AD PowerShell module and collects:
- The full DC list seen from that server
- FSMO role holders (PDC, RID, Infrastructure, Schema, Domain Naming)
Compares each server's view against a baseline DC; emits Log-pass/Log-Failure messages and
returns $true only if all DCs agree on the DC list and all FSMO role holders.

.PARAMETER Servers
Optional set of DC/DNS hostnames to query. If omitted, uses Get-ADDomainController -Filter *.

.OUTPUTS
[bool] $true when all views match; otherwise $false. Also emits diagnostic messages.

.EXAMPLE
HealthTest-ADViewConsistency
Discovers DCs and validates DC list and FSMO role agreement.

.EXAMPLE
HealthTest-ADViewConsistency -Servers @('dc01.contoso.com','dc02.contoso.com')
Restricts the check to the given DCs.

.NOTES
Requires RSAT ActiveDirectory module. Uses Log-pass/Log-Failure helpers.
#>
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
    Log-failure "ActiveDirectory module not available." -comment "Install RSAT AD PowerShell tools. On a DC it's built-in; on a Domain member use Add-WindowsFeature RSAT-AD-PowerShell (Server) or RSAT package (Client)."
    return
  }

  if (-not $Servers -or $Servers.Count -eq 0) {
    try { $Servers = Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName }
    catch {
      Log-failure "Unable to discover domain controllers." -comment "Try on a domain-joined host with AD PowerShell and DNS working. Command used: Get-ADDomainController -Filter *"
    return
    }
  }

  $Servers = Normalize-Names $Servers
  if ($Servers.Count -eq 0) {
    Log-failure "No domain controllers to query." -comment "Pass -Servers @('dc01.contoso.com','dc02.contoso.com') or run on a domain-joined host with AD tools."
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
      Log-failure ("Cannot query DC '{0}'." -f $s) -comment ("The server didn't answer AD queries (-Server {0}). Check network/DNS, ADWS service and firewall. Try: Test-NetConnection {0} -Port 389; Get-Service ADWS -ComputerName {0}; repadmin /showrepl {0}" -f $s)
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
      Log-failure ("DC list mismatch on '{0}'." -f $v.Server) -comment ("Baseline '{0}' sees DCs: [{1}] ; '{2}' sees: [{3}]. Likely replication or DNS SRV inconsistency. Run: repadmin /replsummary ; check _msdcs.{4} SRV records under _ldap._tcp.dc._msdcs and AD-integrated DNS." -f $baseline.Server, $baseDCsJoined, $v.Server, $dcJoin, $domainName)
      $ok = $false
    }

    # 2) FSMO holders equality
    if ($v.PDC -ne $baseline.PDC) {
      Log-failure ("PDC emulator disagreement on '{0}'." -f $v.Server) -comment ("Baseline: {0} ; {1} thinks: {2}. If a role transfer occurred, verify replication. Check: (Get-ADDomain -Server {1}).PDCEmulator; run repadmin /showrepl {1} and GPMC target DC." -f $baseline.PDC, $v.Server, $v.PDC)
      $ok = $false
    }
    if ($v.RID -ne $baseline.RID) {
      Log-failure ("RID Master disagreement on '{0}'." -f $v.Server) -comment ("Baseline: {0} ; {1} thinks: {2}. If long-standing, DCs may fail to create new SIDs when pools deplete. Check: (Get-ADDomain -Server {1}).RIDMaster; repadmin /showrepl {1}." -f $baseline.RID, $v.Server, $v.RID)
      $ok = $false
    }
    if ($v.Infra -ne $baseline.Infra) {
      Log-failure ("Infrastructure Master disagreement on '{0}'." -f $v.Server) -comment ("Baseline: {0} ; {1} thinks: {2}. In multi-domain forests this can cause stale cross-domain group memberships. Check: (Get-ADDomain -Server {1}).InfrastructureMaster; repadmin /showrepl {1}." -f $baseline.Infra, $v.Server, $v.Infra)
      $ok = $false
    }
    if ($v.Schema -ne $baseline.Schema) {
      Log-failure ("Schema Master disagreement on '{0}'." -f $v.Server) -comment ("Baseline: {0} ; {1} thinks: {2}. Schema updates should be halted until replication converges. Check: (Get-ADForest -Server {1}).SchemaMaster; repadmin /showrepl {1}." -f $baseline.Schema, $v.Server, $v.Schema)
      $ok = $false
    }
    if ($v.DNM -ne $baseline.DNM) {
      Log-failure ("Domain Naming Master disagreement on '{0}'." -f $v.Server) -comment ("Baseline: {0} ; {1} thinks: {2}. Avoid adding/removing domains until resolved. Check: (Get-ADForest -Server {1}).DomainNamingMaster; repadmin /showrepl {1}." -f $baseline.DNM, $v.Server, $v.DNM)
      $ok = $false
    }
  }

  if ($ok) {
    Log-pass "All DCs agree on DC list and FSMO role holders." -comment ("Baseline DC: {0} ; DCs: [{1}]. Cross-check is order- and case-insensitive." -f $baseline.Server, $baseDCsJoined)
  }
}

<#
.SYNOPSIS
Validates DFS Replication (DFSR) state across replicated folders.

.DESCRIPTION
Reads DFSR folder state from root\MicrosoftDFS:DfsrReplicatedFolderInfo and ensures all
replicated folders report state 4 (Normal). Warns for transitional states (1-3) and fails
for errors (5). Returns $true only if all are Normal.

.OUTPUTS
[bool] $true if all folders are Normal; otherwise $false. Emits messages with state details.

.EXAMPLE
HealthTest-DfsReplicationState
Reports whether DFSR is healthy and converged.

.NOTES
Requires DFS Replication role installed and permissions to query WMI/CIM on the host.
#>
function HealthTest-DfsReplicationState {
  $stateNames = @{0='Uninitialized';1='Initialized';2='Initial_Sync';3='Auto_Recovery';4='Normal';5='Error'}

  $repl = Get-CimInstance -Namespace 'root\MicrosoftDFS' -ClassName 'DfsrReplicatedFolderInfo' -ErrorAction SilentlyContinue |
          Select-Object ReplicatedFolderName, ReplicationGroupName, state

  if (-not $repl) {
    Log-failure "Could not query DFSR state (class root\MicrosoftDFS:DfsrReplicatedFolderInfo not found or no data)." -comment "Is DFS Replication installed and running? Do you have permissions?"
    return
  }

  $notNormal = $repl | Where-Object { $_.state -ne 4 }

  foreach ($r in $notNormal) {
    $name = $stateNames[$r.state]; if (-not $name) { $name = 'Unknown' }
    if ($r.state -in 1,2,3) {
      Log-Warning ("DFSR replication for '{0}' is at state {1} ({2}) instead of 4 (Normal)" -f $r.ReplicatedFolderName, $r.state, $name)
    } else {
      Log-failure ("DFSR replication for '{0}' is at state {1} ({2}) instead of 4 (Normal)" -f $r.ReplicatedFolderName, $r.state, $name) `
        -comment ("Group: {0}. States: 0 Uninitialized, 1 Initialized, 2 Initial_Sync, 3 Auto_Recovery, 4 Normal, 5 Error." -f $r.ReplicationGroupName)
    }
  }

  if (-not $notNormal) {
    Log-pass "All DFSR replications are at state 4 (Normal)"
  }
}

<#
.SYNOPSIS
Runs key repadmin health checks and flags replication issues.

.DESCRIPTION
Executes:
1) repadmin /replsum -- ensures all "fails" counters are 0 per DSA
2) repadmin /showreps -- ensures each "Last attempt" was successful
Emits Log-pass/Log-Warning/Log-Failure and returns $true only if both checks are clean.

.OUTPUTS
[bool] $true if both checks pass; otherwise $false, with per-issue messages.

.EXAMPLE
HealthTest-ADReplication
Quick replication summary suitable for automation or CI-style health probes.

.NOTES
Relies on repadmin.exe availability and AD connectivity.
#>
function HealthTest-ADReplication {
  $ok = $true

  $repadminCmd = Get-Command repadmin.exe -ErrorAction SilentlyContinue
  if ($repadminCmd) { $repadmin = $repadminCmd.Source } else { $repadmin = "$env:windir\system32\repadmin.exe" }
  if (-not (Test-Path $repadmin)) {
    Log-failure "repadmin.exe not found."
  }

  # --- Test 1: repadmin /replsum -> ensure all 'fails' are 0
  $sumOut = & $repadmin /replsum 2>&1 | Out-String
  if (-not $sumOut) {
    Log-failure "No output from 'repadmin /replsum'."
    $ok = $false
  } else {
    $bad = @()
    $lines = $sumOut -split '\r?\n'
    foreach ($ln in $lines) {
      if ($ln -match '^\s*(?<DSA>\S+)\s+(?<Delta>(?:\d+d:)?(?:\d+h:)?\d+m:\d+s|\d+s)\s+(?<Fails>\d+)\s*/\s*(?<Total>\d+)\b') {
        $dsa = $Matches.DSA; $fails = [int]$Matches.Fails; $total = [int]$Matches.Total
        if ($fails -gt 0) { $bad += [pscustomobject]@{ DSA=$dsa; Fails=$fails; Total=$total } }
      }
    }
    if ($bad.Count -gt 0) {
      foreach ($b in $bad) {
        Log-failure "Replication failures found on '$($b.DSA)'" -comment ("repadmin /replsum shows {0} fail(s) out of {1} total neighbors for this DSA." -f $b.Fails,$b.Total)
      }
      $ok = $false
    } else {
      Log-pass "repadmin /replsum: all DSAs report 0 fails."
    }
  }

  # --- Test 2: repadmin /showreps -> all latest attempts 'was successful.'
  $showOut = & $repadmin /showreps 2>&1 | Out-String
  if (-not $showOut) {
    Log-failure "No output from 'repadmin /showreps'."
    $ok = $false
  } else {
    $attemptLines = ($showOut -split '\r?\n') | Where-Object { $_ -match 'Last attempt @' }
    if (-not $attemptLines -or $attemptLines.Count -eq 0) {
      Log-Warning "repadmin /showreps: no 'Last attempt' lines found." -comment "Execute 'repadmin /showreps' manually and diagnose."
    } else {
      $notOk = $attemptLines | Where-Object { $_ -notmatch 'was successful\.$' }
      if ($notOk.Count -gt 0) {
        foreach ($ln in $notOk) {
          Log-Warning "repadmin /showreps: Found unsuccessful replication attempt" -comment ($ln.Trim())
        }
        $ok = $false
      } else {
        Log-pass "repadmin /showreps: all last attempts were successful."
      }
    }
  }
}

<#
.SYNOPSIS
Smoke-tests DFSDIAG /TestDCs output for unexpected lines.

.DESCRIPTION
Runs DFSDIAG /TestDCs and filters out empty lines and expected boilerplate.
If any remaining lines exist, flags a failure and surfaces the unexpected lines.

.OUTPUTS
[bool] $true when output is clean; otherwise $false, with Log-Failure.

.EXAMPLE
HealthTest-DfsDiagTestDCs
Fast sanity test for DFS Namespace/DC consistency via DFSDIAG.
#>
function HealthTest-DfsDiagTestDCs {
    write-progress "Runing 'DFSDIAG /TestDCs'"
    $out=(DFSDIAG /TestDCs | sls -NotMatch '^$|^(Information|[A-Za-z]+ing|Success)[ :]|^Finished TestDcs[.] *$')
    if ($out) {
        Log-failure "'DFSDIAG /TestDCs' output does not seem clean" -Comment "If the following lines I was not expecting indicate problems, run DFSDIAG /TestDCs to view the whole output:`n$out"
        return
    }
    Log-pass "'DFSDIAG /TestDCs' returned expected output"
}

<#
.SYNOPSIS
Runs DCDIAG (/c /v) and reports any failing tests; classifies basic vs extra tests.

.DESCRIPTION
Calls Get-DcDiagFailures -Comprehensive to capture failures from DCDIAG /c /v.
If failures are found, Calls Get-DcDiagFailures without -Comprehensive
to distinguish beteween , reruns a plain /v parse to determine if the failure is in the basic set
or only in the comprehensive (/c) set, and emits an appropriate message.
Returns $false if any failure exists, otherwise $true.

.OUTPUTS
[bool] $true if no failures are found; otherwise $false with detailed guidance.

.EXAMPLE
HealthTest-Dcdiag
Surface actionable failures and where to re-run for details (/v vs /c /v).

.NOTES
Depends on Get-DcDiagFailures helper.
#>
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
                Log-notice "'DCDIAG /v' reports a failure in this basic test that examines the event log: $testName" `
                    -Comment "Since this test fails when warnings/errors appear in the event log, false positives are likely.`nRun DCDIAG /v, search for '$testName' and examine the detailed report above it.`nBelow are lines from that report that contain words like error/fail:`n$interesting_lines"
            } else {
                Log-failure "'DCDIAG /v' reports a failure in this basic test: $testName" `
                    -Comment "Run DCDIAG /v, search for '$testName' and examine the detailed report above it.`nBelow are lines from that report that contain words like error/fail:`n$interesting_lines"
            }
          } else {
            Log-Warning "'DCDIAG /c /v' reports a failure in this extra test: $testName" `
                -Comment "Run DCDIAG /c /v (do include the /c to run extra tests), search for '$testName' and examine the detailed report above it.`nBelow are lines from that report that contain words like error/fail:`n$interesting_lines"
          }
      }
      return
    }
  Log-pass "DCDIAG /c reports no failures."
}

<#
.SYNOPSIS
Checks that this domain controller is not using public DNS forwarders.

.DESCRIPTION
Domain controllers should normally use only internal DNS servers (other DCs in the forest)
or no forwarders at all (falling back to root hints) to resolve external names.

Using public DNS servers (like 8.8.8.8 or 1.1.1.1) as forwarders is considered unhealthy because:
- They are not domain-joined Windows servers, so `dcdiag` and other tools will try to contact them
  using RPC/DCOM/WMI and generate spurious DCOM 10028 errors.
- They cannot resolve internal AD DNS zones and might cause intermittent name resolution failures.
- They bypass your AD-integrated DNS topology and logging, reducing visibility and security.

This function queries the DNS forwarders configured on the local DNS Server role.
If any configured forwarder is outside the private RFC1918 ranges (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16),
it emits Log-Failure and returns $false. Otherwise it emits Log-pass and returns $true.

.OUTPUTS
[bool] $true if no public DNS forwarders are found, otherwise $false.

.EXAMPLE
HealthTest-DcDnsServerForwarder
#>
function HealthTest-DcDnsServerForwarder {
  [CmdletBinding()]
  [OutputType([bool])]
  param()

  $forwarders = Get-DnsServerForwarder
  # ($forwarders | Format-List * -Force | Out-String).Trim()|write-host -f green
  if(-not $forwarders){
    Log-pass "No DNS forwarders configured"; # return $true
  }
  $ipAddresses = $forwarders | %{$_.ipaddress.tostring()}

  $private = {
    ($_ -like '10.*') -or
    ($_ -like '192.168.*') -or
    ($_ -like '172.1[6-9].*') -or
    ($_ -like '172.2[0-9].*') -or
    ($_ -like '172.3[0-1].*')
  }

  $public = $ipAddresses | Where-Object { -not (& $private $_) }

  if($public){
    Log-Notice "The DNS service on this DC, will forward queries for non-local zones to specific DNS servers" `
        -Comment "This means that these DNS servers (view them with Get-DnsServerForwarder) can inspect and log the domains your domain contact. For extra privacy, you may wish to configure the DNS service to rely on root hints instead of DNS forwarders."
    return
  } else {
    Log-pass "All DNS forwarders are private/internal: $($ipAddresses -join ', ')"
  }
}

function HealthTest-TimeSyncPolicy {
<#
.SYNOPSIS
Validates that the host's time sync topology matches AD/NTP best practices.

.DESCRIPTION
Detects server role via Win32_ComputerSystem.DomainRole:
- PDC Emulator: should sync from an external NTP source (or hypervisor if intentionally configured);
  flags Local CMOS or domain hierarchy sources as failures.
- Other DCs: should sync from domain hierarchy.
- Member servers: should sync from domain hierarchy if domain-joined; otherwise any source is OK.
Also notes if the VMICTimeProvider (hypervisor sync) is enabled on a PDC.

.OUTPUTS
Log-objects regarding findings.

.NOTES
Reads w32tm /query /source and registry VMICTimeProvider; uses Log-pass/Failure/Notice.
#>
    [CmdletBinding()]
    param()

    Write-Verbose "Starting HealthTest-TimeSyncPolicy..."
    $evidences = @()

    # Checks if the provided time source matches a known Domain Controller 
    # (from the provided list)
    # or implies the internal AD hierarchy based on the domain suffix.
    function Is-DCSource([string]$timeSource, [string[]]$dcNameSet, [string]$domainName) {
        if (-not $timeSource) { return $false }
        
        $normalizedSource = $timeSource.Trim().ToLowerInvariant()
        
        # Check if source is an IP address
        if ($normalizedSource -match '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
        
        if ($dcNameSet.Count -gt 0) {
            if ($dcNameSet -contains $normalizedSource) { return $true }
            
            $shortHostName = ($normalizedSource -replace '[.].*')
            if ($dcNameSet -contains $shortHostName) { return $true }
        }

        if ($domainName) {
            $domainNameLower = $domainName.ToLowerInvariant()
            if ($normalizedSource -like "*.$domainNameLower") { return $true }
        }
        
        $false
    }
    
    # Checks if the time source matches common public NTP providers 
    # (Google, Microsoft, NTP Pool)
    # to distinguish them from internal AD sources.
    function Looks-ExternalNtp {
        param(
            [string]$timeSource,
            [string[]]$externalDomains = @('*.pool.ntp.org', '*time.google.com*', '*time.windows.com*')
        )
        if (-not $timeSource) { return $false }
        $sourceLower = $timeSource.ToLowerInvariant()
        foreach ($pattern in $externalDomains) {
            if ($sourceLower -like $pattern.ToLowerInvariant()) {
                return $true
            }
        }
        $false
    }
    
    # --- Helper: Robust DC Validator using DNS SRV ---
    function Get-DnsDomainControllers {
        param($DomainName)
        $names = @()
        try {
            $records = Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$DomainName" -Type SRV -ErrorAction Stop | 
                        Where-Object { $_.Type -eq 'SRV' }
            
            foreach ($rec in $records) {
                if ($rec.NameTarget) {
                    $fqdn = $rec.NameTarget.ToLowerInvariant().TrimEnd('.')
                    $short = ($fqdn -split '\.')[0]
                    $names += $fqdn
                    $names += $short
                }
            }
        }
        catch {
            Write-Verbose "DNS SRV lookup failed: $_"
        }
        return ($names | Select-Object -Unique)
    }
    
    # --- Step 1: Role Detection ---
    $compSystem = Get-CimInstance Win32_ComputerSystem
    $domainRole = $compSystem.DomainRole
    $domainName = $compSystem.Domain
    
    $isHostDC = ($domainRole -in 4, 5)
    $isHostDomainJoined = ($domainRole -in 1, 3, 4, 5)
    $isHostPDC = $false
    $dcNameSet = @()
    
    $msg = "Role Detection: DomainJoined=$isHostDomainJoined, IsDC=$isHostDC (Role ID: $domainRole), Domain=$domainName"
    Write-Verbose $msg
    $evidences += $msg

    if ($isHostDomainJoined -and $domainName) { 
        $dcNameSet = Get-DnsDomainControllers -DomainName $domainName
        $msg = "Found $($dcNameSet.Count) known DC names: $($dcNameSet -join ', ')"
        Write-Verbose $msg
        $evidences += $msg
        
        if ($isHostDC) {
            try { 
                $pdcRecord = Resolve-DnsName -Name "_ldap._tcp.pdc._msdcs.$domainName" -Type SRV -ErrorAction Stop | 
                             Where-Object { $_.Type -eq 'SRV' }
                
                if ($pdcRecord.NameTarget) {
                    $isHostPDC = (($pdcRecord.NameTarget -replace '[.].*') -eq $env:COMPUTERNAME) 
                    $msg = "PDC Detection: IsPDC=$isHostPDC (PDC Record: $($pdcRecord.NameTarget))"
                    Write-Verbose $msg
                    $evidences += $msg
                }
            }
            catch {
                Log-Warning "HealthTest-TimeSyncPolicy: Unable to determine PDC Role via DNS SRV record: $_"
            }
        }
    }

    # --- Step 2: Registry Type ---
    $w32TimeParamsRegistryPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
    $timeSyncType = (Get-ItemProperty $w32TimeParamsRegistryPath -ErrorAction SilentlyContinue).Type
    if (-not $timeSyncType) { $timeSyncType = '' }
    
    $msg = "Registry Configuration: Type='$timeSyncType'"
    Write-Verbose $msg
    $evidences += $msg

    # --- Step 3: Current Source ---
    $currentTimeSource = (w32tm /query /source 2>$null).Trim()
    
    $msg = "Current Time Source: '$currentTimeSource'"
    Write-Verbose $msg
    $evidences += $msg

    # --- Step 4: VMIC Provider ---
    $vmicProviderRegistryPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\VMICTimeProvider'
    $vmicRegistrySettings = Get-ItemProperty -Path $vmicProviderRegistryPath -ErrorAction SilentlyContinue
    $vmicEnabled = ($vmicRegistrySettings -and ($vmicRegistrySettings.Enabled -ne 0) -and ($vmicRegistrySettings.InputProvider -ne 0))

    $isActiveVMIC = ($currentTimeSource -eq 'VM IC Time Synchronization Provider')
    $isActiveCMOS = ($currentTimeSource -eq 'Local CMOS Clock')
    
    $msg = "Provider Status: VMIC_Active=$isActiveVMIC, CMOS_Active=$isActiveCMOS, VMIC_RegEnabled=$vmicEnabled"
    Write-Verbose $msg
    $evidences += $msg

    # --- Step 5: Only for domain joined except PDC: is source a DC? ---
    $isSourceDC = $null
    if ($isHostDomainJoined -and (-not $isHostPDC)) {
      $isSourceDC = (Is-DCSource $currentTimeSource $dcNameSet $domainName)
      if ($isSourceDC) {
        $msg = "$currentTimeSource is a known DC"
      } else {
        $msg = "$currentTimeSource is NOT a known DC"
      }
      Write-Verbose $msg
      $evidences += $msg
    }
    
    # --- Step 6: Logic Evaluation ---

    # Special case for domains
    if ($isSourceDC) {
      # Syncing from myself
      $cleanSource = $currentTimeSource.ToLowerInvariant() -replace '\.$','' # remove trailing dot if any
      if ($cleanSource -match "^$($env:COMPUTERNAME.ToLowerInvariant())(\.|$)") {
          Log-Failure "Misconfiguration: syncing from myself." -comment ($evidences -join "`r`n")
      }
      # Confusion: NTP from a DC
      if ($timeSyncType -eq 'NTP' -and $isSourceDC) {
        $msg = "Confusing setup: a specific DC is manually set as the time source. What if this DC goes down or if another one is better (e.g. on the same LAN)?"
        Write-Verbose $msg
        $evidences += $msg
      } 
    }
    
    $evidenceString = $evidences -join "`r`n"
    if ($isHostPDC) {
        # ---- CHECKS FOR PDCs ---
        if ($timeSyncType -eq 'NT5DS') {
            Log-Failure "PDC time syncing type is NT5DS, this is only valid if this is a subdomain and you are syncing from the higher domain" -comment $evidenceString
        }
        elseif ($timeSyncType -notin 'NTP', 'AllSync') {
            Log-Failure "PDC time syncing type is '$timeSyncType' instead of 'NTP' or 'AllSync'." -comment $evidenceString
        }
        elseif ($isActiveCMOS) {
            Log-Failure "PDC currently reports 'Local CMOS Clock'." -comment $evidenceString
        }
        elseif ($isActiveVMIC) {
            Log-Failure "PDC is currently syncing from hypervisor (Source='$currentTimeSource')." -comment $evidenceString
        }
        else {
            if ($vmicEnabled) {
                if ($isHostPDC) {
                    $comment = "Since this is a PDC consider disabling VM time sync for strict NTP-only behavior."
                }
                else {
                    $comment = ""
                }
                Log-Notice "VMICTimeProvider is enabled, but not used." -comment $comment
            }
            if (Looks-ExternalNtp $currentTimeSource) {
                Log-Pass "PDC emulator time syncing looks correct (Type=$timeSyncType, Source='$currentTimeSource')."
            }
            else {
                Log-Notice "PDC emulator Type=$timeSyncType, Source='$currentTimeSource' (not sure if this is a good external NTP)."
            }
        }
    }
    elseif ($isHostDC) {
        # ---- CHECKS FOR DCs (except PDCs) ---
        if ($timeSyncType -ne 'NT5DS') {
            Log-Failure "DC time syncing type is '$timeSyncType' (expected 'NT5DS')." -comment $evidenceString
        }
        elseif ($isActiveVMIC) {
            Log-Failure "DC is currently syncing from hypervisor (Source='$currentTimeSource')." -comment $evidenceString
        }
        elseif ($isActiveCMOS) {
            Log-Failure "DC reports 'Local CMOS Clock'." -comment $evidenceString
        }
        elseif (Looks-ExternalNtp $currentTimeSource) {
            Log-Failure "DC appears to be using an external NTP source ('$currentTimeSource') instead of domain hierarchy (NT5DS)." -comment $evidenceString
        }
        elseif ($isSourceDC) {
            Log-Pass "DC time syncing is OK (Type=$timeSyncType, Source='$currentTimeSource')." 
        }
        else {
            Log-Failure "DC is not clearly syncing from domain hierarchy (Type=$timeSyncType, Source='$currentTimeSource')." -comment $evidenceString
        }
    }
    elseif ($isHostDomainJoined) {
        # ---- CHECKS FOR Domain Joined servers except DCs, PDCs ---
        if ($timeSyncType -ne 'NT5DS') {
            Log-Failure "Domain member time syncing type is '$timeSyncType' instead of 'NT5DS'." -comment $evidenceString
        }
        elseif ($isActiveVMIC) {
            Log-Failure "Domain member is currently syncing from hypervisor (Source='$currentTimeSource')." -comment $evidenceString
        }
        elseif ($isActiveCMOS) {
            if (Test-IsLaptopOrMobile) {
                Log-Warning "This domain member (likely a laptop) is not syncing time from domain (Source='Local CMOS Clock')."
            }
            else {
                Log-Failure "Domain member is not syncing time from domain (Source='Local CMOS Clock')." -comment $evidenceString
            }
        }
        elseif (Looks-ExternalNtp $currentTimeSource) {
            Log-Failure "Domain member appears to be using an external NTP source ('$currentTimeSource') instead of domain hierarchy." -comment $evidenceString
        }
        elseif ($isSourceDC) {
            Log-Pass "Domain member is syncing via domain hierarchy (Type=$timeSyncType, Source='$currentTimeSource')." 
        }
        else {
            Log-Failure "Domain member is not clearly syncing via domain hierarchy (Type=$timeSyncType, Source='$currentTimeSource')." -comment $evidenceString
        }
    }
    else {
        # ---- CHECKS FOR Standalone PCs ---
        if ($currentTimeSource -eq 'Local CMOS Clock' -or -not $currentTimeSource) {
            Log-Failure "Standalone machine is not syncing time (Source='$currentTimeSource')." -comment $evidenceString
        }
        elseif ($isActiveVMIC) {
            Log-Pass "Standalone machine is syncing via Hypervisor/VM Tools."
        }
        else {
            # Assume anything else is a valid NTP server (IP or DNS name)
            Log-Pass "Standalone machine is syncing from external source '$currentTimeSource'."
        }
    }
}

<#
.SYNOPSIS
Measures time offset vs. a time source and compares against thresholds.

.DESCRIPTION
By default targets the current w32time Source (from w32tm /query /status), unless -AlwaysUseRef
is specified, in which case it targets -RefTimeServer. Uses w32tm /stripchart with 1 sample,
parses the offset in seconds, and evaluates against -WarnOffsetSeconds and -FailOffsetSeconds.

.PARAMETER WarnOffsetSeconds
Warning threshold for absolute offset seconds. Default 2.

.PARAMETER FailOffsetSeconds
Failure threshold for absolute offset seconds. Default 15.

.PARAMETER RefTimeServer
Fallback/explicit NTP server to test when AlwaysUseRef or no usable Source. Default time.windows.com.

.PARAMETER AlwaysUseRef
Force testing against RefTimeServer instead of the current Source.

.EXAMPLE
HealthTest-TimeSyncAccuracy
Uses the current time source and warns/fails on excessive offset.

.EXAMPLE
HealthTest-TimeSyncAccuracy -RefTimeServer 'pool.ntp.org' -AlwaysUseRef -WarnOffsetSeconds 1 -FailOffsetSeconds 5
Tests against a specific NTP pool with stricter thresholds.
#>
function HealthTest-TimeSyncAccuracy {
  param(
    [int]$WarnOffsetSeconds=15,
    [int]$FailOffsetSeconds=30,
    [string]$RefTimeServer='time.windows.com',
    [switch]$AlwaysUseRef
  )

  $source = ''
  try {
    $srcOut = (w32tm /query /source 2>&1) -join "`n"
    if ($LASTEXITCODE -eq 0) {
      $source = ($srcOut -split "`r?`n")[0].Trim()
    }
  } catch {}

  $target = $RefTimeServer
  if (-not $AlwaysUseRef -and $source) {
    $src1 = ($source -split ',',2)[0].Trim()
    $isNonHost = $src1 -match '(?i)(free[-\s]?running|local\s+(cmos|rtc)|vm\s+ic|hyper[-\s]?v|unsynchronized|no\s+source|local\s+clock)'
    $looksIPv4 = $src1 -match '^(?:\d{1,3}\.){3}\d{1,3}$'
    $looksName = $src1 -match '^[A-Za-z0-9][A-Za-z0-9\-\.]*[A-Za-z0-9]$'
    $looksIPv6 = $src1 -match '^[\[\]0-9A-Fa-f:]+$'
    if (($looksIPv4 -or $looksName -or $looksIPv6) -and -not $isNonHost) { $target = $src1 }
  }

  $sc = (w32tm /stripchart /computer:$target /dataonly /samples:2 2>&1) -join "`n"
  $exit = $LASTEXITCODE
  if ($exit -ne 0) {
    $hex = '0x{0:X}' -f ($exit -band 0xFFFFFFFF)
    if ($target -ne $RefTimeServer) {
        Log-notice "Failed to test time sync via $target, retrying with $RefTimeServer" -Comment "Stripchart to $target failed with error $hex"
        # retry
        $sc = (w32tm /stripchart /computer:$RefTimeServer /dataonly /samples:2 2>&1) -join "`n"
        $exit = $LASTEXITCODE
        if ($exit -ne 0) {
          $hex = '0x{0:X}' -f ($exit -band 0xFFFFFFFF)
          Log-Warning "Failed to test time sync either via $target or via $RefTimeServer" -Comment "Stripchart to $RefTimeServer failed with error $hex"
          return
        }
        $target = $RefTimeServer
    } else {
        Log-Warning "Failed to test time sync" -Comment "Stripchart to $target failed with error $hex"
        return
    }
  }

  $m = [regex]::Match($sc,'([-+]?\d+(?:[.,]\d+)?)s')
  if (-not $m.Success) {
    Log-Warning "Failed to test time sync" -Comment "Could not parse offset from stripchart to $target"
    return
  }

  $valStr = $m.Groups[1].Value.Replace(',', '.')
  $offsetSec = [double]::Parse($valStr, [System.Globalization.CultureInfo]::InvariantCulture)
  $abs = [math]::Abs($offsetSec)
  $ok = $true

  if ($abs -ge $FailOffsetSeconds) {
    Log-failure "Time offset too high" -Comment ("{0} s exceeds {1} s (2-samples)" -f $offsetSec,$FailOffsetSeconds)
    $ok = $false
  } elseif ($abs -ge $WarnOffsetSeconds) {
    Log-Warning "Time offset rather high" -Comment ("{0} s exceeds {1} s (2-samples)" -f $offsetSec,$WarnOffsetSeconds)
    $ok = $false
  }

  if ($ok) {
    Log-pass ("Time OK (1-sample); source: {0}; target: {1}; offset: {2} s" -f $source,$target,$offsetSec)
  }
}

<#
.SYNOPSIS
Detects whether a reboot is pending on this host.

.DESCRIPTION
Checks common reboot indicators:
- CBS: HKLM\...\Component Based Servicing\RebootPending
- Windows Update: HKLM\...\WindowsUpdate\Auto Update\RebootRequired
- Pending file rename operations in Session Manager
Emits Log-Notice if a reboot is pending; Log-pass otherwise.

.EXAMPLE
if (-not (HealthTest-PendingReboot)) { 'Schedule a reboot.' }
#>
function HealthTest-PendingReboot {
    $pending = $false
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending = $true }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending = $true }
    $pfr = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
    if ($pfr -and $pfr.PendingFileRenameOperations) {write-debug "Found entries in HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations (if you are not sure what this means, you can safely ignore it)"}
    if ($pending) { Log-notice "Windows need a reboot to apply some changes"; return}
    Log-pass "No pending reboot indicators"
}

<#
.SYNOPSIS
Flags stale Windows Update posture based on last successful install date.

.DESCRIPTION
Determines last successful installation via registry
(HKLM:\...\WindowsUpdate\Auto Update\Results\Install\LastSuccessTime). If unavailable,
falls back to latest HotFix InstalledOn. Compares age in days to Warn/Fail thresholds.

.PARAMETER WarnDays
Warn when last success is >= this many days. Default 30.

.PARAMETER FailDays
Fail when last success is >= this many days. Default 45.

.OUTPUTS
[bool] $true when update age < WarnDays; $false otherwise. Emits messages with the date.

.EXAMPLE
HealthTest-UpdateAge -WarnDays 21 -FailDays 35
#>
function HealthTest-UpdateAge {
    param([int]$WarnDays=30,[int]$FailDays=45)
    $lastUpdateDate = $null
    $reg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Install' -ErrorAction SilentlyContinue
    if ($reg -and $reg.LastSuccessTime) { $lastUpdateDate = [datetime]::Parse($reg.LastSuccessTime) }
    if (-not $lastUpdateDate) {
      $hf = Get-HotFix -ErrorAction SilentlyContinue | ?{$_.InstalledOn} | Sort-Object InstalledOn -Descending | Select-Object -First 1
      if ($hf -and $hf.InstalledOn) { $lastUpdateDate = $hf.InstalledOn }
    }
    if (-not $lastUpdateDate) { Log-Warning "Could not determine last successful Windows Update installation (normal only for a fresh windows installation)"; return}
    $age = (Get-Date) - $lastUpdateDate
    if ($age.Days -ge $FailDays) { Log-failure "Too many days since the last successful Windows Update installation" -Comment "$($age.Days)d ago ($lastUpdateDate)"; return }
    if ($age.Days -ge $WarnDays) { Log-Warning "Several days since the last successful Windows Update installation" -Comment "$($age.Days)d ago ($lastUpdateDate)"; return }
    Log-pass "We have a recent successful installation of a Windows Update ($($age.Days)d ago at $lastUpdateDate)"
}

<#
.SYNOPSIS
Checks Microsoft Defender signature freshness and reports status.

.DESCRIPTION
Reads Get-MpComputerStatus and compares AntispywareSignatureAge and AntivirusSignatureAge
to thresholds. Fails when either age >= FailSigAgeDays; warns when either >= WarnSigAgeDays.
On success, reports current AV signature version.

.PARAMETER WarnSigAgeDays
Warn threshold for signature age (days). Default 1.

.PARAMETER FailSigAgeDays
Fail threshold for signature age (days). Default 7.

.OUTPUTS
[bool] $true if signatures are fresh; $false otherwise. Emits messages.

.EXAMPLE
HealthTest-DefenderStatus -WarnSigAgeDays 2 -FailSigAgeDays 5
#>
function HealthTest-DefenderStatus {
    param([int]$WarnSigAgeDays=2,[int]$FailSigAgeDays=7)
    $s = Get-MpComputerStatus
    $ok = $true
    if ($s.AntispywareSignatureAge -ge $FailSigAgeDays -or $s.AntivirusSignatureAge -ge $FailSigAgeDays) {
      Log-failure "Defender signatures are too old" -Comment "$([math]::Max($s.AntivirusSignatureAge,$s.AntispywareSignatureAge)) days old"
      $ok = $false
    }
    elseif ($s.AntispywareSignatureAge -ge $WarnSigAgeDays -or $s.AntivirusSignatureAge -ge $WarnSigAgeDays) {
      Log-Warning "Defender signatures are rather old" -Comment "AV=$($s.AntivirusSignatureAge)d, AS=$($s.AntispywareSignatureAge)d"
      $ok = $false
    }
    if ($ok) {
      Log-pass "Defender signatures fresh (AV=$($s.AntivirusSignatureVersion))"
    } else {
    }
}

<#
.SYNOPSIS
Alerts on soon-to-expire or expired machine certificates (LocalMachine\My).

.DESCRIPTION
Enumerates certificates under Cert:\LocalMachine\My and compares NotAfter with now.
Emits failures for expired or within -FailDays, warnings within -WarnDays, and success otherwise.

.PARAMETER WarnDays
Warn when expiration is within this many days. Default 60.

.PARAMETER FailDays
Fail when expiration is within this many days. Default 30.

.OUTPUTS
[bool] $true if no certs expire within WarnDays; $false on any warning/failure or errors.

.EXAMPLE
HealthTest-CertExpiry -WarnDays 90 -FailDays 21
#>
function HealthTest-CertExpiry {
    param([int]$WarnDays=60,[int]$FailDays=30)
    $now = Get-Date
    $certs = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue
    $problem_found = $false
    if (-not $certs) { Log-info "No certificates in LocalMachine\My"; return }
    $fail = @(); $warn = @()
    foreach ($c in $certs) {
      $days = ($c.NotAfter - $now).TotalDays
      if ($days -le -60) { $warn += "$($c.Subject) :: expired long time ago $($c.NotAfter)" }
      elseif ($days -le -1) { $fail += "$($c.Subject) :: expired recently $($c.NotAfter)" }
      elseif ($days -eq 0) { $fail += "$($c.Subject) :: expires today $($c.NotAfter)" }
      elseif ($days -le $FailDays) { $fail += "$($c.Subject) :: will expire soon, at $($c.NotAfter)" }
      elseif ($days -le $WarnDays) { $warn += "$($c.Subject) :: will expire within $WarnDays, at $($c.NotAfter)" }
    }
    if ($problem_found) {return}
    Log-pass "No certificates expiring within $WarnDays days"
}

# TODO: consolidate this and HealthTest-ScheduledTasksLastResult
# I think the later seems does more robust detection of issues based on Last Result
<#
.SYNOPSIS
Health check for non-Microsoft scheduled tasks (failures and missed runs).
.DESCRIPTION
Enumerates scheduled tasks excluding Microsoft/Windows built-ins and some noisy patterns. For each
task, flags non-success LastTaskResult values and any NumberOfMissedRuns > 0. Emits Log-Warning
entries with compact task details and returns $false if any problems are found; otherwise reports OK.
.OUTPUTS
[bool] $true if all checked tasks are healthy; $false if any failures/missed runs or on errors.
.EXAMPLE
HealthTest-ScheduledTasks
.NOTES
Uses Convert-TaskResultCode and Get-ScheduledTaskDeepInfo.
#>
function HealthTest-ScheduledTasks {
    $task_name_paterns_to_ignore = @(
      'OneDrive Per-Machine Standalone Update Task*',
      'OneDrive Reporting Task*',
      'OneDrive Standalone Update*',
      'Office Feature Updates*',
      'Firefox Background Update*',
      'Firefox Default Browser Agent*',
      'Office Actions Server*',
      'Clipboard User Service*',
      "Optimize Start Menu Cache Files-*",
      "User_Feed_Synchronization-*"
    )
    $OK_TASK_RESULTS = @(0,267009,267010,267011,267012,267013,267014)

    $problem_found = $false
    $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | ?{$_.TaskPath -notlike "\Microsoft\Windows\*"}

    foreach ($t in $tasks) {
        $skip = $false
        foreach ($p in $task_name_paterns_to_ignore) {
          if ($t.TaskName -like $p) { $skip = $true; break }
        }
        if ($skip) { continue }

        $i = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue
        if ($i -and ($i.LastTaskResult -notin $OK_TASK_RESULTS -or $i.NumberOfMissedRuns -gt 0)) {
            $problem_found = $true
            $details=(Get-ScheduledTaskDeepInfo -TaskName $t.TaskName -TaskPath $t.TaskPath |
              Select-Object state,actions,Description,RunAcntUserId,RunLogonType,LastRunTime,NextRunTime | %{
                $_.PSObject.Properties |
                  Where-Object { $_.Value -ne $null -and "$($_.Value)" -ne '' } |
                    ForEach-Object {
                      if ($_.Name -eq 'actions') {
                        $acts = @($_.Value)
                        foreach($a in $acts){
                          if($null -eq $a){ continue }
                          if($a.PSObject.Properties.Name -contains 'Execute'){
                            "Command: $($a.Execute) $($a.Arguments)"
                          } else {
                            $t = $a.GetType().FullName
                            "Action: $t"
                          }
                        }
                      } else {
                        "{0}: {1}" -f $_.Name, $_.Value
                      }
                    }
              } | out-string)
            if ($i.LastTaskResult -notin $OK_TASK_RESULTS) {
                $meaning = Convert-TaskResultCode $i.LastTaskResult
                Log-Warning "Scheduled Task with failures: '$($t.TaskPath)$($t.TaskName)'; Last exit code: $($i.LastTaskResult) ($meaning)" `
                    -comment "Details about this task:`r`n$details"
            }
            if ($i.NumberOfMissedRuns -gt 0) {
                if ($i.NumberOfMissedRuns -lt 5){
                    if ($t.TaskName -like '*update*' `
                        -or $t.TaskName -like '*Maintenance*' `
                        -or $t.TaskName -in @('Office Serviceability Manager','Resolut Refresh') `
                    ) {
                        Log-info "Scheduled Task with just a few missed runs(<5): '$($t.TaskPath)$($t.TaskName)'" -Comment "$($i.NumberOfMissedRuns) runs where missed. Details about this task: $details"
                    } else {
                        Log-notice "Scheduled Task with just a few missed runs(<5): '$($t.TaskPath)$($t.TaskName)'" -Comment "$($i.NumberOfMissedRuns) runs where missed. Details about this task: $details"
                    }
                } else {
                    Log-Warning "Scheduled Task with missed runs: '$($t.TaskPath)$($t.TaskName)'" -Comment "$($i.NumberOfMissedRuns) runs where missed. Details about this task: $details"
                }
            }
        }
    }
    if ($problem_found) { return }

    Log-pass "Scheduled tasks healthy (non-Microsoft)"
}


<#
.SYNOPSIS
Evaluates scheduled task "Last Result" codes on the local host, suppressing informational values, and reports only meaningful warnings and failures.

.DESCRIPTION
Queries all scheduled tasks on the local computer via SCHTASKS /V, normalizes
and interprets Last Result codes (including HRESULTs and bare Win32 values),
suppresses informational and benign results, and emits only actionable warnings
and failures. For each problematic task it outputs a summary message plus a
multiline comment block describing the task and execution details.
#>
function HealthTest-ScheduledTasksLastResult {
  $mapHresult = @{
    0x40010004=@{d='Process terminated externally'}
    0x80070001=@{d='Incorrect function'}
    0x80070002=@{d='File or path not found'}
    0x80070003=@{d='Path not found'}
    0x80070005=@{d='Access denied'}
    0x8007000A=@{d='Invalid environment'}
    0x8007000B=@{d='Bad EXE format / arch mismatch'}
    0x80070070=@{d='Disk full'}
    0x8007052E=@{d='Logon failure (bad username/password)'}
    0x80070533=@{d='Account disabled'}
    0x800705B4=@{d='Operation timed out'}
    0x800706BA=@{d='RPC server unavailable'}
    0x80040121=@{d='Storage access denied'}
    0x80040154=@{d='COM class not registered'}
    0x800401F5=@{d='COM application not found'}
    0x8004130F=@{d='Task engine execution error/timeout'}
    0x80004005=@{d='Unspecified failure'}
    0x80090020=@{d='Cryptographic/DPAPI failure'}
    0xC000006D=@{d='Logon failure'}
    0xC000006A=@{d='Wrong password'}
    0xC0000064=@{d='Unknown user'}
    0xC0000072=@{d='Account disabled'}
    0xC0000234=@{d='Account locked out'}
  }
  $mapWin32Bare = @{
    1056=@{d='Service already running'}
    1326=@{d='Logon failure (bad username/password)'}
    1331=@{d='Account disabled'}
    1909=@{d='Account locked out'}
  }

  function Normalize-Code($v){
    if($null -eq $v){return $null}
    $s="$v".Trim()
    if($s -eq '' -or $s -eq 'N/A'){return $null}
    if($s -match '(?i)^0x([0-9a-f]{1,8})$'){return [int64]([uint32]::Parse($matches[1],[System.Globalization.NumberStyles]::HexNumber))}
    if($s -match '^-?\d+$'){return [int64]$s}
    $null
  }
  function To-UInt32($code){
    try{
      $i64=[int64]$code
      $u64=[uint64]($i64 -band 0xFFFFFFFFFFFFFFFF)
      [uint32]($u64 -band 0x00000000FFFFFFFF)
    }catch{$null}
  }
  function Get-Severity($u32,$isBare){
    if($isBare){return 'Error'}
    if($null -eq $u32){return 'Error'}
    $sev=($u32 -band 0xC0000000)
    if($sev -eq 0x80000000){'Error'}
    elseif($sev -eq 0x40000000){'Warning'}
    elseif($u32 -eq 0){'Success'}
    else{'Success'}
  }

  # Suppress purely informational "Last Result" values entirely
  $benign = [uint32[]](0x00000000,0x10000000,0x40010004) # S_OK, success-severity flag, DBG_TERMINATE_PROCESS
  function Is-Informational($u32,$sev){
    if($null -eq $u32){return $false}
    if($benign -contains $u32){return $true}
    if($sev -eq 'Success'){return $true}
    if($u32 -ge 0x00041300 -and $u32 -le 0x000413FF){return $true} # SCHED_S_* family
    $false
  }

  function Get-RowValue{ param($row,[string[]]$names)
    foreach($n in $names){
      if($row.PSObject.Properties.Name -contains $n){
        $v=$row.$n; if($v){return "$v"}
      }
    }
    $null
  }

  $want = [ordered]@{
    'Task Name'         = @('TaskName','Task Name')
    'Run As User'       = @('Run As User','RunAsUser')
    'Last Run Time'     = @('Last Run Time','LastRunTime')
    'Next Run Time'     = @('Next Run Time','NextRunTime')
    'Status'            = @('Status')
    'Schedule Type'     = @('Schedule Type','ScheduleType')
    'Triggers'          = @('Schedule','Triggers')
    'Task To Run'       = @('Task To Run','TaskToRun','Actions')
    'Start In'          = @('Start In','StartIn')
    'Logon Mode'        = @('Logon Mode','LogonMode')
    'Author'            = @('Author')
    'Last Result (raw)' = @('Last Result','LastResult')
  }

  $passed = $true
  # These conditions:
  #     $_.'Last Result' -notmatch 'Last Result' -and $_.HostName -eq $env:COMPUTERNAME
  # filter-out plenty of invalid lines that schtasks generates
  $tasks = schtasks /query /fo csv /v | ConvertFrom-Csv | Where-Object {
    $_.'Last Result' -ne 0 -and `
    $_.'Last Result' -notmatch 'Last Result' -and $_.HostName -eq $env:COMPUTERNAME
  }

  foreach($t in $tasks){
    $dec = Normalize-Code $t.'Last Result'
    if($null -eq $dec){ continue }
    $u32 = To-UInt32 $dec
    if($null -eq $u32){ continue }

    $isBare = $mapWin32Bare.ContainsKey($u32)
    $sev = Get-Severity $u32 $isBare
    if(Is-Informational $u32 $sev){ continue } # suppress informational results

    $info = if($isBare){ $mapWin32Bare[$u32] } else { $mapHresult[$u32] }
    $desc = if($info){ $info.d } else { 'Unknown failure' }
    $hex  = ('0x{0:X8}' -f $u32)
    $msg  = "Scheduled Task '$($t.TaskName)' terminated with Last Result=$hex('$desc')"

    $lines=@()
    foreach($k in $want.Keys){
      $val = Get-RowValue -row $t -names $want[$k]
      if($val){ $lines += ('{0}: {1}' -f $k,$val) }
    }
    $details = ($lines -join "`r`n")

    if($sev -eq 'Error'){ Log-Failure -Message $msg -Comment $details; $passed = $false }
    elseif($sev -eq 'Warning'){ Log-Warning -Message $msg; $passed = $false }
  }

  if ($passed) {
      Log-pass "HealthTest-ScheduledTasksLastResult found no problem"
  }
}


<#
.SYNOPSIS
    Performs a comprehensive health check of all local physical disks using Windows Storage APIs.

.DESCRIPTION
    HealthTest-Storage examines each physical disk via Get-PhysicalDisk and (where available)
    Get-StorageReliabilityCounter to detect early signs of storage degradation. It evaluates
    parameters such as HealthStatus, temperature, media/uncorrectable errors, and SSD wear
    percentage, returning $true if all drives are within safe limits or $false otherwise.
#>
function HealthTest-Storage {
    [CmdletBinding()]
    param([int]$MaxTemperatureC = 70,[int]$MaxPercentUsed = 95)

    $allHealthy = $true
    $disks = Get-PhysicalDisk -ErrorAction SilentlyContinue
    if (-not $disks) { Log-failure "No disks visible via Get-PhysicalDisk"; return }

    foreach ($d in $disks) {
        # 1) Explicit predictive failure
        $predFail = $false
        if ($d.PSObject.Properties.Name -contains 'OperationalStatus') {
            $os = $d.OperationalStatus
            if ($os -is [array]) { foreach($s in $os){ if ($s -eq 'Predictive Failure') { $predFail=$true; break } } }
            else { if ($os -eq 'Predictive Failure') { $predFail=$true } }
        }
        if ($predFail) {
            Log-failure ("OperationalStatus=Predictive Failure for disk '{0}'" -f $d.FriendlyName)
            $allHealthy = $false
        }

        # 2) HealthStatus
        if ($d.PSObject.Properties.Name -contains 'HealthStatus') {
            if ($d.HealthStatus -ne 'Healthy') {
                Log-failure ("HealthStatus={0} for disk '{1}'" -f $d.HealthStatus,$d.FriendlyName)
                $allHealthy = $false
            }
        }

        # 3) Reliability counters (temp, errors, wear)
        try {
            $c = $d | Get-StorageReliabilityCounter -ErrorAction Stop
            if ($c) {
                if ($c.PSObject.Properties.Name -contains 'Temperature') {
                    if ([double]$c.Temperature -gt $MaxTemperatureC) {
                        Log-failure ("Temperature({0}) exceeds max for disk '{1}'" -f $c.Temperature,$d.FriendlyName)
                        $allHealthy = $false
                    }
                }

                $uncorr = 0
                foreach ($p in 'ReadErrorsUncorrected','WriteErrorsUncorrected','MediaErrors','UncorrectableErrors') {
                    if ($c.PSObject.Properties.Name -contains $p) { $uncorr += [int64]$c.$p }
                }
                if ($uncorr -gt 0) {
                    Log-failure ("Uncorrectable error counter not zero for disk '{0}'" -f $d.FriendlyName)
                    $allHealthy = $false
                }

                $percentUsed = $null; $propName='(UNKNOWN)'
                foreach ($name in 'PercentageUsed','PercentUsed','Wear','WearPercentage','LifeRemaining','PercentLifeRemaining','LifeLeftPercent') {
                    if ($c.PSObject.Properties.Name -contains $name) {
                        $val = [double]$c.$name
                        if ($name -in 'LifeRemaining','PercentLifeRemaining','LifeLeftPercent') { $percentUsed = 100 - $val } else { $percentUsed = $val }
                        $propName = $name; break
                    }
                }
                if ($percentUsed -ne $null -and $percentUsed -ge $MaxPercentUsed) {
                    Log-failure ("{0} >= {1} for disk '{2}'" -f $propName,$MaxPercentUsed,$d.FriendlyName)
                    $allHealthy = $false
                }
            }
        } catch { }
    }

    if ($allHealthy) { Log-pass "HealthTest-Storage passed for all disks" }
}


<#
.SYNOPSIS
Check NTFS volumes for the "dirty" bit.
.DESCRIPTION
Enumerates NTFS volumes via Get-Volume and runs `fsutil dirty query` per drive. If any volumes are
marked dirty, emits Log-Warning listing the drive letters and returns $false; otherwise returns $true.
.OUTPUTS
[bool] $true if no dirty volumes; $false if any volume is dirty or on error.
.EXAMPLE
HealthTest-NtfsDirtyBit
#>
function HealthTest-NtfsDirtyBit {
    $dirty = @()
    $drives = Get-Volume -FileSystem NTFS -ErrorAction SilentlyContinue
    foreach ($d in $drives) {
      $out = (& fsutil dirty query $d.DriveLetter`: 2>$null)
      if ($out -and ($out -match 'is dirty')) { $dirty += $d.DriveLetter }
    }
    if ($dirty.Count -gt 0) { Log-Warning "NTFS dirty bit set on: $($dirty -join ', ')"; return }
    Log-pass "No NTFS dirty volumes"
}

<#
.SYNOPSIS
Sanity-check IIS site bindings for common misconfigurations.
.DESCRIPTION
If IIS cmdlets are available, inspects bindings for each website. Warns/notices on:
- HTTP wildcard bindings on port 80 when multiple sites exist;
- HTTPS bindings lacking a certificate assignment.
Returns $false if any issues found, $true otherwise.
.OUTPUTS
[bool] $true if bindings look sane; $false if issues detected or on errors.
.EXAMPLE
HealthTest-IisBindings
.NOTES
Requires WebAdministration module (Get-Website/Get-WebBinding) when present; otherwise no-op success.
#>
function HealthTest-IisBindings {
    # Skip test on workstations
    # 1 = Workstation 2 = Domain Controller 3 = Windows Server
    $host_type = (Get-CimInstance Win32_OperatingSystem).ProductType
    if ($host_type -eq 1) {
        Log-Debug "ProductType=$host_type; skiping HealthTest-IisBindings"
        return
    }

    $role = Get-WindowsFeature Web-Server -ErrorAction SilentlyContinue

    if (-not($role -and $role.Installed)) {
        Log-info "No IIS installed; skiping HealthTest-IisBindings"
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
            Log-notice "$($s.Name): site serves plain HTTP with wildcard bindings" -comment $comment
            $problem_found = $true
        }
        if ($x.protocol -eq 'https' -and ($x.bindingInformation -like '*:443:*') -and -not $x.certificateHash) {
            Log-Warning "$($s.Name): site is configured for HTTPS, but it has no certificate assigned"
            $problem_found = $true
        }
      }
    }
    if ($problem_found) {return}
    Log-pass "IIS bindings look sane"
}

<#
.SYNOPSIS
Quick AD replication check for this DC using RSAT cmdlets.
.DESCRIPTION
If the host is a Domain Controller and AD RSAT is available, queries
Get-ADReplicationPartnerMetadata for LastReplicationResult across partners. Fails if any partner
reports non-zero result; otherwise reports success. On non-DC hosts, returns $true (skips).
.OUTPUTS
[bool] $true if replication appears healthy for this DC; $false if errors or on query failure.
.EXAMPLE
HealthTest-ADReplication
.NOTES
Distinct from the repadmin-based variant; this version uses AD Web Services/RSAT.
#>
function HealthTest-ADReplication {
  # 0(Workstation standalone),  1(Workstation domain joined), 2(Server standalone), 3(Server joined), 4(DC non-FSMO), 5(DC with FSMO role)
  $domainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole
  $isHostDC = ($domainRole -in 4,5)

  if ($isHostDC) {
        $me = Get-ADDomainController -ErrorAction SilentlyContinue
        if (-not $me -or -not $me.HostName) {
            Log-Debug "Not a Domain Controller; skipping HealthTest-ADReplication."
            return
        }
        if (-not (Get-ADDomain -ErrorAction SilentlyContinue)) { Log-notice "AD RSAT not available or not a DC"; return }
        $md = Get-ADReplicationPartnerMetadata -Target $me.HostName -ErrorAction SilentlyContinue
        $bad = @($md | Where-Object { $_.LastReplicationResult -ne 0 })
        if ($bad.Count -gt 0) {
          $details = $bad | ForEach-Object { "$($_.Partner) rc=$($_.LastReplicationResult) at $($_.LastSuccessfulSync)" }
          Log-failure "AD replication errors: $($details -join ' | ')"; return
        }
        Log-pass "AD replication healthy for $($me.HostName)"; return
  } else {
      return # nothing to do -- not a DC
  }

}

<#
.SYNOPSIS
Flag high DFS-R backlog for a replication group.
.DESCRIPTION
For the given replication group (default 'Domain System Volume'), enumerates DFS-R connections and
retrieves backlog counts per source->destination. Warns when any backlog exceeds 1000 items; returns
$false if any threshold exceeded, $true otherwise.
.PARAMETER RGName
DFSR Replication Group name. Default: 'Domain System Volume'.
.OUTPUTS
[bool] $true when backlog is within limits or cmdlets unavailable; $false if high backlog detected.
.EXAMPLE
HealthTest-DfsrBacklog -RGName 'Domain System Volume'
.NOTES
Requires DFSR PowerShell cmdlets (Get-DfsrConnection/Get-DfsrBacklog) when present.
#>
function HealthTest-DfsrBacklog {
    param([string]$RGName='Domain System Volume')
    if (-not(Get-Service DFSR -ErrorAction SilentlyContinue)) {
        Log-Debug "No DFSR service; skipping HealthTest-DfsrBacklog."
        return
    }
    if (-not (Get-Command Get-DfsrBacklog -ErrorAction SilentlyContinue)) {
        Log-Warning "DFSR cmdlets not available. Can't start the DFSR backlog healthcheck." `
            -comment 'I suggest you install RSAT-DFS-Mgmt-Con:`n        Install-WindowsFeature RSAT-DFS-Mgmt-Con'
        return
    }
    $conn = Get-DfsrConnection -GroupName $RGName -ErrorAction SilentlyContinue
    if (-not $conn) { Log-info "No DFS-R connections found for '$RGName'"; return }
    $over = @()
    foreach ($c in $conn) {
      $b = Get-DfsrBacklog -GroupName $RGName -SourceComputerName $c.SourceComputerName -DestinationComputerName $c.DestinationComputerName -ErrorAction SilentlyContinue
      if ($b -and $b.Count -gt 1000) { $over += "$($c.SourceComputerName)->$($c.DestinationComputerName): $($b.Count)" }
    }
    if ($over.Count -gt 0) { Log-Warning "DFS-R backlog high" -Comment "$($over -join ' | ')"; return }
    Log-pass "DFS-R backlog OK"; return
}

<#
.SYNOPSIS
Snapshot test for low free RAM.
.DESCRIPTION
Samples \Memory\Available MBytes `-Samples` times with `-SampleDelayMs` between samples, computes
the median, then compares to percent-of-total thresholds with absolute minimum floors:
~10% (notice), ~5% (warn), ~2% (failure). Emits Log-pass/Notice/Warn/Failure and returns [bool].
If free RAM is below 10% and only one sample was taken, another one is taken and average is used.
.PARAMETER Samples
Number of samples to take. Default 1. (But see note in description)
.PARAMETER SampleDelayMs
Delay in milliseconds between samples. Default 500.
.OUTPUTS
[bool] $true if free RAM is healthy (>= ~10%); $false at warn/failure levels.
.EXAMPLE
HealthTest-RamPressure -Samples 5 -SampleDelayMs 250
#>
function HealthTest-RamPressure {
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [ValidateRange(1,2147483647)][int]$Samples=1,
    [ValidateRange(0,3600000)][int]$SampleDelayMs=500
  )

  $os = Get-CimInstance Win32_OperatingSystem
  $totalMB = [math]::Round($os.TotalVisibleMemorySize/1024,1)
  if ($totalMB -le 0) { Log-Failure "Total visible memory is 0 MB; cannot compute free %."; return }

  function Get-AvailMB {
    try {
      $c = (Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples.CookedValue
      if ($null -eq $c) { throw "No counter value." }
      [math]::Round([double]$c,1)
    } catch { return $null }
  }

  $vals = @()
  for ($i=0; $i -lt $Samples; $i++) {
    $v = Get-AvailMB
    if ($null -eq $v) { Log-Warning "Skipped a failed \\Memory\\Available MBytes read (sample $($i+1)/$Samples)."; continue }
    $vals += $v
    if (($i+1) -lt $Samples -and $SampleDelayMs) { Write-Verbose "waiting $SampleDelayMs ms"; Start-Sleep -Milliseconds $SampleDelayMs }
  }
  if ($vals.Count -eq 0) { Log-Failure "Failed to sample available memory."; return }

  $sorted = @($vals | Sort-Object)
  $n = $sorted.Length
  $mid = [int]($n/2)
  $medianFree = if ($n % 2) { [double]$sorted[$mid] } else { ([double]$sorted[$mid-1] + [double]$sorted[$mid]) / 2 }
  $freePcnt = [math]::Round(($medianFree*100)/$totalMB,1)

  if ($Samples -eq 1 -and $freePcnt -lt 10) {
    if ($SampleDelayMs) { Start-Sleep -Milliseconds $SampleDelayMs }
    $v = Get-AvailMB
    if ($null -ne $v) {
      $medianFree = [math]::Round((([double]$medianFree + [double]$v)/2),1)
      $freePcnt = [math]::Round(($medianFree*100)/$totalMB,1)
    }
  }

  if ($freePcnt -lt 2) { Log-failure "Free RAM under 2%" -comment "$freePcnt% free RAM"; return }
  elseif ($freePcnt -lt 5) { Log-Warning "Free RAM between 2 and 5%" -comment "$freePcnt% free RAM"; return }
  elseif ($freePcnt -lt 10) { Log-notice "Free RAM between 5 and 10%" -comment "$freePcnt% free RAM"; return }
  Log-pass "Free RAM at $($freePcnt)%"
  return
}

<#
.SYNOPSIS
Baseline check for key Windows Exploit Protection (system) mitigations.
.DESCRIPTION
Reads Get-ProcessMitigation -System and verifies core mitigations:
DEP enabled, ASLR force-relocate, and SEHOP. Emits notices for missing items and returns $false if
any are off; $true only when all are enabled or cmdlets unavailable (soft pass).
.OUTPUTS
[bool] $true if mitigations meet baseline; $false if any are missing or on errors.
.EXAMPLE
HealthTest-ExploitProtectionBaseline
.NOTES
Requires Windows 10/Server 2016+ with Exploit Protection cmdlets.
#>
function HealthTest-ExploitProtectionBaseline {
    if (-not (Get-Command Get-ProcessMitigation -ErrorAction SilentlyContinue)) { Log-notice "Exploit Protection cmdlets unavailable"; return }
    $sys = Get-ProcessMitigation -System -ErrorAction SilentlyContinue
    if (-not $sys) { Log-Warning "Could not read system process mitigations"; return }
    $ok = $true
    if (-not $sys.Dep.Enable) { Log-notice "Exploit Protection; DEP not enforced system-wide"; $ok = $false }
    if (-not $sys.ASLR.EnableForceRelocateImages) { Log-notice "Exploit Protection; ASLR not enforcing force-relocate"; $ok = $false }
    if (-not $sys.SEHOP.Enable) { Log-notice "Exploit Protection; SEHOP not enabled"; $ok = $false }
    if ($ok) { Log-pass "Exploit Protection key mitigations enabled"; return } else { return }
}

<#
.SYNOPSIS
    Audits SMB shares for broad access and hygiene issues.

.DESCRIPTION
    The HealthTest-ShareReasonableness function enumerates all SMB shares on the local host
    (excluding admin/system shares unless -IncludeAdminShares is used), inspects
    both share-level and NTFS-level permissions, and reports potential security
    or configuration issues.

    It focuses on "broad access" principals (Everyone, Authenticated Users, Domain Users, etc.)
    and determines whether they have effective Read/Write/Full access by intersecting
    share and NTFS permissions. It highlights risky conditions and hygiene issues such as:
      - Broad write or read access by many users
      - Orphaned share permissions blocked by NTFS (suggesting cleanup)
      - Presence of Null session shares
      - SMB1 enabled
      - SMB signing not required on DCs

    The function outputs status via Log-pass, Log-Warning, Log-Failure, and Log-Notice
    to integrate cleanly into your health check framework, and returns $true if no high-risk
    issues are found, otherwise $false.

.PARAMETER BroadPrincipals
    An array of account or group names considered "broad access".
    Defaults to: Everyone, Authenticated Users, Domain Users, Users, Guests.

.PARAMETER IncludeAdminShares
    If specified, also checks admin/system shares (C$, ADMIN$, IPC$, SYSVOL, NETLOGON).

.OUTPUTS
    [bool] - $true if no risk findings were found, $false otherwise.

.EXAMPLE
    HealthTest-ShareReasonableness

    Runs the check on all non-admin SMB shares on the local machine.

.EXAMPLE
    HealthTest-ShareReasonableness -IncludeAdminShares

    Runs the check on all shares including admin/system ones.

.NOTES
    This function requires the SMB Share and CIM modules to be available.
    It is compatible with PowerShell 5.1 and PowerShell 7+.

.LINK
    https://learn.microsoft.com/powershell/module/smbshare/get-smbshare
.LINK
    https://learn.microsoft.com/powershell/module/smbshare/get-smbshareaccess
.LINK
    https://learn.microsoft.com/powershell/module/smbshare/revoke-smbshareaccess
.LINK
    https://learn.microsoft.com/powershell/module/microsoft.powershell.security/get-acl
.LINK
    https://learn.microsoft.com/powershell/module/cimcmdlets/get-ciminstance
#>
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
      Log-pass "Skipping HealthTest-ShareReasonableness; LanmanServer service not running."
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
    if(-not (Test-Path $path)){ Log-Warning "Share '$($s.Name)' points to missing path '$path'"; $riskFound = $true; continue }

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
        Log-Info "Accounts for share '$($s.Name)' (Path: $path)"
        Log-Info ("    Share-level : {0}" -f ($(if($sharePrincipals){ $sharePrincipals -join ', ' } else { '<none>' })))
        Log-Info ("    NTFS-level  : {0}" -f ($(if($ntfsPrincipals){ $ntfsPrincipals -join ', ' } else { '<none>' })))
        Log-Info ("    Effective(*) : {0}" -f ($(if($effectivePrincipals){ $effectivePrincipals -join ', ' } else { '<none>' })))
        Log-Info "    (*) Effective here means present on both lists; this is a coarse check without group nesting resolution."
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
      Log-pass ("Share '{0}' has no broad-principal read or write access; ABE={1}; EncryptData={2}" -f $s.Name,$s.FolderEnumerationMode,$s.EncryptData)
    } else {
      foreach($r in $report){
        if($r.Effective -eq 'Full' -or $r.Effective -eq 'Write'){
          Log-Failure ("'{1}' can write share '{0}'('$path')" -f $r.Share,$r.Principal) -Comment ("Restrict to specific groups; ensure share grants Read or None to broad principals and tighten NTFS. Path: {0}" -f $r.Path)
          $riskFound = $true
        } elseif($r.Effective -eq 'Read') {
            if ($r.Share -ne 'SYSVOL'){
                Log-Warning ("'$($r.Principal)' can read share '$($r.Share)'('$path')")
            }
        } else {
          Log-pass ("No effective access for {0} on '{1}' (blocked by layer intersection)" -f $r.Principal,$r.Share)
        }
      }
      # Log-Info ("ABE={0}; EncryptData={1}; Caching={2}" -f $s.FolderEnumerationMode,$s.EncryptData,$s.CachingMode)
    }

    # Hygiene extras
    # if($s.FolderEnumerationMode -ne 'AccessBased'){ Log-Warning ("Enable Access-Based Enumeration on '{0}' if multi-tenant" -f $s.Name) }
    # if(-not $s.EncryptData){ Log-Warning ("Consider SMB encryption on '{0}' for sensitive data" -f $s.Name) }
    # if($s.CachingMode -ne 'None'){ Log-Warning ("Offline caching is {0} on '{1}' - assess if appropriate" -f $s.CachingMode,$s.Name) }
  }

  # Global checks
  #--------------------------
  $srv = Get-SmbServerConfiguration
  if($srv.EnableSMB1Protocol){
    Log-Warning "SMB1 is enabled; disable unless really needed" -comment "You can disable it by running: Set-SmbServerConfiguration -EnableSMB1Protocol `$false"
  }
  if($srv.RequireSecuritySignature -eq $false){
    if ($isHostDC) {
      Log-Warning "SMB signing not required and this is a DC. It is recomended to enable" -comment "You can enable it by running: Set-SmbServerConfiguration -RequireSecuritySignature `$true"
    } else {
      Log-Info "SMB signing not required; You may want to consider enabling it. It helps avoid sophisticated internal data integrity attacks."
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
    Log-Failure "Null session shares configured: $($nullShares -join ', ')" -Comment "Remove unless a documented legacy requirement exists."
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
    Log-notice ("Null session pipes (Named Pipes that can be accessed anonymously) found: {0}" -f ($nullPipes -join ', ')) -Comment "Anonymous users are allowed to open those pipes. Modern domains don't need null pipes and they increase attack surface if other policies are loose. If you don't have legacy (pre-Windows 2000-era) trusts/clients, it's recommended to keep Null session pipes empty. Change Local Security Policy > Security Options > 'Network access: Named Pipes that can be accessed anonymously' (set to None), or the equivalent GPO."
  }

  if (!$riskFound) {Log-pass "No risks related to SMB shares were detected"}
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
        $shares_beside_the_system_ones | %{Log-Warning  "Found a share named '$($_.name)' that shares '$($_.Path)'"}
    } else {
        if ((Get-Service  -Name "LanmanServer").status -eq 'Stopped') {
            Log-pass "No shares except the defaults and LanMan service is stopped."
        } else {
            Log-pass "Found no shares except the default ones (like C$, ADMIN$)."
            if (!$isHostDC -and ($lanManServer_service.status -ne 'stopped' -or $lanManServer_service.StartType -ne 'Disabled')) {
                if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 2) { # server
                    Log-Warning "File & print sharing is enabled. It's recomended to disable it unless you really need it" -comment "Run this if you want to disable:`n   Set-Service -Name 'LanmanServer' -StartupType Disabled; Stop-Service -Name 'LanmanServer'"
                } else { # workstation
                    Log-Debug "File & print sharing is enabled on a workstation." `
                        -comment "You may consider disabling it to reduce the attack surface"
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
                    Log-info "This service is stoped but its last execution terminated NORMALY and it's one of the services that are often stopped: Service '$($_.Name)', StartMode=$($_.StartMode), DelayedAutoStart=$($_.DelayedAutoStart), last ExitCode=$($_.ExitCode)($exitCodeMeaning)."
            } else {
                if ($_.ExitCode  -in (0,1077)) {
                    Log-Notice "Service '$($_.Name)' which is set to automatically start is not running; calmingly its last execution terminated normally: ExitCode=$($_.ExitCode)($exitCodeMeaning)." `
                        -Comment "Display name: $($_.DisplayName), StartMode=$($_.StartMode), DelayedAutoStart=$($_.DelayedAutoStart), last ExitCode=$($_.ExitCode)($exitCodeMeaning)."
                } else {
                    Log-Failure "Service '$($_.Name)' which is set to automatically start is not running; alarmingly its last execution terminated abnormally: ExitCode=$($_.ExitCode)($exitCodeMeaning)." `
                        -Comment "Display name: $($_.DisplayName), StartMode=$($_.StartMode), DelayedAutoStart=$($_.DelayedAutoStart), last ExitCode=$($_.ExitCode)($exitCodeMeaning)."
                }
            }
        }
    } else {
        Log-pass "All services that are set to automatically start are running"
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
      Log-pass "Host supports legacy Greek (ACP/OEMCP 1253/737)."
    }elseif($loc_acp -eq 1252 -and $loc_oemcp -eq 437){
      Log-notice "This host uses default English/ANSI (1252/437), so legacy Greek apps may fail."
    }else{
      Log-Warning "Unusual non-Unicode locale: $loc_acp / $loc_oemcp (ACP/OEMCP). Greek is 1253/737; Default english is 1252/437."
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
            Log-failure "This local account has the property PasswordRequired set to false: $account_name" `
                -comment "Make sure the account password is set and then run this command:`n& cmd /c 'net user `"$($_.name)`" /passwordreq:yes'"
        }
    }
    if ($ok) {Log-pass "All local accounts have PasswordRequired True"}
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
            Log-failure "Disk is critically low on free space" -Comment "$out"
        } elseif ($out.level -eq 'Warning') {
            Log-Warning "Disk is low on free space" -Comment "$out"
        } else {
            Log-pass "Disk has enough free space" -Comment "$out"
        }
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
            Log-Warning "Either something's wrong with service '$($_.ServiceName)' or there's a bug in Get-ServiceVendors." -Comment $_.ExceptionsThrown
        } else {
            if ($isHostServer -or ($_.Vendor -notin $COMMON_VENDORS_FOR_WORKSTATIONS)) {
                Log-Warning "Found service that is not a core Microsoft service: Vendor='$($_.Vendor)' Name='$TrimmdServiceName'$extra_msg" `
                    -Comment ("Admin must verify if service is legit and needed. Service Description: '$($_.DisplayName)'`n" `
                    + "Executable: '$($_.ExePath)'.")
            } else {
                Log-notice "Found service that is not a core Microsoft service: Vendor='$($_.Vendor)' Name='$TrimmdServiceName'$extra_msg" `
                    -Comment ("It is however from a common vendor. Admin must verify if service is legit and needed. Service Description: '$($_.DisplayName)'`n" `
                    + "Executable: '$($_.ExePath)'.")
            }
        }
    }
    if ($ok) {Log-Pass 'Found no service except Microsoft ones'}
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
        Log-failure "VM $($_.name) should be running but is not"
        $ok=$false
    }
    if ($all_vm |?{$_.AutomaticStartAction -eq 'Start'}) {
        if ($ok) {Log-Pass 'All VMs that are set to always auto-start are running'}
    } else {
        Log-info 'No VM is set to always auto-start'
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
                Log-Warning "VM $($vm.Name) has $prop_name='$actual_value' instead of '$expected_value'."
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
        Log-pass "Did windows defender perform a quick scan recently?" -comment $comment
    } elseif ($days -lt $MAX_FAILURE_DAYS) {
        Log-warning "Did windows defender perform a quick scan recently?" -comment $comment
    } else {
        Log-failure "Did windows defender perform a quick scan recently?" -comment $comment
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
      if (!$ok1) {Log-failure "'\\$dc\SYSVOL' not reachable"}
      $ok2 = Test-Path "\\$dc\NETLOGON"
      if (!$ok1) {Log-failure "'\\$dc\NETLOGON' not reachable"}
      if(-not($ok1 -and $ok2)){ $bad += $dc.HostName }
    }
    $pass = ($bad.Count -eq 0)
    if($pass){Log-pass "All DCs have reachable SYSVOL & NETLOGON"}
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
        $msg="$($dc.HostName): objectVersion missing"; $errs+=$msg; Log-failure $msg; continue
      }
      $ov=[int]("$ov".Trim()); $vers[$dc.HostName]=$ov
    }catch{
      $msg="$($dc.HostName): $($_.Exception.Message)"; $errs+=$msg; Log-failure $msg
    }
  }

  if($vers.Count -eq 0){
    Log-failure "AD schema version consistency" -Comment ("No schema versions retrieved. Errors: "+($errs -join ' | '))
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
    Log-pass "AD schema version consistent across DCs ($det)"
  } else {
    Log-failure "AD schema version consistent across DCs" -Comment $det
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
  if(-not $dbOk){ Log-failure "NTDS database path not on an expected volume" -Comment "DB=$db; Expected roots: $($ExpectedDbRoots -join ', ')" }

  $lgOk = if($ExpectedLogRoots -and $ExpectedLogRoots.Count){
    ($ExpectedLogRoots | Where-Object { $lg -like "$_*" -or ([IO.Path]::GetPathRoot($lg) -eq $_) }).Count -gt 0
  } else { $true }
  if(-not $lgOk){ Log-failure "NTDS log path not on an expected volume" -Comment "LOGS=$lg; Expected roots: $($ExpectedLogRoots -join ', ')" }

  if($dbOk -and $lgOk){ Log-pass "NTDS database/log paths sane (DB=$db; LOGS=$lg)" }
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
  if($tl -ge $MinDays){ Log-pass "AD tombstoneLifetime is sufficient ($tl days >= $MinDays)" }
  else{ Log-failure "AD tombstoneLifetime below threshold" -Comment "Current=$tl; Min=$MinDays" }
}

<#
.SYNOPSIS
Confirms AD Recycle Bin is enabled.
#>
function HealthTest-RecycleBinEnabled{
  $f=Get-ADOptionalFeature 'Recycle Bin Feature' -ErrorAction Stop
  $enabled=($f.EnabledScopes -ne $null -and $f.EnabledScopes.Count -gt 0)
  if($enabled){ Log-pass "AD Recycle Bin enabled" } else { Log-notice "AD Recycle Bin is not enabled -- consider enabling it." }
}

<#
.SYNOPSIS
Verifies domain trusts and performs netdom /verify.
#>
function HealthTest-TrustsVerify{
  $trusts=Get-ADTrust -Filter * -ErrorAction Stop
  if(-not $trusts){ Log-pass "No inter-domain trusts configured"; return }
  $bad=$false
  foreach($t in $trusts){
    $r=& netdom.exe trust $t.TargetName /domain:$($t.Source) /verify 2>&1
    if($LASTEXITCODE -ne 0){ $bad=$true; Log-failure "Trust verification failed" -Comment "$($t.Source) -> $($t.TargetName): $r" }
  }
  if(-not $bad){ Log-pass "All domain trusts verify successfully" }
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
        if($mins -gt $MaxMinutes){ $anyFail=$true; Log-failure "Replication latency above threshold" -Comment "$($dc.HostName) partition '$p' latency=$mins min (Max=$MaxMinutes)" }
      }
    }
  }
  if(-not $anyFail){ Log-pass "AD replication latency acceptable (<= $MaxMinutes min on schema/config)" }
}

<#
.SYNOPSIS
Validates DNS zone replication scope for AD-integrated zones.
#>
function HealthTest-DnsZoneReplicationScope{
  $zones = Get-DnsServerZone -ErrorAction Stop | Where-Object { $_.IsDsIntegrated }
  if(-not $zones){ Log-pass "No AD-integrated zones present"; return }
  $lines = ($zones | ForEach-Object { "{0}:{1}" -f $_.ZoneName, $_.ReplicationScope })
  Log-pass "DNS zone replication scope reviewed" -Comment ($lines -join '; ')
}

<#
.SYNOPSIS
Confirms required SRV records exist in _msdcs.
#>
function HealthTest-RequiredSrvRecords{
  $dom=(Get-ADDomain).DNSRoot
  $labels=@("_ldap._tcp.dc._msdcs.$dom","_kerberos._tcp.$dom","_kerberos._udp.$dom")
  $missing=$false
  foreach($q in $labels){
    try{ $r=Resolve-DnsName -Type SRV $q -ErrorAction Stop }catch{$r=$null}
    if(-not $r){ $missing=$true; Log-failure "Required SRV record missing" -Comment $q }
  }
  if(-not $missing){ Log-pass "Required AD SRV records present" }
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
  if(-not $sv.ScavengingState){ $flagged=$true; Log-Warning "DNS server scavenging is disabled" -comment $comment }

  foreach($z in $zones){
    $ai = $null; try { $ai = Get-DnsServerZoneAging -Name $z.ZoneName -ErrorAction Stop } catch {}
    if(-not ($ai -and $ai.AgingEnabled)){ $flagged=$true; Log-Warning "DNS zone aging is disabled" -Comment "zone: $($z.ZoneName) `nNote that scavenging must be enabled both at the server level and at the zone`n$comment"}
  }

  if(-not $flagged){
    $on=@($zones | ForEach-Object { $_.ZoneName })
    Log-pass "DNS scavenging configured on server and zones" -Comment ("Zones: " + ($on -join ', '))
  }
}

<#
.SYNOPSIS
Validates DNS forwarders reachability and forbids loopback.
#>
function HealthTest-DnsForwarders{
  $f=Get-DnsServerForwarder -ErrorAction Stop
  if(-not $f -or -not $f.IPAddress){ Log-pass "No DNS forwarders configured"; return }
  $ips=$f.IPAddress
  $bad=$false
  foreach($ip in $ips){
    if(($ip -eq '127.0.0.1') -or ($ip -eq '::1')){ $bad=$true; Log-failure "Loopback address is configured as a DNS forwarder" -Comment $ip; continue }
    $ok=(Test-Connection -ComputerName $ip -Count 1 -Quiet)
    if(-not $ok){ $bad=$true; Log-failure "DNS forwarder not reachable" -Comment $ip }
  }
  if(-not $bad){ Log-pass "DNS forwarders sane & reachable" -Comment ("Forwarders: " + ($ips -join ', ')) }
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
        Log-pass "LDAP signing & channel binding enforced"
    } else {
        Log-notice "LDAP signing and/or channel binding not enforced" `
            -Comment "LDAPServerIntegrity=$sign; LdapEnforceChannelBinding=$cb"
    }
}

<#
.SYNOPSIS
Requires SMB signing on the server.
#>
function HealthTest-SmbSigningRequired{
  if ((Get-PropValue -obj (Get-Service -Name LanmanServer) -name Status) -ne 'running') {
      Log-pass "Skipping HealthTest-SmbSigningRequired; LanmanServer service not running."
      return
  }

  $c=Get-SmbServerConfiguration
  if($c.RequireSecuritySignature){
    Log-pass "SMB signing required on the server"
  } else {
    Log-Warning "SMB signing is not required" -Comment "RequireSecuritySignature=$($c.RequireSecuritySignature); EnableSecuritySignature=$($c.EnableSecuritySignature)"
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
  if($disabled){ Log-pass "SMBv1 is disabled" } else { Log-Warning "SMBv1 is enabled" -Comment "State=$state" }
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

      Log-failure "Unconstrained delegation account found" -Comment "$($cls): $name"
    }

  } else {
    Log-pass "No unconstrained delegation accounts"
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
    foreach($u in $bad){ Log-failure "Service account password set to never expire" -Comment $u.SamAccountName }
  } else {
    Log-pass "Service accounts have expiring passwords"
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
    Log-pass "Anonymous access hardening (baseline met)" -Comment $details
  } else {
    Log-failure "Anonymous access hardening not at baseline" -Comment "$details. Recommendation: Set RestrictAnonymousSAM=1 and EveryoneIncludesAnonymous=0 via GPO."
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
    Log-failure "No pagefile detected" -Comment ("AutomaticManagedPagefile="+[int]$auto)
    return
  }

  $sumAlloc=($entries | Measure-Object AllocMB -Sum).Sum
  $okSize = ($sumAlloc -ge $MinMB)
  $okSys  = $true
  if($RequireOnSystemDrive){
    $sys = $env:SystemDrive  # Typically 'C:'
    $okSys = (($entries | Where-Object {$_.Name -like "$sys\*"}).Count -gt 0)
    if(-not $okSys){ Log-failure "No pagefile on system drive" -Comment "SystemDrive=$sys; Entries="+(($entries | ForEach-Object {"$($_.Name):$($_.AllocMB)MB"}) -join ', ') }
  }
  if(-not $okSize){ Log-failure "Total pagefile size below threshold" -Comment "TotalAllocMB=$sumAlloc; MinMB=$MinMB" }

  if($okSize -and $okSys){
    Log-pass "Paging file configured sensibly" -Comment ("Auto="+[int]$auto+"; TotalAllocMB=$sumAlloc; Entries="+(($entries | ForEach-Object {"$($_.Name):$($_.AllocMB)MB"}) -join ', '))
  }
}

<#
.SYNOPSIS
Confirms WinRM is running and responsive.
#>
function HealthTest-WinRMListening{
  $svc=Get-Service WinRM -ErrorAction Stop
  if($svc.Status -ne 'Running'){ Log-failure "WinRM service is not running" -Comment "Status=$($svc.Status)"; return }
  try{ $null=Test-WSMan -ErrorAction Stop; Log-pass "WinRM running and responding" }
  catch{ Log-failure "WinRM not responding" -Comment $_.Exception.Message }
}

<#
.SYNOPSIS
Verifies IPv6 binding state per policy (PS5.1-safe).
#>
function HealthTest-IPv6Binding{
  [CmdletBinding()] param([switch]$RequireEnabled)
  $rows = Get-NetAdapterBinding -ComponentID ms_tcpip6 | Select-Object Name,Enabled
  if(-not $rows){ Log-failure "No adapters returned for IPv6 binding (ms_tcpip6)"; return }
  $bad=$false
  if($RequireEnabled){
    foreach($r in $rows){
      if(-not $r.Enabled){ $bad=$true; Log-failure "IPv6 disabled on adapter" -Comment $r.Name }
    }
    if(-not $bad){ Log-pass "IPv6 enabled on all adapters" }
  } else {
    Log-pass "IPv6 binding state reported" -Comment (($rows | ForEach-Object { "$($_.Name)=$($_.Enabled)" }) -join '; ')
  }
}

<#
.SYNOPSIS
Verifies DNS Client service is running.
#>
function HealthTest-DnsClientService{
  $s=Get-Service Dnscache -ErrorAction Stop
  if($s.Status -eq 'Running'){ Log-pass "DNS Client service running" } else { Log-failure "DNS Client service is not running" -Comment "Status=$($s.Status)" }
}

<#
.SYNOPSIS
Verifies WMI repository consistency.
#>
function HealthTest-WmiRepository{
  $out=& winmgmt /verifyrepository 2>&1
  $ok=($out -match 'consistent')
  if($ok){ Log-pass "WMI repository consistent" } else { Log-failure "WMI repository inconsistent" -Comment ($out -join ' ') }
}

<#
.SYNOPSIS
Lists VSS writers and flags non-stable states.
#>
function HealthTest-VssWriters{
  $out=& vssadmin list writers 2>&1
  $bad=($out | Select-String -Pattern 'State: \d+ \((?i:Retryable error|Waiting for completion|Failed)\)')
  if($bad){
    foreach($b in $bad){ Log-failure "VSS writer not healthy" -Comment $b.Line }
  } else {
    Log-pass "All VSS writers report stable states"
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
      if (-not $present.ContainsKey($k)) { $missing += $k; Log-failure "Shadow storage not configured on required volume" -Comment $k }
    }
    if($missing.Count -eq 0){
      Log-pass "Shadow storage on required volumes" -Comment ("Configured on: " + ((@($present.Keys) | Sort-Object) -join ', '))
    }
  } else {
    if ($present.Count -gt 0) {
      Log-pass "Shadow storage configured" -Comment ("On: " + ((@($present.Keys) | Sort-Object) -join ', '))
    } else {
      Log-notice "Shadow storage (Volume Shadow Copies) is not enabled" -comment `
      "Users won't see Previous Version for files/folders. (Note that this issue is UNRELATED to the VSS service that backup software use.)"
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
    Log-pass "Startup items reviewed" -Comment ($items -join '; ')
  } else {
    Log-pass "No startup items found in standard keys"
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
  if(-not $objs){ Log-pass "No objects with SPN found"; return }

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
      Log-failure "Duplicate SPN detected" -Comment ("$spn -> " + ($owners -join ', '))
    }
  }
  if(-not $dupsFound){ Log-pass "No duplicate SPNs detected" }
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
    Log-Info "Gateway Configuration looks fine - Windows will prefer $($best.InterfaceAlias).$note"
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

    Log-Failure "Multiple Gateways with metrics that may cause routing instability." -comment "$desc`n$hintText"
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
        Log-pass "Default gateways: at most one per IP family"
    } else {
        if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 2) { # server -- always considered a failure
            Log-failure "Multiple default gateways detected per IP family" -Comment "IPv4=$v4; IPv6=$v6; Gateways=$(($nextHops) -join ', ')"
        } else { # workstation
            Test-MultipleGatewayConfiguration
        }
    }
  } else {
    if($nextHops.Count -le 1){
      Log-pass "Default gateways: at most one overall"
    } else {
        if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 2) { # server -- always considered a failure
            Log-failure "Multiple default gateways configured" -Comment "Gateways=$(($nextHops) -join ', ')"
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
    if(-not $ares){ $msg="$hn has no A records in DNS"; $bad+=$msg; Log-failure $msg; continue }
    if($ares -notcontains $ip){ $msg="$hn A record mismatch: AD IP=$ip, DNS IPs="+($ares -join ','); $bad+=$msg; Log-failure $msg }
  }
  if($bad.Count -eq 0){ Log-pass "DC DNS A records match AD IPs for all DCs" }
}

<#
.SYNOPSIS
Validates DNS recursion configuration (enabled/forwarders/EDNS). OnlyForDCs
#>
function HealthTest-DnsRecursionConfig {
    if (-not (Get-Command Get-DnsServerRecursion -ErrorAction SilentlyContinue)) {
        Log-notice "DNS Server tools not available" -Comment "DNS role/RSAT missing?"
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
        Log-pass "No issues found in the DNS recursion configuration" -comment ("EnableRecursion={0}; MaxTTL={1}; EDNS-ECS={2}" `
                    -f $recText, $ttlText, $ecsText)
    } else {
        Log-notice "Unable to read DNS recursion configuration on this host" `
            -Comment "Host is probably not a DNS server"
    }
}


<#
.SYNOPSIS
Confirms reverse lookup zones exist for known subnets. OnlyForDCs
#>
function HealthTest-ReverseZonesPresent{
  [CmdletBinding()] param([string[]]$ExpectedReverseZones)
  $zones=Get-DnsServerZone | Where-Object {$_.IsReverseLookupZone} | Select-Object -ExpandProperty ZoneName
  if(-not $ExpectedReverseZones){ Log-pass ("Reverse zones present: "+(($zones -join ', ')-replace '^$','<none>')); return }
  $missing=@()
  foreach($z in $ExpectedReverseZones){
    if($zones -notcontains $z){ $missing+=$z; Log-failure "Reverse zone missing: $z" }
  }
  if($missing.Count -eq 0){ Log-pass "All expected reverse zones are present" }
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
    if($has){ Log-pass "At least one Global Catalog exists in the domain" } else { Log-failure "No Global Catalog server detected in the domain" }
    return
  }
  $sites=$dcs | Group-Object Site
  $bad=@()
  foreach($s in $sites){
    if(($s.Group | Where-Object {$_.IsGlobalCatalog}).Count -eq 0){ $bad+=$s.Name; Log-failure "No Global Catalog in site '$($s.Name)'" }
  }
  if($bad.Count -eq 0){ Log-pass "Each AD site has at least one Global Catalog" }
}

<#
.SYNOPSIS
Checks AdminSDHolder applied to protected groups reasonably. OnlyForDomainServers
#>
function HealthTest-AdminSDHolderCoverage{
  $prot=Get-ADUser -LDAPFilter '(adminCount=1)' -Properties MemberOf | Select-Object -ExpandProperty SamAccountName
  if($prot){ Log-pass ("AdminSDHolder applied; protected users: "+($prot -join ', ')) } else { Log-pass "No users currently protected by AdminSDHolder" }
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
        if($count -gt $MaxBacklog){ $bad=$true; Log-failure "DFSR backlog above threshold: $dc <- $peer : $count (Max=$MaxBacklog)" }
      }
    }
  }
  if(-not $bad){ Log-pass "DFSR SYSVOL backlog within threshold on all DC pairs" }
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
      Log-notice ("Unsigned device instance treated as benign: {0}{1}{2}" -f $manText,$d.DeviceName,$provText)
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
                  Log-notice ("Benign logical child without INF: {0} (ParentSvc={1}, Signed={2})" -f $d.DeviceName,$svc,$sig.SignerCertificate.Subject)
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
            Log-notice ("Win32 reports unsigned but INF-linked drivers are signed: {0} (INF={1})" -f $d.DeviceName,(Split-Path $infPath -Leaf))
            continue
          }
        }
      }
    }

    $bad=$true
    $ver = if($d.DriverVersion){ $d.DriverVersion } else { '' }
    $man = if($d.Manufacturer){ $d.Manufacturer } else { '' }
    $detail = [string]($d | Select-Object Description,DeviceName,DeviceID,Location,DriverVersion,DriverProviderName,InfName)
    Log-failure ("Unsigned 3rd-party driver detected: {0}{1} ver [{2}]" -f ($(if($man){"$man, "}), $d.DeviceName, $ver)) -comment ("Details: {0}" -f $detail)
  }

  if(-not $bad){ Log-pass "All non-Microsoft PnP drivers appear signed (benign logical/child nodes and whitelisted instances excluded)." }
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
            Log-notice "Optional baseline port is listening: $p ($procDescr)"
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
                Log-Warning "Unexpected listening port: $p (Process: $procDescr, Vendor: $vendor)" -comment $comment
            } else {
                Log-notice "Unexpected listening port: $p (Process: $procDescr, Vendor: $vendor)" -comment $comment
            }
        } else {
            Log-failure "Unexpected listening port: $p (Process: $procDescr, Vendor: $vendor)" -comment $comment
        }
    }

    if (-not $bad) { Log-pass "Listening ports are within baseline" }
}

<#
.SYNOPSIS
Verifies DFS Namespace (domain-based) objects enumerate without error. OnlyForDomainServers
#>
function HealthTest-DfsNamespaceEnumerate{
  $roots=Get-DfsnRoot -ErrorAction SilentlyContinue
  if(-not $roots){ Log-pass "No DFS Namespace roots found (nothing to check)"; return }
  $count=0
  foreach($r in $roots){ $count += (Get-DfsnFolder -Path $r.Path -ErrorAction SilentlyContinue | Measure-Object).Count }
  Log-pass "DFSN roots/folders enumerate: Roots=$($roots.Count); Folders=$count"
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
      if(& $isRequired $path){ Log-failure "Required SYSTEM task is disabled: $path" }
      else { Log-Warning "SYSTEM task is disabled: $path" }
      continue
    }

    # 2) Stale runs (only if triggers exist)
    if($hasEnabledTrigger -and $StaleDays -gt 0){
      if(($lastRun -eq [datetime]::MinValue) -or ((Get-Date) - $lastRun).TotalDays -gt $StaleDays){
        $hadIssue = $true
        Log-Warning "SYSTEM task appears stale: $path ; LastRun=$lastRun (> $StaleDays days or never)"
      }
    }

    # 3) Non-zero last result (optional)
    if($WarnOnNonZeroLastResult -and $info.LastTaskResult -ne 0){
      $hadIssue = $true
      if(& $isRequired $path){ Log-failure "Required SYSTEM task has non-zero LastTaskResult: $path ; Code=$lastRes" }
      else { Log-Warning "SYSTEM task has non-zero LastTaskResult: $path ; Code=$lastRes" }
    }
  }

  if(-not $hadIssue){ Log-pass "All relevant SYSTEM scheduled tasks are enabled and healthy" }
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
    if($wr -and ($id -match 'Everyone|Authenticated Users')){ $bad=$true; Log-failure "SYSVOL ACL too broad: $id has $($ace.FileSystemRights)" }
  }
  if(-not $bad){ Log-pass "SYSVOL does not grant write to broad principals (Everyone/Auth Users)" }
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
        Log-Warning "RC4 permitted for $($o.objectClass): $($o.sAMAccountName)"
        $bad_count += 1
        if ($bad_count -gt 10) {
            Log-Warning "I will not report any more 'RC4 permitted for...' warnings"
            break
        }
    }
  }
  if($bad_count -eq 0){ Log-pass "No accounts permit RC4 in msDS-SupportedEncryptionTypes" }
}

<#
.SYNOPSIS
Ensures DHCP server presence/authorization sane if role installed. OnlyForDomainServers
#>
function HealthTest-DhcpInAd{
  $dhcp=Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
  if(-not $dhcp -or -not $dhcp.Installed){ Log-pass "DHCP role not installed on this server"; return }
  $auth=Get-DhcpServerInDC -ErrorAction SilentlyContinue
  $fqdn=[System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName
  $isAuth=($auth | Where-Object { $_.DnsName -ieq $fqdn })
  if($isAuth){ Log-pass "DHCP server is authorized in AD ($fqdn)" } else { Log-failure "DHCP server is NOT authorized in AD ($fqdn)" }
}

<#
.SYNOPSIS
Flags enabled NICs that are disconnected (cleanup). OnlyForDomainServers
#>
function HealthTest-UnusedEnabledAdapters{
  $nics=Get-NetAdapter | Where-Object {$_.AdminStatus -eq 'Up' -and $_.Status -ne 'Up'}
  foreach($n in $nics){ Log-Warning "Enabled network adapter is disconnected: $($n.Name) ($($n.Status))" }
  if(($nics | Measure-Object).Count -eq 0){ Log-pass "No enabled-but-disconnected network adapters detected" } else { Log-failure "There are enabled-but-disconnected network adapters present" }
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
    if($i.InterfaceMetric -gt $MaxPreferredMetric -and !($i.InterfaceAlias -like "Loopback*")){ $bad=$true; Log-Warning "Interface metric too high: $($i.InterfaceAlias) Metric=$($i.InterfaceMetric) (Max=$MaxPreferredMetric)" }
  }
  if(-not $bad){ Log-pass "All connected interfaces have acceptable metrics (<= $MaxPreferredMetric)" } else { Log-failure "One or more interfaces have metrics above the preferred threshold" }
}

<#
.SYNOPSIS
Detects disabled GPO links at domain root (policy choice). OnlyForDomainServers
#>
function HealthTest-DisabledGpoLinksAtDomainRoot{
  # Preconditions
  if(-not (Get-Command Get-GPO -ErrorAction SilentlyContinue)){
    Log-Warning "GroupPolicy cmdlets not available; install RSAT/GPMC (GroupPolicy module)."
    return
  }

  # Resolve domain DN even if AD module is missing
  $root = $null
  if(Get-Command Get-ADDomain -ErrorAction SilentlyContinue){
    try{ $root = (Get-ADDomain).DistinguishedName }catch{}
  }
  if(-not $root){
    try{
      $dns  = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name
      $root = ($dns -split '\.') | ForEach-Object { "DC=$_" } -join ','
    }catch{
      Log-Warning "Cannot resolve domain root DN (need AD or machine joined to a domain)."
      return
    }
  }

  # Collect links at domain root by parsing GPO reports (no Get-GPLink dependency)
  $links = foreach($g in (Get-GPO -All -ErrorAction Stop)){
    try{
      $xml = [xml](Get-GPOReport -Guid $g.Id -ReportType Xml -ErrorAction Stop)
      foreach($lnk in @($xml.GPO.LinksTo.LinkTo)){
        if($lnk.SOMPath -eq $root){
          [pscustomobject]@{
            DisplayName = $xml.GPO.Name
            Enabled     = if($lnk.Enabled    -eq 'true'){ 1 } else { 0 }
            Enforced    = if($lnk.NoOverride -eq 'true'){ 1 } else { 0 }
            Order       = [int]$lnk.Order
          }
        }
      }
    }catch{}
  }

  if(-not $links){
    Log-pass "No GPO links found at the domain root ($root)."
    return
  }

  $flagged = $false
  foreach($l in $links){
    if($l.Enabled  -eq 0){ $flagged = $true; Log-Warning "Domain-root GPO link is disabled: $($l.DisplayName)" }
    if($l.Enforced -eq 0){ $flagged = $true; Log-Warning "Domain-root GPO link is not enforced: $($l.DisplayName)" }
  }

  if(-not $flagged){ Log-pass "All domain-root GPO links are enabled (and enforced per policy)" }
  else{ Log-failure "There are disabled or non-enforced GPO links at the domain root" }
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
    if(-not $sz){ Log-Warning "$name log size could not be determined"; $bad=$true; continue }

    $minMB=[int]$MinSizesMB[$name]
    $minBytes=[int64]$minMB*1MB
    if($sz -lt $minBytes){
      $bad=$true
      $currentMB=[math]::Round($sz/1MB)
      $comment="Fix: Run  wevtutil sl $name /ms:$minBytes"
      Log-failure "$name log maximum size too small: ${currentMB}MB < ${minMB}MB" -comment $comment
    }
  }

  if(-not $bad){ Log-pass "Event log maximum sizes meet or exceed baseline" }
}


<#
.SYNOPSIS
Runs DCDIAG RIDManager and checks for failures or low pool signals. OnlyForDCs
#>
function HealthTest-RidManager{
  $out=& dcdiag /test:ridmanager /v 2>&1
  $fail=($out | Select-String -Pattern 'failed test RidManager','is low' -SimpleMatch)
  if($fail){ Log-failure "RID Manager test reported issues" -Comment "Review dcdiag /test:ridmanager output"; } else { Log-pass "RID Manager health OK (dcdiag)" }
}

<#
.SYNOPSIS
Checks presence of EFS Data Recovery Agents policy/certs. OnlyForDomainServers
#>
function HealthTest-EfsRecoveryAgents{
  $out=& certutil -recoveryagent 2>&1
  $has=($out | Select-String -Pattern 'Recovery Agent' -SimpleMatch)
  if($has){ Log-pass "EFS Data Recovery Agents are configured" } else { Log-notice "No EFS Data Recovery Agents configured." -comment "If anyone uses EFS (NTFS file encryption), there's no domain recovery agent to decrypt data if the user's key is lost." }
}

<#
.SYNOPSIS
Verifies DNS zone transfers are restricted. OnlyForDCs
#>
function HealthTest-DnsZoneTransfers{
  $zones=Get-DnsServerZone | Where-Object { -not $_.IsAutoCreated }
  $bad=$false
  foreach($z in $zones){
    if($z.SecureSecondaries -eq 'Any'){ $bad=$true; Log-failure "DNS zone transfer open to Any: $($z.ZoneName)" }
  }
  if(-not $bad){ Log-pass "DNS zone transfers are restricted (not 'Any')" }
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
    Log-pass "krbtgt password age acceptable ($ageDays days <= $MaxDays)"
  } else {
    Log-failure "krbtgt password age exceeds threshold($MaxDays)" -comment "The KRBTGT account key hasn't been rotated for $ageDays days. Windows keeps the previous KRBTGT key to validate existing TGTs; never rotating extends the brute force time window for an attacker. Risk: If an attacker ever accessed the KRBTGT key, they can mint TGTs and persist. Rotating twice (with replication time in between) is the standard mitigation."
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
  if($freeGB -ge $MinFreeGB){ Log-pass "NTDS log volume free space OK ($freeGB GB >= $MinFreeGB GB)" } else { Log-failure "NTDS log volume low free space ($freeGB GB < $MinFreeGB GB)" -Comment "Log path: $logPath" }
}

<#
.SYNOPSIS
Verifies required hotfix baseline is present. OnlyForDomainServers
#>
function HealthTest-HotfixBaseline{
  [CmdletBinding()] param([string[]]$RequiredKBs)
  if(-not $RequiredKBs -or $RequiredKBs.Count -eq 0){ Log-pass "No hotfix baseline provided"; return }
  $have=(Get-HotFix | Select-Object -ExpandProperty HotFixID)
  $miss=@()
  foreach($kb in $RequiredKBs){
    if($have -notcontains $kb){ $miss += $kb; Log-failure "Missing required hotfix: $kb" }
  }
  if($miss.Count -eq 0){ Log-pass "All required hotfixes are installed" }
}

<#
.SYNOPSIS
Validates DHCP DNS update credential account health. OnlyForDomainServers
#>
function HealthTest-DhcpDnsCredential{
  [CmdletBinding()] param([int]$MaxPwdAgeDays=365)
  $dhcp=Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
  if(-not $dhcp -or -not $dhcp.Installed){ Log-pass "DHCP role not installed on this server"; return }
  $cred=Get-DhcpServerDnsCredential -ErrorAction SilentlyContinue
  if(-not $cred -or -not $cred.UserName){ Log-failure "No DHCP DNS update credentials configured"; return }
  $u=Get-ADUser -Identity $cred.UserName -Properties Enabled,pwdLastSet
  $age=[int]((Get-Date) - [DateTime]::FromFileTime($u.pwdLastSet)).TotalDays
  if(-not $u.Enabled){ Log-failure "DHCP DNS credential account is disabled: $($cred.UserName)"; return }
  if($age -gt $MaxPwdAgeDays){ Log-failure "DHCP DNS credential password age too high ($age days > $MaxPwdAgeDays): $($cred.UserName)" } else { Log-pass "DHCP DNS credential healthy (Enabled, pwd age $age days <= $MaxPwdAgeDays)" }
}

<#
.SYNOPSIS
Validates GPT vs GPC version numbers for GPO consistency. OnlyForDomainServers
#>
function HealthTest-GpoVersionConsistency{

    $dom=(Get-ADDomain).DNSRoot
    $base="\\$dom\SYSVOL\$dom\Policies"
    $bad=$false
    foreach($g in Get-GPO -All){
      $ini="$base\{$($g.Id)}\gpt.ini"
      $gptVer = if(Test-Path $ini){ [int]((Get-Content $ini | where {$_ -match '^Version='}) -replace 'Version=','') } else { -1 }
      if($gptVer -lt 0){ $bad=$true; Log-failure "GPO missing GPT: $($g.DisplayName)"; continue }
      $uGpt=$gptVer -shr 16; $cGpt=$gptVer -band 0xFFFF
      if($uGpt -ne $g.User.DSVersion -or $cGpt -ne $g.Computer.DSVersion){
        $bad=$true
        Log-failure "GPO GPT/AD version mismatch: '$($g.DisplayName)' User AD=$($g.User.DSVersion) GPT=$uGpt; Computer AD=$($g.Computer.DSVersion) GPT=$cGpt"
      }
    }
  if(-not $bad){ Log-pass "All GPOs have matching GPT/GPC versions" }
}

<#
.SYNOPSIS
Compares SYSVOL policy tree manifest across DCs (count+hash). OnlyForDCs
.NOTES 
Stresses Network: SMB directory tree walks to each DC's SYSVOL\Policies across sites.
#>
function HealthTest-SysvolContentConsistency{
    $dom=(Get-ADDomain).DNSRoot
    $dcs=Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName

    $sigs = foreach($dc in $dcs){
      $p="\\$dc\SYSVOL\$dom\Policies"
      if(-not (Test-Path -LiteralPath $p)){
        Log-Failure "SYSVOL Policies path missing on ${dc}: $p"
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
      Log-Pass "SYSVOL policy tree manifests match across all DCs"
    } elseif($hasMissing){
      Log-Failure "At least one DC lacks SYSVOL\Policies" -Comment $map
    } else {
      Log-Failure "SYSVOL policy manifests are not consistent across DCs" -Comment $map
    }
}

<#
.SYNOPSIS
Reviews RODC PRP (allow/deny) presence where RODCs exist. OnlyForDomainServers
#>
function HealthTest-RodcPrp{
  $rodcs=Get-ADDomainController -Filter {IsReadOnly -eq $true}
  if(-not $rodcs){ Log-pass "No RODCs found (PRP not applicable)"; return }
  $bad=$false
  foreach($r in $rodcs){
    $ro=Get-ADObject $r.NTDSSettingsObjectDN -Properties msDS-RevealOnDemandGroup,msDS-NeverRevealGroup
    if(-not $ro.'msDS-RevealOnDemandGroup' -and -not $ro.'msDS-NeverRevealGroup'){ $bad=$true; Log-failure "RODC PRP not configured on $($r.HostName)" }
  }
  if(-not $bad){ Log-pass "PRP is configured on all RODCs" }
}

<#
.SYNOPSIS
Reports members of 'Pre-Windows 2000 Compatible Access' (should be empty). OnlyForDomainServers
#>
function HealthTest-PreWin2000Group{
  $g=Get-ADGroup -Identity 'Pre-Windows 2000 Compatible Access'
  $m=Get-ADGroupMember $g -Recursive -ErrorAction SilentlyContinue
  foreach($u in $m){ Log-failure "'Pre-Windows 2000 Compatible Access' contains member: $($u.SamAccountName)" }
  if(($m | Measure-Object).Count -eq 0){ Log-pass "'Pre-Windows 2000 Compatible Access' group has no members" }
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
    Log-Warning "This machine cannot read LDAP RootDSE. Is it domain-joined and can it reach a DC?"
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
        Log-pass "No GPO WMI filters defined (CN=WMIPolicy container not found)."
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
      Log-Warning "Cannot enumerate WMI filters via GPMC or LDAP. Check: domain join, DC reachability/DNS, and GPMC installation."
      return
    }
  }

  if(-not $items){ Log-pass "No GPO WMI filters defined"; return }

  $unique = $items | Sort-Object Filter,Namespace -Unique
  foreach($i in $unique){
    try{
      $null=Get-CimInstance -Namespace $i.Namespace -ClassName __NAMESPACE -ErrorAction Stop
    } catch {
      $bad=$true
      Log-failure "WMI namespace missing for filter '$($i.Filter)': $($i.Namespace)"
    }
  }  

  if(-not $bad){ Log-pass "All WMI namespaces referenced by GPO WMI filters exist on this host" }
  else{ Log-Warning "One or more GPO WMI filter namespaces are missing on this host" }
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
  if ($role -in 0,2) { Log-Notice "This test ($fn) is not applicable to non-domain joined hosts"; return }
  if ($role -in 4,5) { Log-Notice "This test ($fn) is not applicable to Domain Controllers"; return }

  $domain = $cs.Domain
  $out = ipconfig /all 2>&1
  $pattern = "DNS Suffix.* $domain`$"
  if ($out | Select-String -Pattern $pattern) {
    Log-pass "Domain name appears in DNS suffix" -Comment "Domain: $domain"
  } else {
    Log-failure "Domain name does not appear in DNS suffix" -Comment "Expected suffix: $domain"
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
  if ($role -in 0,2) { Log-Notice "This test ($fn) is not applicable to non-domain joined hosts"; return }
  if ($role -in 4,5) { Log-Notice "This test ($fn) is not applicable to Domain Controllers"; return }

  Log-debug "Reading C:\it\config\ips-of-all-DCs.conf to get the list of the IPs of all DCs"
  # will return a list of IPs or throw
  $dcIps = Get-AllDCIPs -Path 'C:\it\config\ips-of-all-DCs.conf'

  $domain = $cs.Domain
  $ares = $null
  try { $ares = Resolve-DnsName -Name $domain -Type A -ErrorAction Stop } catch {}
  if (-not $ares) {
    Log-failure "No A records found for domain DNS name." -Comment $domain
    return
  }

  $aIps = @($ares | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
  $intersection = @()
  foreach ($ip in $aIps) { if ($dcIps -contains $ip) { $intersection += $ip } }

  $comment = "Domain=$domain; DC IPs=" + ($dcIps -join ', ') + "; Domain A IPs=" + ($aIps -join ', ')
  if ($intersection.Count -gt 0) {
    Log-pass "Domain DNS name resolves to at least one DC IP." -Comment $comment
  } else {
    Log-failure "Domain DNS name does not resolve to any known DC IPv4 address." -Comment $comment
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
  if ($role -in 0,2) { Log-Notice "This test ($fn) is not applicable to non-domain joined hosts"; return }
  if ($role -in 4,5) { Log-Notice "This test ($fn) is not applicable to Domain Controllers"; return }

  Log-debug "Reading C:\it\config\ips-of-all-DCs.conf to get the list of the IPs of all DCs"
  # will return a list of IPs or throw
  $dcIps = Get-AllDCIPs -Path 'C:\it\config\ips-of-all-DCs.conf'

  $nets = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=TRUE"
  if (-not $nets) {
    Log-failure "No IP-enabled network adapters found."
    return
  }

  $anyClean = $false
  $anyBad   = $false

  foreach ($net in $nets) {
    $dns  = $net.DNSServerSearchOrder
    $desc = $net.Description
    if (-not $dns -or $dns.Count -eq 0) {
      Log-Notice "Interface has no DNS servers configured." -Comment $desc
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
      Log-pass "Interface has only DCs as DNS servers." -Comment ("Interface: " + $desc + "; DNS=" + $dnsList)
    } elseif ($allNonDomain) {
      # Ignoring this interface that only has non-domain DNS servers
    } else {
      $anyBad = $true
      Log-failure "Interface DNS servers include non-DC addresses." -Comment ("Interface: " + $desc + "; DNS=" + $dnsList + "; DC IPs=" + ($dcIps -join ', '))
    }
  }

  if (-not $anyClean) {
    Log-failure "No interface found where all DNS servers are DC IPs."
  } elseif (-not $anyBad) {
    Log-pass "All interfaces with DNS configured use only DC IPs."
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
  if ($role -in 0,2) { Log-Notice "This test ($fn) is not applicable to non-domain joined hosts"; return }
  if ($role -in 4,5) { Log-Notice "This test ($fn) is not applicable to Domain Controllers"; return }

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
    Log-pass "NLTEST /dsgetsite succeeded." -Comment ("Site: " + $site)
  } else {
    $hex = '0x{0:X}' -f ($exit -band 0xFFFFFFFF)
    Log-failure "NLTEST /dsgetsite failed." -Comment ("ExitCode=" + $hex + "; Output=`n" + $txt)
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
  if ($role -in 0,2) { Log-Notice "This test ($fn) is not applicable to non-domain joined hosts"; return }
  if ($role -in 4,5) { Log-Notice "This test ($fn) is not applicable to Domain Controllers"; return }


  if (!(Test-ComputerSecureChannel)) {
      Log-warning "Can't connected to any Domain Controller. Can not run gpupdate." -comment "Make sure you are on the domain LAN or connected via VPN."
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
    Log-pass "Computer and user policy updates completed successfully (gpupdate)."
    return
  }

  if ($compOk) {
    Log-pass "Computer policy update completed successfully (gpupdate)."
  } else {
    Log-failure "Computer policy update did not report success." -Comment ("gpupdate output:`n" + $text)
  }

  if (-not $userOk) {
    if ($isSystem) {
      Log-notice "User policy update did not report success (gpupdate running under SYSTEM/non-interactive)." -Comment ("This can be expected when no interactive user is logged on.`nRaw gpupdate output:`n" + $text)
    } else {
      Log-failure "User policy update did not report success." -Comment ("Expected success for interactive user.`nRaw gpupdate output:`n" + $text)
    }
  } else {
    Log-pass "User policy update completed successfully (gpupdate)."
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
                Log-failure "Storage($p) error in last N hours" -comment "N=$Hours hours; Event: $($_.TimeCreated), $($_.LevelDisplayName), $($_.Message)"
                $pass = $false
            }
        } catch {
            if ($_.Exception.Message -notlike '*There is not an event provider*') {
                Log-Warning "Failed reading System log for provider '$p': $($_.Exception.Message)"
            }
        }
    }

    if ($pass) {
        Log-pass "No disk/NTFS/storage errors in last $Hours h"
    }

}

<# .SYNOPSIS Looks for crash dumps and bugcheck events as indicators of recent system crashes. #>
function HealthTest-CrashDumpSignals {
    param([int]$Hours = 48)

    $pass = $true
    if ($Hours -lt 1) { $Hours = 1 }
    $cutoff = (Get-Date).AddHours(-$Hours)

    Get-ChildItem "$env:SystemRoot\Minidump" -Filter *.dmp -ErrorAction SilentlyContinue | ?{ $_.LastWriteTime -gt $cutoff } | %{
        Log-Failure "Found $env:SystemRoot\Minidump\ file(s) within the last N hours" -comment "N=$Hours hours. File: $env:SystemRoot\Minidump\$($_.name))"
    }
    if ($pass) {
        Log-pass "No recent minidumps"
    }

    $pass = $true
    Get-WinEvent -FilterHashtable @{
            LogName   = 'System'
            Id        = 1001  # BugCheck
            StartTime = $cutoff
    } -ErrorAction SilentlyContinue | %{
        Log-Failure "Found System Event #1001 within the last N hours (this event often indicates a crash)" -comment "N=$Hours hours. Event: $($_.TimeCreated), $($_.LevelDisplayName), $($_.Message)"
    }

    if ($pass) {
        Log-pass "No recent System #1001 events"
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
            Log-Warning "Unexpected Local Administrator: $full"
            $pass = $false
        }
    }
    if ($pass) {
        Log-pass "No unexpected accounts in Local Administrators"
    }
}

<# .SYNOPSIS Checks physical NICs for link problems and significant error rates. #>
function HealthTest-Nic {
    $nics = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
    if (-not $nics) {
        Log-debug "No physical NICs with Status=Up; skipping NIC health check"
        return
    }

    $pass = $true
    $minPackets = 100000

    foreach ($n in $nics) {
        $stat = Get-NetAdapterStatistics -Name $n.Name -ErrorAction SilentlyContinue
        if (-not $stat) {
            Log-debug "Network interface skipped due to missing stats ($($n.Name))"
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
            Log-Warning "Disconnected network interface ($($n.Name))" -Comment ""
            $pass = $false
            continue
        }

        if ($totalPackets -lt $minPackets) {
            Log-debug "Network interface skipped due to low traffic ($($n.Name))"
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
            Log-Warning "Network interface with plenty of errors ($($n.Name))" -Comment "errors=$pctStr ($errors/$totalPackets total packets)"
            $pass = $false
        } elseif ($errors -ge 100 -and $errorPct -ge 0.002) {
            $noticeList += "$($n.Name): errors=$pctStr ($errors/$totalPackets total)"
            Log-Notice "Network interface with some errors ($($n.Name))" -Comment "errors=$pctStr ($errors/$totalPackets total packets)"
            $pass = $false
        } else {
            # below 0.002%: considered OK, no log entry
            continue
        }
    }

    if ($pass) {
        Log-pass "Network interfaces healthy; no significant error rates or disconnected interfaces detected"
    }
}

<# .SYNOPSIS Summarizes BitLocker protection status for local volumes. #>
function HealthTest-BitLockerStatus {
    if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        Log-warning "BitLocker PowerShell cmdlets not available; skipping BitLocker status check"
        return
    }

    $pass = $true

    $vols = Get-BitLockerVolume -ErrorAction SilentlyContinue
    if (-not $vols) {
        Log-notice "No BitLocker-capable volumes found"

    }
    $vols | Where-Object { $_.ProtectionStatus -ne 'On' } | %{
        Log-Failure "Volume not protected by BitLocker: $($_.MountPoint)"
        $pass = $false
    }
    if ($pass) {
        Log-pass "BitLocker protection is ON for all detected volumes"
    }
}

<# .SYNOPSIS Detects DHCP scopes whose utilization is close to exhaustion. #>
function HealthTest-DhcpScopeUtilization {
    $svc = Get-Service -Name 'DHCPServer' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Log-debug "Host is not a DHCP server (DHCPServer service missing); skipping DHCP scope utilization test"
        return
    }

    if (-not (Get-Command Get-DhcpServerv4ScopeStatistics -ErrorAction SilentlyContinue)) {
        Log-warning "DHCP server cmdlets not available on this DHCP server; skipping DHCP scope utilization test"
        return
    }

    $stats = Get-DhcpServerv4ScopeStatistics -ErrorAction SilentlyContinue
    if (-not $stats) {
        Log-Warning "DHCP server role present but no DHCPv4 scopes found"
        return
    }

    $over = @()
    foreach ($s in $stats) {
        if ($s.PercentageInUse -ge 90) {
            $over += $s.ScopeId
            Log-Failure "DHCP scope is >=90% used: $($s.ScopeId)"
        } elseif ($s.PercentageInUse -ge 80) {
            $over += $s.ScopeId
            Log-Warning "DHCP scope is >=80% used: $($s.ScopeId)"
        }
    }

    if ($over.Count -gt 0) {
        Log-pass "DHCP scope utilization OK (<80% in use)"
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
        Log-Failure "Primary DNS suffix" "Current is empty" "Ensure the system has a primary DNS suffix (normally set by domain join)."
    } elseif ($primarySuffix -ieq $DomainName) {
        Log-Pass "Primary DNS suffix" $primarySuffix
    } else {
        Log-Failure "Primary DNS suffix" ("Current='{0}' Expected='{1}'" -f $primarySuffix,$DomainName) "Ensure primary DNS suffix equals the AD DNS name (normally set by domain join)."
    }

    # 2) DNS devolution is enabled (boolean only)
    try {
        $g = Get-DnsClientGlobalSetting -ErrorAction Stop
        if ($g.UseDevolution -eq $true) {
            Log-Pass "DNS devolution enabled" "UseDevolution=True"
        } else {
            Log-Failure "DNS devolution enabled" "UseDevolution=False" "Enable devolution (GPO: Computer Configuration/Administrative Templates/Network/DNS Client/Turn off DNS devolution = Disabled)."
        }
    } catch {
        $err = $_
        Log-Failure "DNS devolution enabled" ("Unable to query global DNS client settings: {0}" -f $err.Exception.Message) "Check OS support for Get-DnsClientGlobalSetting and that the DNS Client service is running."
    }

    # 3) Per-NIC checks (only PASS/FAIL; no discovery warning if none found)
    $nics = @()
    try {
        $nics = Get-DnsClient -ErrorAction Stop |
                Where-Object { $_.InterfaceOperationalStatus -eq "Up" -and $_.ConnectionSpecificSuffix -ne "localdomain" }
    } catch {
        $err = $_
        Log-Failure "NIC DNS settings" ("Unable to query DNS client interfaces: {0}" -f $err.Exception.Message) "Confirm OS supports Get-DnsClient and you have sufficient privileges."
        $nics = @()
    }

    foreach ($n in $nics) {
        $nicName = $n.InterfaceAlias

        # 3a) Registration flags must both be True
        if ($n.RegisterThisConnectionsAddress -and $n.UseSuffixWhenRegistering) {
            Log-Pass ("NIC '{0}' DNS registration" -f $nicName) "RegisterThisConnectionsAddress=True, UseSuffixWhenRegistering=True"
        } else {
            Log-Failure ("NIC '{0}' DNS registration" -f $nicName) ("RegisterThisConnectionsAddress={0}, UseSuffixWhenRegistering={1}" -f $n.RegisterThisConnectionsAddress,$n.UseSuffixWhenRegistering) "Enable both flags on important interfaces."
        }

        # 3b) Connection-specific suffix: must be Empty OR exactly the domain
        $css = $n.ConnectionSpecificSuffix
        if ([string]::IsNullOrWhiteSpace($css)) {
            Log-Pass ("NIC '{0}' Conn.-specific suffix" -f $nicName) "Empty"
        } elseif ($css -ieq $DomainName) {
            Log-Pass ("NIC '{0}' Conn.-specific suffix" -f $nicName) ("Equals {0}" -f $DomainName)
        } else {
            Log-Failure ("NIC '{0}' Conn.-specific suffix" -f $nicName) ("Set to '{0}'" -f $css) "Leave blank for single-domain setups unless a specific suffix is required."
        }
    }
}

