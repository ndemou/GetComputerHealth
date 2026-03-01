<#
.SYNOPSIS
Runs a suite of built-in and optional custom "HealthTest-*" checks and reports their findings; can also whitelist/suppress expected messages by signature.

.DESCRIPTION
Executes many health-test functions (named `HealthTest-*`) and emits their results either as structured objects (`-OutputObjects`) and/or as colorized console messages (`-OutputConsoleMessages`), with optional filtering via `-Hide`.

Supports:
- Listing available built-in tests (`-ListAllBuiltInTests`).
- Running only selected tests (`-OnlyTheseTests`) and/or skipping specific tests (`-ExcludeTests`).
- Loading and running custom tests by dot-sourcing `.ps1` files from a folder or a single `.ps1` path (`-IncludeTestsFromFolder`) and invoking any `CustomHealthTest-*` functions they define.
- Suppressing expected notices/warnings/failures by 8-hex "signature" hashes, either temporarily for the current run (`-WhitelistSigs`) or by appending a permanent suppression entry (`-AddWhitelisting`) to a suppression file.

Notable side effects:
- When `-IncludeTestsFromFolder` is used, dot-sources scripts (executes their top-level code) from the provided location.
- The health tests themselves may perform read/write operations depending on their implementation (this script invokes them; it does not enforce read-only behavior).

Idempotency:
- `-AddWhitelisting` is append-only (not strictly idempotent): repeated runs add additional lines; last matching line "wins" when loading suppressions.

Dependencies & execution context:
- Requires elevation.
- Relies on two companion library scripts:
  - `lib-write-log-objects.ps1`
  - `lib-health-tests.ps1`
- Uses a suppression config file at `C:\it\config\Get-ComputerHealth.sigs-to-suppress.txt`.

.PARAMETER OutputConsoleMessages
(Parameter set: Run) If set, writes colorized log/messages to the console while executing tests.

.PARAMETER OutputObjects
(Parameter set: Run) If set, outputs structured objects produced by the health tests to the pipeline.

.PARAMETER Hide
(Parameter set: Run) Message visibility filter. String containing only letters from `DIPNWFC`.
Default: empty (show all). Typical value: `DIP`
  D = hide Debug messages
  I = hide Info messages
  P = hide Pass messages
  N = hide Notice messages
  W = hide Warning messages
  F = hide Failure messages
  C = hide Comments (messages still print, but without their Comment lines)

.PARAMETER WhitelistSigs
(Parameter set: Run) One or more 8-hex signatures to suppress for this run only (merged into the loaded suppression set).

.PARAMETER OnlyTheseTests
(Parameter set: Run) One or more function names to execute (treated as a list; values may be space/comma separated). When provided, only these tests are invoked.

.PARAMETER ExcludeTests
(Parameter set: Run) One or more function names to skip (treated as a list; values may be space/comma separated).

.PARAMETER IncludeTestsFromFolder
(Parameter set: Run) Path to a folder containing `.ps1` files (or a single `.ps1` path). Files are dot-sourced; any functions named `CustomHealthTest-*` discovered are invoked.

.PARAMETER DebugSkipSlowTests
(Parameter set: Run) Skips a predefined subset of "slow" built-in tests (those gated by the script's `$DebugSkipSlowTests` check).

.PARAMETER DoNothing
(Parameter set: Run) Immediate no-op return (useful for smoke-testing invocation/parameter binding).

.PARAMETER AddWhitelisting
(Parameter set: AddWhitelist) Appends a suppression entry for a specific signature to the suppression file and exits (does not run health tests).

.PARAMETER ComputerName
(Parameter set: AddWhitelist; Mandatory) Target computer name for the suppression entry. Must match the current computer `$env:COMPUTERNAME`.

.PARAMETER Signature
(Parameter set: AddWhitelist; Mandatory) 8-hex signature to suppress (case-insensitive). Alias: `-Sig`.

.PARAMETER Comment
(Parameter set: AddWhitelist) Optional text appended to the suppression line (non-ASCII characters are replaced with `?`).

.PARAMETER Until
(Parameter set: AddWhitelist) Optional expiry date for the suppression entry in `yyyy-MM-dd` format. After this date passes, the entry is treated as expired when loading.

.PARAMETER ListAllBuiltInTests
(Parameter set: List; Mandatory) Lists all currently loaded `HealthTest-*` functions with their synopsis text and exits.

.EXAMPLE
# Run all applicable built-in tests; show console output but hide Debug/Info/Pass; also return objects:
$out = .\Get-ComputerHealth.ps1 -OutputConsoleMessages -OutputObjects -Hide DIP
$out | Out-GridView

.EXAMPLE
# List available built-in tests (name + synopsis):
.\Get-ComputerHealth.ps1 -ListAllBuiltInTests

.EXAMPLE
# Run only a small subset of tests by name:
.\Get-ComputerHealth.ps1 -OutputConsoleMessages -OnlyTheseTests HealthTest-PendingReboot,HealthTest-DisksHaveFreeSpace

.EXAMPLE
# Temporarily suppress specific signatures just for this run:
.\Get-ComputerHealth.ps1 -OutputConsoleMessages -WhitelistSigs 1a2b3c4d,deadbeef

.EXAMPLE
# Permanently suppress a known-expected signature on this computer (optionally with expiry):
.\Get-ComputerHealth.ps1 -AddWhitelisting -ComputerName CONTOSO-SRV01 -Signature 1a2b3c4d -Comment "Known baseline deviation" -Until 2026-12-31

.NOTES
- Elevation is enforced for normal runs and for whitelisting operations.
- Permanent suppression file: `C:\it\config\Get-ComputerHealth.sigs-to-suppress.txt`.
- Custom tests: dot-sourced scripts may execute arbitrary code on import; only functions named `CustomHealthTest-*` are invoked automatically.
#>

[CmdletBinding(DefaultParameterSetName='Run')]
param(
  # ----------------------------
  # Normal run (execute tests)
  # ----------------------------
  [Parameter(ParameterSetName='Run')]
  [switch]$OutputConsoleMessages,

  [Parameter(ParameterSetName='Run')]
  [switch]$OutputObjects,

  [Parameter(ParameterSetName='Run')]
  [ValidatePattern('^[DIPNWFC]*$')]
  [string]$Hide = '',

  [Parameter(ParameterSetName='Run')]
  [Alias('SuppressSigs')]
  [string[]]$WhitelistSigs = @(),

  [Parameter(ParameterSetName='Run')]
  [string[]]$OnlyTheseTests = @(),

  [Parameter(ParameterSetName='Run')]
  [string[]]$ExcludeTests = @(),

  [Parameter(ParameterSetName='Run')]
  [string]$IncludeTestsFromFolder,

  [Parameter(ParameterSetName='Run')]
  [switch]$DebugSkipSlowTests,

  [Parameter(ParameterSetName='Run')]
  [switch]$DoNothing,

  # ----------------------------
  # Add whitelisting entry
  # ----------------------------
  [Parameter(ParameterSetName='AddWhitelist', Mandatory)]
  [switch]$AddWhitelisting,

  [Parameter(ParameterSetName='AddWhitelist', Mandatory)]
  [ValidateNotNullOrEmpty()]
  [string]$ComputerName,

  [Parameter(ParameterSetName='AddWhitelist', Mandatory)]
  [Alias('Sig')]
  [ValidatePattern('^[0-9A-Fa-f]{8}$')]
  [string]$Signature,

  [Parameter(ParameterSetName='AddWhitelist')]
  [string]$Comment,

  [Parameter(ParameterSetName='AddWhitelist')]
  [ValidatePattern('^\d{4}-\d{2}-\d{2}$')]
  [string]$Until,

  # ----------------------------
  # List tests
  # ----------------------------
  [Parameter(ParameterSetName='List', Mandatory)]
  [switch]$ListAllBuiltInTests
)

$VERSION="1.4.0"

#------------------------------------------
# Configuration
#

$global:SUPPRESS_SIGNATURES_PATH = 'C:\it\config\Get-ComputerHealth.sigs-to-suppress.txt'

#------------------------------------------
# Dot source libraries of functions
#
. (Join-Path -Path $PSScriptRoot -ChildPath "lib-write-log-objects.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "lib-health-tests.ps1")

#------------------------------------------
# Helper functions specific to this script except tests
#
function Add-AsciiLine {
# Append a line to an ASCII file (replaces non ASCII chars with ?)
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Line
  )
  # Replace non-ASCII chars (anything > 0x7F) with '?'
  $safeLine = ($Line -replace '[^\u0000-\u007F]', '?')
  # Append using ASCII encoding
  Add-Content -LiteralPath $Path -Value $safeLine -Encoding ASCII
}

function Test-IsVirtualMachine {
# returns $true if it guesses the computer is VM
    [CmdletBinding()]
    param()

    $cs  = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $csp = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction SilentlyContinue

    $man = ($cs.Manufacturer, $csp.Vendor   | Where-Object { $_ }) -join ' '
    $mod = ($cs.Model,        $csp.Name     | Where-Object { $_ }) -join ' '
    $txt = "$man $mod"

    if (-not $txt) { return $false }

    $patterns = @{
        'Hyper-V'    = 'Microsoft Corporation Virtual Machine'
        'VMware'     = 'VMware'
        'VirtualBox' = 'VirtualBox'
        'Xen'        = 'Xen HVM domU'
        'KVM'        = 'KVM QEMU'
        'Azure'      = 'Microsoft Corporation Virtual Machine'
        'EC2'        = 'EC2'
        'GCP'        = 'Google Compute Engine'
    }

    foreach ($k in $patterns.Keys) {
        foreach ($needle in $patterns[$k].Split(' ')) {
            if ($txt -like "*$needle*") {
                return $true
            }
        }
    }

    if ($txt -like '*Virtual Machine*' -or $txt -like '*VirtualBox*' -or $txt -like '*VMware*') {
        return $true
    }

    return $false
}

function Test-IsLaptopOrMobile {
# returns $true if it guesses the computer is laptop/mobile

    $cs  = Get-CimInstance Win32_ComputerSystem     -ErrorAction SilentlyContinue
    $enc = Get-CimInstance Win32_SystemEnclosure    -ErrorAction SilentlyContinue
    $bat = Get-CimInstance Win32_Battery            -ErrorAction SilentlyContinue

    $chassisTypes = @()
    if ($enc -and $enc.ChassisTypes) { $chassisTypes = @($enc.ChassisTypes) }

    $mobileChassis  = 8,9,10,11,12,14,18,30,31,32
    $desktopChassis = 3,4,5,6,7,13,15,24,34

    $hasMobileType  = @($chassisTypes | Where-Object { $mobileChassis  -contains $_ }).Count -gt 0
    $hasDesktopType = @($chassisTypes | Where-Object { $desktopChassis -contains $_ }).Count -gt 0

    $pcSystemType = $null
    if ($cs -and (Get-Member -InputObject $cs -Name PCSystemType -MemberType *Property -ErrorAction SilentlyContinue)) {
        $pcSystemType = $cs.PCSystemType  # 2 ~= Mobile
    }

    $hasBattery = $bat -ne $null

    $isMobile = $false
    if ($hasMobileType -or $pcSystemType -eq 2 -or ($hasBattery -and -not $hasDesktopType)) {
        $isMobile = $true
    }

    return $isMobile
}

function Invoke-HealthTest {
<#
.SYNOPSIS
Invoke a named health-test function and return a structured result object.

.OUTPUTS
[pscustomobject] with properties:
FunctionName, Time, ElapsedMilliseconds, Output, Success, Error, Category, Reason, FullyQualifiedErrorId, ScriptStackTrace
#>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$FunctionName,

    [object]$Argument
  )

  $start_time = Get-Date

  if ($ExcludeTests -contains $FunctionName) {
      Log-Debug "Skipping test $FunctionName"
      return
  }

  Write-Progress -Activity "Starting test $FunctionName"
  Log-debug "Starting test $FunctionName"
  $cmd = Get-Command -Name $FunctionName -CommandType Function -ErrorAction SilentlyContinue
  if (-not $cmd) {
      Log-failure "(Program Error) Health test function '$FunctionName' not found"
      return
  }

  $target = (Get-Item ("Function:\{0}" -f $cmd.Name)).ScriptBlock
  $oldEap = $ErrorActionPreference
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $cntProperRecord = 0
    $cntImproperRecord = 0
    $cntPassRecord = 0
    $ErrorActionPreference = 'Stop'

    if ($PSBoundParameters.ContainsKey('Argument')) {
      # write-verbose '$result = & $target $Argument'
      $result = & $target $Argument
    } else {
      # write-verbose '$result = & $target'
      $result = & $target
    }
    # write-verbose "`$result = $result"
    $result | %{
        if($_ -and $_.PSObject.Properties['Hash'] -and $_.PSObject.Properties['Message'] -ne $null -and $_.PSObject.Properties['level']){
            $cntProperRecord += 1
            if ($_.level -eq 'pass') {$cntPassRecord += 1}
            write-output $_
        } else {
            $cntImproperRecord += 1
            Log-Warning "$FunctionName returned malformed output (this is due to a programmer's mistake)." -comment $_
        }
    }
    if ($cntProperRecord -eq 0 -and $cntImproperRecord -eq 0) {
        Log-notice "$FunctionName returned no output (this is due to a programmer's mistake; the test may or may not have passed)"
    }
  } catch {
    $err = $_
    $inv = $err.InvocationInfo

    # Try to locate the inner (real) throw site from the script stack trace
    $innerFunc = $null; $innerFile = $null; $innerLine = $null; $innerCode = $null

    # The ScriptStackTrace has lines like:
    # "at HealthTest-Whatever, C:\path\Module.psm1: line 123"
    $frames = ($err.ScriptStackTrace -split "`r?`n") |
              Where-Object { $_ -match ':\s*line\s+\d+' }

    # Prefer the first frame that is NOT this wrapper function
    $frame = $frames | Where-Object { $_ -notmatch '\bInvoke-HealthTest\b' } | Select-Object -First 1
    if (-not $frame) { $frame = $frames | Select-Object -First 1 } # fallback

    if ($frame -and $frame -match '^(?:at\s+)?([^,]+),\s*(.+?):\s*line\s+(\d+)\s*$') {
      $innerFunc = $matches[1].Trim()
      $innerFile = $matches[2].Trim()
      $innerLine = [int]$matches[3]

      # Try to fetch the actual source line (best-effort)
      try {
        if ($innerFile -and (Test-Path -LiteralPath $innerFile)) {
          $innerCode = (Get-Content -LiteralPath $innerFile -TotalCount $innerLine)[-1]
        }
      } catch { }
    }

    # Build a helpful message with graceful fallbacks
    $baseMsg   = Get-LeftString $err.Exception.GetBaseException().Message 500
    $outerLine = $inv.ScriptLineNumber
    $outerCode = $inv.Line

    $details =
      if ($innerLine -and $innerFunc) {
        "Line: $innerLine" +
        ($(if ($innerCode) { "`n  #       Code: $innerCode" } else { "" }))
      } else {
        # Fallback to the catcher's position info
        "Throw site unknown from stack; fallback to caller:`n  #       Line #$($outerLine): $outerCode"
      }

    Log-Failure "(Program Error) Exception while running '$FunctionName'" `
      -Comment "details: $baseMsg`nThis often means that the test failed but it may also be a bug in this code."
  } finally {
    $sw.Stop()
    $ErrorActionPreference = $oldEap
    Write-Progress -Activity "Starting test $FunctionName" -Completed
  }

  Log-debug "Done with test $FunctionName in $([int]$sw.ElapsedMilliseconds) ms"
}

function Get-HealthTests {
<#
.SYNOPSIS
Lists all loaded HealthTest-* functions with their synopsis text.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    Get-Command -CommandType Function -Name 'HealthTest-*' | ForEach-Object {
        $help = Get-Help $_.Name -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Name     = $_.Name
            Synopsis = $help.Synopsis
        }
    }
}

function Invoke-HealtTestsFromFolder {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true,Position=0)][string]$FolderPath)

  $resolved = $null
  try { $resolved = (Resolve-Path -LiteralPath $FolderPath -ErrorAction Stop).Path }
  catch {
    Log-debug "Path -IncludeTestsFromFolder $FolderPath was not found"
    return
  }

  $before = @{}
  Get-ChildItem Function:\ -ErrorAction SilentlyContinue | ForEach-Object { $before[$_.Name] = $true }

  if(-not (Test-Path -LiteralPath $resolved -PathType Container)){
    if ($resolved -like ".ps1") {
        $files = @($resolved)
    } else {
        Log-debug "Path -IncludeTestsFromFolder $FolderPath was ignored because it's neither a folder nor a ps1 script"
        return
    }
  } else {
      $files = @(Get-ChildItem -LiteralPath $resolved -Filter *.ps1 -File -ErrorAction SilentlyContinue)
  }

  $fileImported = $false
  foreach($f in $files){
    Log-debug "Found script $($f.name) in custom tests folder $resolved"
    try {
      . $f.FullName
      $fileImported = $true
    } catch {
      Log-failure "Dot-source failed for $($f.FullName): $($_.Exception.Message)"
    }
  }
  if (!$fileImported) {return}
  
  log-info "Invoke-HealtTestsFromFolder imported at least one file. Will invoke custom health tests."

  $after = @{}
  Get-ChildItem Function:\ -ErrorAction SilentlyContinue | ForEach-Object { $after[$_.Name] = $true }

  $foundExtraFunction = $false
  $added = New-Object System.Collections.Generic.List[string]
  foreach($name in $after.Keys){
    if(-not $before.ContainsKey($name)){
        $foundExtraFunction = $true
        if ($name -like "CustomHealthTest-*") {
            Invoke-HealthTest $name
        } else {
            log-debug "Ignoring function $name (doesn't start with 'CustomHealthTest-')"
        }
    }
  }
  if (!$foundExtraFunction) {
    Log-warning "Found no extra function in $FolderPath."
  }
}

function Write-UsageHelp {
    write-host -ForegroundColor Cyan  "$((Split-Path $PSCommandPath -Leaf) -replace '.ps1') version $VERSION, Nick Demou, enLogic"
    write-host -ForegroundColor Gray  ""
    write-host -ForegroundColor Gray  "Most often you want to use me like this:"
    write-host -ForegroundColor white "    `$out = $PSCommandPath -OutputConsoleMessages -Hide " -nonewline
    write-host -ForegroundColor DarkCyan "DIP"
    write-host -ForegroundColor Gray  "          # (-Hide DIP means: hide Debug, Informationcal and Pass messages)"
    write-host -ForegroundColor white "    `$out | ogv # or similar"
    write-host -ForegroundColor Gray  ""
    write-host -ForegroundColor Gray  "You can whitelist messages that are normal for this computer like this:"
    write-host -ForegroundColor white "    $PSCommandPath -AddWhitelisting -sig " -nonewline
    write-host -ForegroundColor DarkCyan "012345678" -nonewline
    write-host -ForegroundColor white " -comment `"" -nonewline
    write-host -ForegroundColor DarkCyan "optional comment" -nonewline
    write-host -ForegroundColor white "`""
    write-host -ForegroundColor Gray  ""
    write-host -ForegroundColor Gray  "Consider installing the ImportExcel module to easily export results to excel:"
    write-host -ForegroundColor white "    Install-Module ImportExcel"
    write-host -ForegroundColor white "    . 'c:\it\bin\lib-write-log-objects.ps1'"
    write-host -ForegroundColor white '    Export-HealthMessagesToExcel -Data $out -FileName "C:\it\all-messages.xlsx"'
    return
}
#=============================================================================
#
# MAIN CODE
#
#=============================================================================

if ($ListAllBuiltInTests) {Get-HealthTests; return}

# Fail if not run as Administrator (elevated)
# None of the functionality that follows is available to non-admins
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent() `
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator (elevated)."
    exit 1
}

if ($AddWhitelisting ){
    if (!$Signature) {throw "You must supply a -Signature"}
    if (!$ComputerName) {throw "You must supply a -ComputerName"}
    if ($Signature -notmatch '^[0-9A-Fa-f]{8}$') {
        throw "Invalid -Signature: $Signature"
    }
    if ($ComputerName -ne $env:COMPUTERNAME) {
        throw "Running on $($env:COMPUTERNAME) but suppression is for $ComputerName"
    }
    if ($Until) {
        $dt=[datetime]::MinValue
        $ok=[DateTime]::TryParseExact($Until,'yyyy-MM-dd',$Culture,[System.Globalization.DateTimeStyles]::None,[ref]$dt)
        if(-not $ok){$ok=[DateTime]::TryParse($Until,[System.IFormatProvider]$Culture,[System.Globalization.DateTimeStyles]::None,[ref]$dt)}
        if(-not $ok){throw "Invalid date: `$Until"}
        $line='{0} UNTIL {1:yyyy-MM-dd} # {2:yyyy-MM-dd HH:mm} # {3}' -f $Signature,$dt,(Get-Date),$Comment
        Add-AsciiLine -Line $line -Path $global:SUPPRESS_SIGNATURES_PATH
    } else {
        $line = "$Signature # $(Get-Date -format yyyy-MM-dd` HH:mm) # $Comment"
        Add-AsciiLine -Line $line -Path $global:SUPPRESS_SIGNATURES_PATH
    }
    return
}

if ($DoNothing){return}

if (!$OutputConsoleMessages -and !$OutputObjects) {
	Write-UsageHelp
	return
}

# To reach this line either one or both of these switches where passed: 
# -OutputConsoleMessages -OutputObjects

#+-----------------------------------------------------------
#| Initialize globals that lib-generic-tui needs
#|
Initialize-LogSystem `
  -OutputConsoleMessages $OutputConsoleMessages.IsPresent `
  -HideStr $Hide `
  -SuppressionFilePath $global:SUPPRESS_SIGNATURES_PATH `
  -AdditionalSuppressedSignatures $WhitelistSigs
#|
#|
#+-----------------------------------------------------------

Log-info "$((Split-Path $PSCommandPath -Leaf) -replace '.ps1'), ver.$VERSION, Nick Demou, enLogic"
Log-info "$(Get-Date -format yyyy-MM-dd` HH:mm:ss), Computer: $($env:COMPUTERNAME), S/N: $((Get-CimInstance win32_bios).serialnumber)"
Log-Debug "-Hide '$Hide'"
[array]$ExcludeTests=$ExcludeTests | %{ $_ -split '[,\s]+'} | %{$_.trim()} | ?{ $_ } | sort -uniq
Log-Debug "-ExcludeTests (semicolon separated): $($ExcludeTests -join ';')"
[array]$OnlyTheseTests=$OnlyTheseTests | %{ $_ -split '[,\s]+'} | %{$_.trim()} | ?{ $_ }
Log-Debug "-OnlyTheseTests (semicolon separated): $($OnlyTheseTests -join ';')"
Log-Debug "-WhitelistSigs '$WhitelistSigs'"
$cfg = Get-LogConfig
Log-debug "Final list of suppressed signatures: $((@($cfg.SuppressedSignatures) | Sort-Object -Unique) -join ', ')"


if ($OnlyTheseTests) {
    $valid_cmdlet_name_regex = '^ *[A-Za-z][A-Za-z0-9_-]*[A-Za-z0-9]+ *$'

    foreach ($item in $OnlyTheseTests) {
        if ($item -match $valid_cmdlet_name_regex) {
            Invoke-HealthTest $item
        } else {
            Log-Warning "Input '$item' is not a valid cmdlet name."
        }
    }
    return
}


#     Domain Role                              |
#  ------------------------------------------- |
#  Value | Meaning                             |
#  ----- | ----------------------------------- |
#  0     | Workstation not joined to a domain  |
#  1     | Workstation joined to a domain      |
#  2     | Server not joined to a domain       |
#  3     | Server joined to a domain           |
#  4     | Domain controller (non-FSMO)        |
#  5     | Domain controller (PDC Emulator)    |
#
$domainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole
#------------------------------------------
# What type of system are we running on
#------------------------------------------
$isHostVM = Test-IsVirtualMachine                # V   (based on heuristics)
$isHostMobile = Test-IsLaptopOrMobile            # L   (based on heuristics)
$isHostDomainJoined = ($domainRole  -in 1,3,4,5) # J (N = Not domain joines)
$isHostServer = ($domainRole  -in 3,4,5)         # S (W = not a server (Workstation))
$isHostDC = ($domainRole -in 4,5)                # C   (by definition also JS)
if($isHostDC){$isHostPDC=$false                  # P   (by definition also CJS)
	$domainInfo=$null
    try{
        $domainInfo=[System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
        $isHostPDC=(($domainInfo.PdcRoleOwner.Name -replace '[.].*') -eq $env:COMPUTERNAME)
    }catch{}
}

if ($isHostMobile) {
    Invoke-HealthTest "HealthTest-IsTPMActivated"
}

#=============================================================================
#
# START OF TESTS
#
#=============================================================================

#--------------------------------------------------------
# For any computer (Generic)
Invoke-HealthTest "HealthTest-PendingReboot"
Invoke-HealthTest "HealthTest-MalwareProtectionFeatures"
Invoke-HealthTest "HealthTest-DefaultLocale"
Invoke-HealthTest "HealthTest-DefenderStatus"
Invoke-HealthTest "HealthTest-RecentWindowsScan"
Invoke-HealthTest "HealthTest-DisksHaveFreeSpace"
Invoke-HealthTest "HealthTest-LocalAcntRequirePass"
Invoke-HealthTest "HealthTest-NonDefaultShares"
Invoke-HealthTest "HealthTest-CertExpiry"
Invoke-HealthTest "HealthTest-NtfsDirtyBit"
Invoke-HealthTest "HealthTest-IisBindings"
Invoke-HealthTest "HealthTest-DfsrBacklog"
Invoke-HealthTest "HealthTest-AutoStartServicesRunning"
Invoke-HealthTest "HealthTest-NtlmHardening"
Invoke-HealthTest "HealthTest-SmbSigningRequired"
Invoke-HealthTest "HealthTest-Smb1Disabled"
Invoke-HealthTest "HealthTest-RestrictAnonymous"
Invoke-HealthTest "HealthTest-PagefileSanity"
Invoke-HealthTest "HealthTest-WinRMListening"
Invoke-HealthTest "HealthTest-DnsClientService"
Invoke-HealthTest "HealthTest-WmiRepository"
Invoke-HealthTest "HealthTest-StartupItems"
Invoke-HealthTest "HealthTest-RamPressure"
Invoke-HealthTest "HealthTest-UpdateAge"
Invoke-HealthTest "HealthTest-SingleDefaultGateway"
Invoke-HealthTest "HealthTest-ScheduledTasks"
Invoke-HealthTest "HealthTest-SystemScheduledTasks"
Invoke-HealthTest "HealthTest-VssWriters"
Invoke-HealthTest "HealthTest-TimeSyncAccuracy"
Invoke-HealthTest "HealthTest-TimeSyncPolicy"
Invoke-HealthTest "HealthTest-UnsignedDrivers"
Invoke-HealthTest "HealthTest-CrashDumpSignals"
Invoke-HealthTest "HealthTest-LocalAdminsBaseline"
Invoke-HealthTest "HealthTest-Nic"
Invoke-HealthTest "HealthTest-EventLogMaxSizes"
Invoke-HealthTest "HealthTest-HotfixBaseline"
Invoke-HealthTest "HealthTest-RdpHardening"
Invoke-HealthTest "HealthTest-RequiredSrvRecords"
# Invoke-HealthTest "HealthTest-ExploitProtectionBaseline"

if (-not $isHostVM) {
    Invoke-HealthTest "HealthTest-BitLockerStatus"
    Invoke-HealthTest "HealthTest-RecentDiskErrors"
}

# Tests that take >1sec (Not including ones for DCs):
#   1.2s  HealthTest-IisBindings
#   1.3s  HealthTest-Smb1Disabled
#   1.7s  HealthTest-MalwareProtectionFeatures
#   1.8s  HealthTest-SingleDefaultGateway
#   2.1s  HealthTest-TimeSyncAccuracy
#   2.3s  HealthTest-SystemScheduledTasks
#   2.5s  HealthTest-VssWriters
#   2.6s  HealthTest-UnsignedDrivers
#   2.7s  HealthTest-RamPressure

# Tests that take >3sec (Not including ones for DCs):
# (These are skiped by -DebugSkipSlowTests)
#   3.5s  HealthTest-ShareReasonableness
#   3.7s  HealthTest-FirewallEnabled
#   3.9s  HealthTest-IPv6Binding
#   4.0s  HealthTest-UnexpectedListeningPorts
#   5.0s  HealthTest-Storage
#   5.9s  HealthTest-NonMicrosoftServices
#  26.3s  HealthTest-GpupdatePolicyApply

if (!$DebugSkipSlowTests) {
	Invoke-HealthTest "HealthTest-SoftwareLicensing"
	Invoke-HealthTest "HealthTest-ScheduledTasksLastResult"
    Invoke-HealthTest "HealthTest-FirewallEnabled"
    Invoke-HealthTest "HealthTest-Storage"
    Invoke-HealthTest "HealthTest-ShareReasonableness"
    Invoke-HealthTest "HealthTest-UnexpectedListeningPorts"
    Invoke-HealthTest "HealthTest-IPv6Binding"
    Invoke-HealthTest "HealthTest-NonMicrosoftServices"
    Invoke-HealthTest "HealthTest-LargeDirectories"
}

if ($isHostServer) {
    Invoke-HealthTest "HealthTest-InstalledRolesFeatures"
    Invoke-HealthTest "HealthTest-DhcpInAd"
    Invoke-HealthTest "HealthTest-ShadowStorage"
    Invoke-HealthTest "HealthTest-DhcpScopeUtilization"
}

if ($isHostDomainJoined) {
    Invoke-HealthTest "HealthTest-ConnectivityToDCs"
    Invoke-HealthTest "HealthTest-DnsSuffixBaseline"
}

if ($isHostDC) {
    if (!$DebugSkipSlowTests) {
		Invoke-HealthTest "HealthTest-DfsDiagTestDCs"
		Invoke-HealthTest "HealthTest-Dcdiag"
	}
    Invoke-HealthTest "HealthTest-ADViewConsistency"
    Invoke-HealthTest "HealthTest-DfsReplicationState"
    Invoke-HealthTest "HealthTest-ADReplicationLocalRSAT"
    Invoke-HealthTest "HealthTest-DcDnsServerForwarder"
    Invoke-HealthTest "HealthTest-NtdsPathsLocation"
    Invoke-HealthTest "HealthTest-LdapSigningChannelBinding"
    Invoke-HealthTest "HealthTest-UnusedEnabledAdapters"
    Invoke-HealthTest "HealthTest-NetworkInterfaceMetrics"
    Invoke-HealthTest "HealthTest-DisabledGpoLinksAtDomainRoot"

    # TODO: some of these below are maybe for all member servers
    Invoke-HealthTest "HealthTest-SchanelBaseline"
    Invoke-HealthTest "HealthTest-EfsRecoveryAgents"
    Invoke-HealthTest "HealthTest-GpWmiFiltersNamespaces"
    #---END TODO---------------------

    # TODO: These tests are domain-wide and there's no need to execute them from all DCs -- if they get executed by one DC we are OK
    Invoke-HealthTest "HealthTest-ADReplicationDomainRepadmin"
    Invoke-HealthTest "HealthTest-SysvolNetlogonAccessible"
    Invoke-HealthTest "HealthTest-SchemaVersionConsistency"
    Invoke-HealthTest "HealthTest-TombstoneLifetime"
    Invoke-HealthTest "HealthTest-RecycleBinEnabled"
    Invoke-HealthTest "HealthTest-TrustsVerify"
    Invoke-HealthTest "HealthTest-ReplicationLatency"
    Invoke-HealthTest "HealthTest-UnconstrainedDelegationAccounts"
    Invoke-HealthTest "HealthTest-DuplicateSpn"
    Invoke-HealthTest "HealthTest-ServiceAccountsPwdNeverExpires"
    #---END TODO---------------------

    # TODO: only run these tests if DNS role is enabled
    Invoke-HealthTest "HealthTest-DnsZoneReplicationScope"
    Invoke-HealthTest "HealthTest-DnsScavenging"
    Invoke-HealthTest "HealthTest-DnsForwarders"
    #---END TODO---------------------

    # GPT5 inspired tests
    Invoke-HealthTest "HealthTest-DcDnsARecords"
    Invoke-HealthTest "HealthTest-DnsRecursionConfig"
    Invoke-HealthTest "HealthTest-ReverseZonesPresent"
    Invoke-HealthTest "HealthTest-GcPlacement"
    Invoke-HealthTest "HealthTest-KccConnectivity"
    Invoke-HealthTest "HealthTest-SysvolAclHygiene"
    Invoke-HealthTest "HealthTest-RidManager"
    Invoke-HealthTest "HealthTest-DnsZoneTransfers"
    Invoke-HealthTest "HealthTest-NtdsLogVolumeFree"
    Invoke-HealthTest "HealthTest-SysvolContentConsistency"
    Invoke-HealthTest "HealthTest-DfsrBacklogSysvol"
    Invoke-HealthTest "HealthTest-GpoVersionConsistency"
    Invoke-HealthTest "HealthTest-AdminSDHolderCoverage"
    Invoke-HealthTest "HealthTest-DfsNamespaceEnumerate"
    Invoke-HealthTest "HealthTest-KerberosEncryptionTypes"
    Invoke-HealthTest "HealthTest-RodcPrp"
    Invoke-HealthTest "HealthTest-PreWin2000Group"
    Invoke-HealthTest "HealthTest-KrbtgtAge"
    Invoke-HealthTest "HealthTest-DhcpDnsCredential"
}

if ($isHostDomainJoined -and -not $isHostDC) {
    Invoke-HealthTest "HealthTest-DomainARecordPointsToDcIp"
    Invoke-HealthTest "HealthTest-InterfaceDnsServersUseDcs"
    Invoke-HealthTest "HealthTest-DnsSuffixMatchesDomain"
    Invoke-HealthTest "HealthTest-NltestSiteDiscovery"
    if (!$DebugSkipSlowTests) {Invoke-HealthTest "HealthTest-GpupdatePolicyApply"}
}

if (Get-Command -Name Get-VM -ErrorAction SilentlyContinue) {
    # Only for Hyper-v Hypervisors
    Invoke-HealthTest "HealthTest-HyperVRunningVMs"
}

if ($IncludeTestsFromFolder) {
    Invoke-HealtTestsFromFolder $IncludeTestsFromFolder
}

#=============================================================================
#
# END OF TESTS
#
#=============================================================================
