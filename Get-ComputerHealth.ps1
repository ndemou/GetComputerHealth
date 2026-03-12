<#
.SYNOPSIS
Runs a suite of built-in and optional custom "HealthTest-*" checks and reports their findings; can also whitelist/suppress expected messages by signature.

.DESCRIPTION
Executes many health-test functions (named `HealthTest-*`) and emits their results either as structured objects (`-OutputObjects`) and/or as colorized console messages (`-OutputConsoleMessages`), with optional filtering via `-Hide`.

Supports:
- Listing available built-in tests (`-ListAllBuiltInTests`).
- Running only selected tests (`-OnlyTheseTests`) and/or skipping specific tests (`-ExcludeTests`).
- Loading and running custom tests from `.ps1` files in an isolated module scope (`-IncludeTestsFromFolder`) and invoking any `HealthTest-*` functions they define.
- Suppressing expected notices/warnings/failures by 8-hex "signature" hashes, either temporarily for the current run (`-WhitelistSigs`) or by appending a permanent suppression entry (`-AddWhitelisting`) to a suppression file.

Notable side effects:
- When `-IncludeTestsFromFolder` is used, custom scripts are loaded in a temporary module scope (top-level code still executes, but does not run in this script's scope/function table).
- The health tests themselves may perform read/write operations depending on their implementation (this script invokes them; it does not enforce read-only behavior).

Idempotency:
- `-AddWhitelisting` is append-only (not strictly idempotent): repeated runs add additional lines; last matching line "wins" when loading suppressions.

Dependencies & execution context:
- Requires elevation.
- Relies on companion scripts: `lib-write-log-objects.ps1` and themed `ht-*.ps1` modules dot-sourced below.
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
(Parameter set: Run) Path to a folder containing `.ps1` files (or a single `.ps1` path). Files are loaded in an isolated module scope; any functions named `HealthTest-*` discovered are invoked.

.PARAMETER DebugSkipSlowTests
(Parameter set: Run) Skips a predefined subset of "slow" built-in tests (those gated by the script's `$DebugSkipSlowTests` check).

.PARAMETER IpsOfAllDcs
(Parameter set: Run) Optional list of Domain Controller IP addresses passed in by the orchestrator. Stored in `$Global:GetComputerHealthDataQMTA.IpsOfAllDcs` for health tests that need it.

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
- Custom tests: scripts may execute arbitrary code on import; files are loaded in temporary module scope and functions named `HealthTest-*` are invoked automatically.
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
  [string[]]$IpsOfAllDcs = @(),

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

$VERSION="2.0.4"

#------------------------------------------
# Configuration
#

$script:Config = [pscustomobject]@{
  SuppressSignaturesPath = 'C:\it\config\Get-ComputerHealth.sigs-to-suppress.txt'
}

#------------------------------------------
# Dot source libraries of functions
#
. (Join-Path -Path $PSScriptRoot -ChildPath "lib-write-log-objects.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "ht-AD-GPO-mgmt.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "ht-DNS-DHCP-srvc.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "ht-syscfg-featdisc.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "ht-srvc-exe-resolve.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "ht-file-dir-anlz.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "ht-schtasks-master.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "ht-net-conn.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "ht-os-perf-hw.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "ht-win-os-hyg.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "ht-hyperv-mgmt.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "ht-special.ps1")

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
    [OutputType([bool])]
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

    $hasBattery = $null -ne $bat

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
    [string]$FunctionName
  )

  function Convert-TextToLogRecord {
    param([Parameter(Mandatory)][string]$Text)

    $normalized = ($Text -replace "`r", '')
    $lines = @($normalized -split "`n")
    if (-not $lines -or ($lines.Count -eq 1 -and [string]::IsNullOrWhiteSpace($lines[0]))) {
      return [pscustomobject]@{ Message=''; Comment='' }
    }

    $msg = [string]$lines[0]
    $comment = ''
    if ($lines.Count -gt 1) {
      $comment = ($lines | Select-Object -Skip 1) -join "`n"
    }
    [pscustomobject]@{ Message=$msg.Trim(); Comment=$comment.Trim() }
  }

  function Convert-WarningRecordToLog {
    param([Parameter(Mandatory)][System.Management.Automation.WarningRecord]$WarningRecord)

    $parts = Convert-TextToLogRecord ([string]$WarningRecord.Message)
    $level = 'warning'
    $msg = $parts.Message
    $comment = $parts.Comment

    if ($parts.Message -match '^\s*\[([a-z]+)\]\s*(.*)$') {
      $candidate = $matches[1].ToLowerInvariant()
      if ($candidate -in @('debug','pass','info','notice','warning','failure')) {
        $level = $candidate
        $msg = [string]$matches[2]
      }
    }

    if ([string]::IsNullOrWhiteSpace($msg)) { $msg = '<empty warning message>' }
    Log-Msg -Level $level -Msg $msg.Trim() -Comment $comment
  }

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
    $legacyLogDetected = $false
    $ErrorActionPreference = 'Stop'

    $result = & {
      $WarningPreference = 'Continue'
      if ($PSBoundParameters.ContainsKey('Argument')) {
        & $target $Argument 3>&1
      } else {
        & $target 3>&1
      }
    }

    $result | ForEach-Object {
      if ($_ -is [System.Management.Automation.WarningRecord]) {
        Convert-WarningRecordToLog $_
        $cntProperRecord += 1
        if (($_.Message -as [string]) -match '^\s*\[\s*pass\s*\]') { $cntPassRecord += 1 }
      } elseif ($_ -and $_.PSObject.Properties['Hash'] -and $null -ne $_.PSObject.Properties['Message'] -and $_.PSObject.Properties['level']){
        $legacyLogDetected = $true
        $cntProperRecord += 1
        if ($_.level -eq 'pass') {$cntPassRecord += 1}
        Write-Output $_
      } elseif ($_ -is [string]) {
        $parts = Convert-TextToLogRecord $_
        $cntImproperRecord += 1
        Log-Debug $parts.Message -Comment $parts.Comment
      } else {
        $cntImproperRecord += 1
        $objType = $_.GetType().FullName
        $objText = ($_ | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($objText)) { $objText = '<empty object serialization>' }
        Log-Debug "Converted output object of type $objType" -Comment $objText
      }
    }

    if ($legacyLogDetected) {
      $sourceScript = $cmd.ScriptBlock.File
      $sourceLabel = if ([string]::IsNullOrWhiteSpace($sourceScript)) { "function '$FunctionName'" } else { "script '$sourceScript'" }
      Log-Notice "Consider modernizing the code in $sourceLabel to use Write-Warning instead of Log-Pass/Log-Failure/..."
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
      } catch { Log-Debug "Program Error: Failed to fetch the actual source line"}
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

function Get-HealthTest {
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

function Invoke-HealthTestsFromFolder {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true,Position=0)][string]$FolderPath)

  $resolved = $null
  try { $resolved = (Resolve-Path -LiteralPath $FolderPath -ErrorAction Stop).Path }
  catch {
    Log-debug "Path -IncludeTestsFromFolder $FolderPath was not found"
    return
  }

  if(-not (Test-Path -LiteralPath $resolved -PathType Container)){
    if ($resolved -like "*.ps1") {
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
    $m = $null
    try {
      $m = New-Module -ArgumentList $f.FullName -ScriptBlock {
        param($Path)
        . $Path
      }

      $customHealthTests = @(& $m {
        Get-Command -CommandType Function -Name 'HealthTest-*' -Module $ExecutionContext.SessionState.Module -ErrorAction SilentlyContinue
      })
      $legacyCustomHealthTests = @(& $m {
        Get-Command -CommandType Function -Name 'CustomHealthTest-*' -Module $ExecutionContext.SessionState.Module -ErrorAction SilentlyContinue
      })

      $allCustomTests = @($customHealthTests) + @($legacyCustomHealthTests) | Group-Object -Property Name | ForEach-Object { $_.Group[0] }

      if (-not $allCustomTests) {
        Log-debug "No HealthTest-* or CustomHealthTest-* functions found in $($f.FullName)"
        continue
      }

      if ($legacyCustomHealthTests.Count -gt 0) {
        Log-Notice "$($f.Name) uses legacy CustomHealthTest-* prefix. Please rename to HealthTest-*"
      }

      $fileImported = $true

      foreach($fn in $allCustomTests){
        $existing = Get-Item -Path ("Function:\{0}" -f $fn.Name) -ErrorAction SilentlyContinue
        try {
          Set-Item -Path ("Function:\{0}" -f $fn.Name) -Value $fn.ScriptBlock -Force
          Invoke-HealthTest $fn.Name
        } finally {
          if ($existing) {
            Set-Item -Path ("Function:\{0}" -f $fn.Name) -Value $existing.ScriptBlock -Force
          } else {
            Remove-Item -Path ("Function:\{0}" -f $fn.Name) -ErrorAction SilentlyContinue
          }
        }
      }
    } catch {
      $errorRecord = $_
      $rootException = $errorRecord.Exception
      while ($rootException.InnerException) {
        $rootException = $rootException.InnerException
      }

      $importErrorDetails = @(
        "Primary error: $($errorRecord.Exception.Message)"
        "Root cause: $($rootException.Message)"
        "ErrorId: $($errorRecord.FullyQualifiedErrorId)"
        "Category: $($errorRecord.CategoryInfo)"
        "Script: $($f.FullName)"
        "--- Full error record ---"
        ($errorRecord | Out-String).Trim()
      ) -join [Environment]::NewLine

      Log-failure "Custom test import failed for $($f.FullName)" -Comment $importErrorDetails
    } finally {
      if ($m) {
        Remove-Module -ModuleInfo $m -Force -ErrorAction SilentlyContinue
      }
    }
  }
  if (!$fileImported) {return}

  log-info "Invoke-HealthTestsFromFolder imported at least one file with HealthTest-* functions."
}

function Write-UsageHelp {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingWriteHost', '',
        Justification='Only triggered by interactive use.'
    )]
    param()

    Write-Host -ForegroundColor Cyan  "$((Split-Path $PSCommandPath -Leaf) -replace '.ps1') version $VERSION, Nick Demou, enLogic"
    Write-Host -ForegroundColor Gray  ""
    Write-Host -ForegroundColor Gray  "Most often you want to use me like this:"
    Write-Host -ForegroundColor White "    `$out = $PSCommandPath -OutputConsoleMessages -Hide " -NoNewline
    Write-Host -ForegroundColor DarkCyan "DIP"
    Write-Host -ForegroundColor Gray  "          # (-Hide DIP means: hide Debug, Informationcal and Pass messages)"
    Write-Host -ForegroundColor White "    `$out | ogv # or similar"
    Write-Host -ForegroundColor Gray  ""
    return
}
#=============================================================================
#
# MAIN CODE
#
#=============================================================================

if ($ListAllBuiltInTests) {Get-HealthTest; return}

# Fail if not run as Administrator (elevated)
# None of the functionality that follows is available to non-admins
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent() `
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator (elevated)."
    exit 1
}

if ($AddWhitelisting ){
    if (-not $Signature) {throw "You must supply a -Signature"}
    if (-not $ComputerName) {throw "You must supply a -ComputerName"}
    if ($Signature -notmatch '^[0-9A-Fa-f]{8}$') {
        throw "Invalid -Signature: $Signature"
    }
    if ($ComputerName -ne $env:COMPUTERNAME) {
        throw "Running on $($env:COMPUTERNAME) but suppression is for $ComputerName"
    }
    if ($Until) {
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        $dt=[datetime]::MinValue
        $ok=[DateTime]::TryParseExact($Until,'yyyy-MM-dd',$culture,[System.Globalization.DateTimeStyles]::None,[ref]$dt)
        if(-not $ok){$ok=[DateTime]::TryParse($Until,[System.IFormatProvider]$culture,[System.Globalization.DateTimeStyles]::None,[ref]$dt)}
        if(-not $ok){throw "Invalid date: `$Until"}
        $line='{0} UNTIL {1:yyyy-MM-dd} # {2:yyyy-MM-dd HH:mm} # {3}' -f $Signature,$dt,(Get-Date),$Comment
        Add-AsciiLine -Line $line -Path $script:Config.SuppressSignaturesPath
    } else {
        $line = "$Signature # $(Get-Date -format yyyy-MM-dd` HH:mm) # $Comment"
        Add-AsciiLine -Line $line -Path $script:Config.SuppressSignaturesPath
    }
    return
}

if ($DoNothing){return}

if (-not $OutputConsoleMessages -and -not $OutputObjects) {
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
  -SuppressionFilePath $script:Config.SuppressSignaturesPath `
  -AdditionalSuppressedSignatures $WhitelistSigs
#|
#|
#+-----------------------------------------------------------

Log-info "$((Split-Path $PSCommandPath -Leaf) -replace '.ps1'), ver.$VERSION, Nick Demou, enLogic"
Log-info "$(Get-Date -format yyyy-MM-dd` HH:mm:ss), Computer: $($env:COMPUTERNAME), S/N: $((Get-CimInstance win32_bios).serialnumber)"
Log-Debug "-Hide '$Hide'"
[array]$ExcludeTests = $ExcludeTests |
  ForEach-Object { $_ -split '[,\s]+' } |
  ForEach-Object { $_.Trim() } |
  Where-Object { $_ } |
  Sort-Object -Unique
Log-Debug "-ExcludeTests (semicolon separated): $($ExcludeTests -join ';')"
[array]$OnlyTheseTests = $OnlyTheseTests |
  ForEach-Object { $_ -split '[,\s]+' } |
  ForEach-Object { $_.Trim() } |
  Where-Object { $_ }
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
$isHostPDC = $false
$currentDomain = $null
if($isHostDC){$isHostPDC=$false                  # P   (by definition also CJS)
	$domainInfo=$null
    try{
        $domainInfo=[System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
        $currentDomain = $domainInfo
        $isHostPDC=(($domainInfo.PdcRoleOwner.Name -replace '[.].*') -eq $env:COMPUTERNAME)
    } catch {
        Log-Warning "Could not determine if host is the PDC emulator for its domain."
	}
}

$normalizedIpsOfAllDcs = @(
    $IpsOfAllDcs |
        Where-Object { $_ } |
        ForEach-Object { $_.ToString().Trim() } |
        Where-Object { $_ }
)

$ipCounts = @{}
$validIpsList = New-Object System.Collections.Generic.List[string]
$invalidIps = New-Object System.Collections.Generic.List[string]

foreach ($ip in $normalizedIpsOfAllDcs) {
    if ($ipCounts.ContainsKey($ip)) { $ipCounts[$ip]++ } else { $ipCounts[$ip] = 1 }

    $parsed = $ip -as [ipaddress]
    $isValidV4 = ($parsed -and ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork))

    if ($isValidV4) {
        if (-not $validIpsList.Contains($ip)) {
            [void]$validIpsList.Add($ip)
        }
    } else {
        if (-not $invalidIps.Contains($ip)) {
            [void]$invalidIps.Add($ip)
        }
    }
}

foreach ($entry in $ipCounts.GetEnumerator() | Where-Object { $_.Value -gt 1 } | Sort-Object Key) {
    Log-Warning "Duplicate IP '$($entry.Key)' provided in -IpsOfAllDcs $($entry.Value) times; using one instance."
}

if ($invalidIps.Count -gt 0) {
    throw "Invalid IPv4 value(s) supplied in -IpsOfAllDcs: $($invalidIps -join ', ')"
}

$validIpsOfAllDcs = @($validIpsList)

if ($isHostDomainJoined -and $validIpsOfAllDcs.Count -eq 0) {
    Log-failure "Cannot run many domain-related tests because no valid IPv4 addresses were provided in -IpsOfAllDcs. Marking this host as non-domain for test applicability."
    $isHostDomainJoined = $false
    $isHostDC = $false
    $isHostPDC = $false
    $currentDomain = $null
}

# Explicitly created so host-fact values are publicly accessible to all health tests,
# including custom health tests loaded at runtime.
$Global:GetComputerHealthDataQMTA = [pscustomobject]@{
    isHostVM           = $isHostVM
    isHostMobile       = $isHostMobile
    isHostDomainJoined = $isHostDomainJoined
    isHostServer       = $isHostServer
    isHostDC           = $isHostDC
    isHostPDC          = $isHostPDC
    GetCurrentDomain   = $currentDomain
    IpsOfAllDcs        = @($validIpsOfAllDcs)
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
if (!$DebugSkipSlowTests) { Invoke-HealthTest "HealthTest-SingleDefaultGateway" }
Invoke-HealthTest "HealthTest-NetworkConnectionProfiles"
Invoke-HealthTest "HealthTest-ScheduledTasks"
Invoke-HealthTest "HealthTest-SystemScheduledTasks"
if (!$DebugSkipSlowTests) { Invoke-HealthTest "HealthTest-VssWriters" }
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
	Invoke-HealthTest "HealthTest-DcDnsRegistration"
    Invoke-HealthTest "HealthTest-ADViewConsistency"
    Invoke-HealthTest "HealthTest-DfsReplicationState"
    Invoke-HealthTest "HealthTest-ADReplicationLocalRSAT"
    Invoke-HealthTest "HealthTest-DcDnsServerForwarder"
    Invoke-HealthTest "HealthTest-NtdsPathsLocation"
    Invoke-HealthTest "HealthTest-LdapSigningChannelBinding"
    Invoke-HealthTest "HealthTest-UnusedEnabledAdapters"
    Invoke-HealthTest "HealthTest-NetworkInterfaceMetrics"
    if (!$DebugSkipSlowTests) { Invoke-HealthTest "HealthTest-DisabledGpoLinksAtDomainRoot" }

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
    if (!$DebugSkipSlowTests) { Invoke-HealthTest "HealthTest-SysvolContentConsistency" }
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
    Invoke-HealthTestsFromFolder $IncludeTestsFromFolder
}
