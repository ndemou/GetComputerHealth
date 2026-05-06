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
- Relies on companion scripts: `lib-write-log-objects.ps1` and the modules under `health-tests\*.ps1` dot-sourced below.
- Uses a suppression config file at `C:\it\config\Get-ComputerHealth.sigs-to-suppress.txt`.

.PARAMETER RunWithoutElevation
(Parameter sets: Run, AddWhitelist, List) Bypasses the normal elevation requirement. Default behavior still requires running as Administrator.

.PARAMETER OutputConsoleMessages
(Parameter set: Run) If set, writes colorized log/messages to the console while executing tests.

.PARAMETER OutputObjects
(Parameter set: Run) If set, outputs structured objects produced by the health tests to the pipeline.

.PARAMETER Hide
(Parameter set: Run) Message visibility filter. String containing only letters from `DIPNWFSC`.
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

.PARAMETER SkipSlowTests
(Parameter set: Run) Skips health tests that have high time impact (`Impact: ... High(Time)` in their help block).

.PARAMETER DebugSkipSlowTests
(Parameter set: Run) Alias for `-SkipSlowTests` (kept for backward compatibility).

.PARAMETER SkipPolicyTests
(Parameter set: Run) Skips health tests tagged as policy inventory tests (`Tags: Policy` in their help block), such as `HealthTest-InstalledSW`.

.PARAMETER DontAutosetPolicy
(Parameter set: Run) Disables first-run auto-baselining for policy tests (`Tags: Policy`, e.g. `HealthTest-InstalledSW`). By default, first run auto-suppresses emitted `[NOTICE]`/`[WARNING]` findings for each policy test and records a marker in the suppression file.

.PARAMETER IpsOfAllDcs
(Parameter set: Run) Optional list of Domain Controller IP addresses passed in by the orchestrator. Stored in `$Global:GCHDQMTA.IpsOfAllDcs` for health tests that need it.

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
- `-RunWithoutElevation` bypasses the elevation guard; some health tests may still fail or produce incomplete results when run non-elevated.
- Permanent suppression file: `C:\it\config\Get-ComputerHealth.sigs-to-suppress.txt`.
- Custom tests: scripts may execute arbitrary code on import; files are loaded in temporary module scope and functions named `HealthTest-*` are invoked automatically.
#>

[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
  [Parameter(ParameterSetName = 'PrettifyWarning')]
  [Alias('Prettify')]
  [switch]$PrettifyWriteWarning,

  [Parameter(ParameterSetName = 'PrettifyWarning', ValueFromPipeline = $true)]
  [AllowNull()]
  [object]$InputObject,

  # ----------------------------
  # Normal run (execute tests)
  # ----------------------------
  [Parameter(ParameterSetName = 'Run')]
  [switch]$OutputConsoleMessages,

  [Parameter(ParameterSetName = 'Run')]
  [switch]$OutputObjects,

  [Parameter(ParameterSetName = 'Run')]
  [ValidatePattern('^[DIPNWFSC]*$')]
  [string]$Hide = '',

  [Parameter(ParameterSetName = 'Run')]
  [Alias('SuppressSigs')]
  [string[]]$WhitelistSigs = @(),

  [Parameter(ParameterSetName = 'Run')]
  [string[]]$OnlyTheseTests = @(),

  [Parameter(ParameterSetName = 'Run')]
  [string[]]$ExcludeTests = @(),

  [Parameter(ParameterSetName = 'Run')]
  [string]$IncludeTestsFromFolder,

  [Parameter(ParameterSetName = 'Run')]
  [Alias('DebugSkipSlowTests')]
  [switch]$SkipSlowTests,

  [Parameter(ParameterSetName = 'Run')]
  [switch]$SkipPolicyTests,

  [Parameter(ParameterSetName = 'Run')]
  [Alias('Quick')]
  [switch]$SkipNonEssentialTests,

  [Parameter(ParameterSetName = 'Run')]
  [switch]$DontAutosetPolicy,

  [Parameter(ParameterSetName = 'Run')]
  [string[]]$IpsOfAllDcs = @(),

  [Parameter(ParameterSetName = 'Run')]
  [switch]$DoNothing,

  [Parameter(ParameterSetName = 'Run')]
  [Parameter(ParameterSetName = 'AddWhitelist')]
  [Parameter(ParameterSetName = 'List')]
  [switch]$RunWithoutElevation,

  # ----------------------------
  # Add whitelisting entry
  # ----------------------------
  [Parameter(ParameterSetName = 'AddWhitelist', Mandatory)]
  [switch]$AddWhitelisting,

  [Parameter(ParameterSetName = 'AddWhitelist', Mandatory)]
  [ValidateNotNullOrEmpty()]
  [string]$ComputerName,

  [Parameter(ParameterSetName = 'AddWhitelist', Mandatory)]
  [Alias('Sig')]
  [ValidatePattern('^[0-9A-Fa-f]{8}$')]
  [string]$Signature,

  [Parameter(ParameterSetName = 'AddWhitelist')]
  [string]$Comment,

  [Parameter(ParameterSetName = 'AddWhitelist')]
  [ValidatePattern('^\d{4}-\d{2}-\d{2}$')]
  [string]$Until,

  # ----------------------------
  # List tests
  # ----------------------------
  [Parameter(ParameterSetName = 'List', Mandatory)]
  [switch]$ListAllBuiltInTests
)

$VERSION="4.1.3"


$SCRIPT_BIN_DIR = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$ROOT_DIR = Split-Path -Parent $SCRIPT_BIN_DIR
$CONFIG_DIR = Join-Path $ROOT_DIR 'config'

#------------------------------------------
# Configuration
#

$script:Config = [pscustomobject]@{
  SuppressSignaturesPath = Join-Path $CONFIG_DIR 'Get-ComputerHealth.sigs-to-suppress.txt'
}

#------------------------------------------
# Dot source libraries of functions
#
. (Join-Path -Path $PSScriptRoot -ChildPath "lib-write-log-objects.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "helpers-networking.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "helpers-for-custom-ht.ps1")

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

  $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
  $csp = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction SilentlyContinue

  $man = ($cs.Manufacturer, $csp.Vendor   | Where-Object { $_ }) -join ' '
  $mod = ($cs.Model, $csp.Name     | Where-Object { $_ }) -join ' '
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

  $cs = Get-CimInstance Win32_ComputerSystem     -ErrorAction SilentlyContinue
  $enc = Get-CimInstance Win32_SystemEnclosure    -ErrorAction SilentlyContinue
  $bat = Get-CimInstance Win32_Battery            -ErrorAction SilentlyContinue

  $chassisTypes = @()
  if ($enc -and $enc.ChassisTypes) { $chassisTypes = @($enc.ChassisTypes) }

  $mobileChassis = 8, 9, 10, 11, 12, 14, 18, 30, 31, 32
  $desktopChassis = 3, 4, 5, 6, 7, 13, 15, 24, 34

  $hasMobileType = @($chassisTypes | Where-Object { $mobileChassis -contains $_ }).Count -gt 0
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
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$FunctionName
  )

  $metaForExclude = Get-HealthTestTagsMetadata -FunctionName $FunctionName
  $markTestMessagesSuppressed = 'Suppressed' -in $metaForExclude.Tags
  $baseFunctionName = "HealthTest-$($metaForExclude.TestName)"
  if (($ExcludeTests -contains $FunctionName) -or ($ExcludeTests -contains $baseFunctionName) -or ($ExcludeTests -contains $metaForExclude.TestName)) {
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
      }
      else {
        & $target 3>&1
      }
    }

    foreach ($item in $result) {
      if ($item -is [System.Management.Automation.WarningRecord]) {
        $record = Convert-WarningLikeObjectToLogRecord -Value $item
        Log-Msg -Level $record.Level -Msg $record.Msg -Comment $record.Comment -Emitter $FunctionName -Suppressed:$markTestMessagesSuppressed
        $cntProperRecord += 1
        if (($item.Message -as [string]) -match '^\s*\[\s*pass\s*\]') { $cntPassRecord += 1 }
      }
      elseif ($item -and $item.PSObject.Properties['Hash'] -and $null -ne $item.PSObject.Properties['Message'] -and $item.PSObject.Properties['level']) {
        $legacyLogDetected = $true
        $cntProperRecord += 1
        if ($item.level -eq 'pass') { $cntPassRecord += 1 }
        if ($markTestMessagesSuppressed -and ([string]$item.level).ToLowerInvariant() -ne 'debug') {
          $item | Add-Member -NotePropertyName Suppressed -NotePropertyValue $true -Force
        }
        Write-Output $item
      }
      elseif ($item -is [string]) {
        $parts = Convert-TextToLogRecord $item
        $cntImproperRecord += 1
        Log-Debug $parts.Message -Comment $parts.Comment
      }
      else {
        $cntImproperRecord += 1
        $objType = $item.GetType().FullName
        $objText = ($item | Out-String).Trim()
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
  }
  catch {
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
      }
      catch { Log-Debug "Program Error: Failed to fetch the actual source line" }
    }

    # Build a helpful message with graceful fallbacks
    $baseMsg = Get-LeftString $err.Exception.GetBaseException().Message 500
    $outerLine = $inv.ScriptLineNumber
    $outerCode = $inv.Line

    $details =
    if ($innerLine -and $innerFunc) {
      "Throw site: $innerFunc" +
      ($(if ($innerFile) { "`nFile: $innerFile" } else { "" })) +
      "`nLine: $innerLine" +
      ($(if ($innerCode) { "`n  #       Code: $innerCode" } else { "" }))
    }
    else {
      # Fallback to the catcher's position info
      "Throw site unknown from stack; fallback to caller:`n  #       Line #$($outerLine): $outerCode"
    }

    Log-Failure "(Program Error) Exception while running '$FunctionName'" `
      -Comment "details: $baseMsg`n$details`nA Program Error during a test means either that the test failed or that its code has a bug." `
      -Emitter $(if ($innerFunc) { $innerFunc } else { $FunctionName })
  }
  finally {
    $sw.Stop()
    $ErrorActionPreference = $oldEap
    Write-Progress -Activity "Starting test $FunctionName" -Completed
  }

  Log-debug "Done with test $FunctionName in $([int]$sw.ElapsedMilliseconds) ms"
}

function Get-HealthTest($allHealthTests) {
  <#
.SYNOPSIS
Lists all loaded HealthTest-* functions with their description text.
#>
  [CmdletBinding()]
  [OutputType([pscustomobject])]

  $allHealthTests | ForEach-Object {
    $definition = $_.Definition
    $description = $null

    if ($definition) {
      $match = [regex]::Match($definition, '(?im)^\s*Description:\s*(.+?)\s*$')
      if ($match.Success) {
        $description = $match.Groups[1].Value.Trim()
      }
    }

    [pscustomobject]@{
      Name        = $_.Name
      Description = $description
    }
  }
}

function Invoke-HealthTestsFromFolder {
  [CmdletBinding()]
  param([Parameter(Mandatory = $true, Position = 0)][string]$FolderPath)

  $resolved = $null
  try { $resolved = (Resolve-Path -LiteralPath $FolderPath -ErrorAction Stop).Path }
  catch {
    Log-debug "Path -IncludeTestsFromFolder $FolderPath was not found"
    return
  }

  if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
    if ($resolved -like "*.ps1") {
      $files = @($resolved)
    }
    else {
      Log-debug "Path -IncludeTestsFromFolder $FolderPath was ignored because it's neither a folder nor a ps1 script"
      return
    }
  }
  else {
    $files = @(Get-ChildItem -LiteralPath $resolved -Filter *.ps1 -File -ErrorAction SilentlyContinue)
  }

  $fileImported = $false
  foreach ($f in $files) {
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

      foreach ($fn in $allCustomTests) {
        $existing = Get-Item -Path ("Function:\{0}" -f $fn.Name) -ErrorAction SilentlyContinue
        try {
          Set-Item -Path ("Function:\{0}" -f $fn.Name) -Value $fn.ScriptBlock -Force
          Invoke-HealthTestWithPolicyAutoset $fn.Name
        }
        finally {
          if ($existing) {
            Set-Item -Path ("Function:\{0}" -f $fn.Name) -Value $existing.ScriptBlock -Force
          }
          else {
            Remove-Item -Path ("Function:\{0}" -f $fn.Name) -ErrorAction SilentlyContinue
          }
        }
      }
    }
    catch {
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
    }
    finally {
      if ($m) {
        Remove-Module -ModuleInfo $m -Force -ErrorAction SilentlyContinue
      }
    }
  }
  if (!$fileImported) { return }

  log-info "Invoke-HealthTestsFromFolder imported at least one file with HealthTest-* functions."
}

function Write-UsageHelp {
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost', '',
    Justification = 'Only triggered by interactive use.'
  )]
  param()

  Write-Host -ForegroundColor Cyan  "$((Split-Path $PSCommandPath -Leaf) -replace '.ps1') version $VERSION, Nick Demou, enLogic"
  Write-Host -ForegroundColor Gray  ""
  Write-Host -ForegroundColor Gray  "Most often you want to use me like this:"
  Write-Host -ForegroundColor White "    `$out = $PSCommandPath -OutputConsoleMessages -Hide " -NoNewline
  Write-Host -ForegroundColor DarkCyan "DIP"
  Write-Host -ForegroundColor Gray  "          # (-Hide DIP means: hide Debug, Informational and Pass messages)"
  Write-Host -ForegroundColor White "    `$out | ogv # or similar"
  Write-Host -ForegroundColor Gray  ""
  return
}

function Write-DummyHealthTest {
  # Useful only for code testing.
  Write-Output "Dummy debug message"
  Write-Warning "[info] Dummy info message"
  Write-Warning "[PASS] Dummy pass message"
  Write-Warning "[NOTICE] Dummy notice message"
  Write-Warning ("[WARNING] Dummy warning message" + "`n" + "This one has a comment(details) also")
  Write-Warning ("[FAILURE] Dummy failure message" + "`n" + "This one has a comment(details) also`nWith 2 lines of text!")
}

function Get-HealthTestTagsMetadata {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$FunctionName
  )

  $normalizedTestName = $FunctionName -replace '^HealthTest-', ''
  $tags = @()
  $isSlowTest = $false

  $cmd = Get-Command -Name $FunctionName -CommandType Function -ErrorAction SilentlyContinue
  $definition = if ($cmd) { [string]$cmd.Definition } else { '' }

  $tagsLine = $null
  $impactLine = $null
  if ($definition) {
    $tagMatch = [regex]::Match($definition, '(?im)^\s*Tags:\s*(.+?)\s*$')
    if ($tagMatch.Success) {
      $tagsLine = $tagMatch.Groups[1].Value.Trim()
    }
    $impactMatch = [regex]::Match($definition, '(?im)^\s*Impact:\s*(.+?)\s*$')
    if ($impactMatch.Success) {
      $impactLine = $impactMatch.Groups[1].Value.Trim()
    }
  }

  if ($tagsLine) {
    $tags = @(
      $tagsLine -split '[,;]' |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ } |
      Sort-Object -Unique
    )
  }

  if ($impactLine) {
    $impactTerms = @(
      $impactLine -split '[,;]' |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ }
    )

    foreach ($impactTerm in $impactTerms) {
      if ($impactTerm -match '(?i)^(?<Left>[A-Za-z]+)\s*\(\s*(?<Right>[A-Za-z]+)\s*\)$') {
        $left = $matches['Left'].ToLowerInvariant()
        $right = $matches['Right'].ToLowerInvariant()

        if ((($left -eq 'high') -and ($right -eq 'time')) -or (($left -eq 'time') -and ($right -eq 'high'))) {
          $isSlowTest = $true
          break
        }
      }
    }
  }

  [pscustomobject]@{
    FunctionName         = $FunctionName
    TestName             = $normalizedTestName
    Tags                 = @($tags)
    IsSlowTest           = $isSlowTest
    IsPolicyTest         = ('Policy' -in $tags)
    IsSuppressedTest     = ('Suppressed' -in $tags)
    IsQuickEssentialTest = ('Essential' -in $tags)
  }
}

function Test-PolicyAutosetAlreadyPerformed {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$PolicyTestName,
    [Parameter(Mandatory)][string]$SuppressionFilePath
  )

  if (-not (Test-Path -LiteralPath $SuppressionFilePath)) { return $false }
  $marker = "POLICY_TEST_WAS_RUN: $PolicyTestName"
  foreach ($line in (Get-Content -LiteralPath $SuppressionFilePath -ErrorAction SilentlyContinue)) {
    if ($line -and ($line.Trim() -eq $marker)) { return $true }
  }
  return $false
}

function Invoke-HealthTestWithPolicyAutoset {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$FunctionName
  )

  $meta = Get-HealthTestTagsMetadata -FunctionName $FunctionName
  if ($SkipSlowTests -and $meta.IsSlowTest) {
    Log-Info "Skipping slow test $FunctionName because of -SkipSlowTests switch"
    return
  }
  if ($SkipPolicyTests -and $meta.IsPolicyTest) {
    Log-Info "Skipping policy test $FunctionName because of -SkipPolicyTests switch"
    return
  }
  if ($SkipNonEssentialTests -and (-not $meta.IsQuickEssentialTest)) {
    Log-Info "Skipping non-essential test $FunctionName because of -SkipNonEssentialTests (-Quick) switch"
    return
  }
  $isPolicyTest = $meta.IsPolicyTest
  $policyTestName = $meta.TestName
  $shouldAutoset = $isPolicyTest -and (-not $DontAutosetPolicy) -and `
  (-not (Test-PolicyAutosetAlreadyPerformed -PolicyTestName $policyTestName -SuppressionFilePath $script:Config.SuppressSignaturesPath))

  $records = @(Invoke-HealthTest $FunctionName)

  if ($shouldAutoset) {
    $policyFindings = @(
      $records |
      Where-Object { $_.Level -in @('notice', 'warning') -and (-not $_.Suppressed) -and ($_.Hash -match '^[0-9a-f]{8}$') }
    )

    $newSuppressionSigs = @($policyFindings | Select-Object -ExpandProperty Hash -Unique)
    $sigToMessage = @{}
    foreach ($finding in $policyFindings) {
      if (-not $sigToMessage.ContainsKey($finding.Hash)) {
        $sigToMessage[$finding.Hash] = [string]$finding.Message
      }
    }

    foreach ($sig in $newSuppressionSigs) {
      $findingMessage = $sigToMessage[$sig]
      $line = "$sig # $(Get-Date -format yyyy-MM-dd` HH:mm) # policy auto-baseline from $($meta.TestName): $findingMessage"
      Add-AsciiLine -Line $line -Path $script:Config.SuppressSignaturesPath
    }
    if ($newSuppressionSigs.Count -gt 0) {
      Add-LogSuppressedSignatures -Signatures $newSuppressionSigs
      Log-Info "Auto-suppressed $($newSuppressionSigs.Count) policy findings for first run of $($meta.FunctionName)."
    }
    else {
      Log-Info "No policy findings to auto-suppress during first run of $($meta.FunctionName)."
    }

    Add-AsciiLine -Line "POLICY_TEST_WAS_RUN: $policyTestName" -Path $script:Config.SuppressSignaturesPath
  }

  $records
}

function Convert-TextToLogRecord {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Text)

  $normalized = ($Text -replace "`r", '')
  $lines = @($normalized -split "`n")
  if (-not $lines -or ($lines.Count -eq 1 -and [string]::IsNullOrWhiteSpace($lines[0]))) {
    return [pscustomobject]@{ Message = ''; Comment = '' }
  }

  $msg = [string]$lines[0]
  $comment = ''
  if ($lines.Count -gt 1) {
    $comment = ($lines | Select-Object -Skip 1) -join "`n"
  }

  [pscustomobject]@{ Message = $msg.Trim(); Comment = $comment.Trim() }
}

function Convert-WarningLikeObjectToLogRecord {
  [CmdletBinding()]
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) { return $null }

  $rawText = if ($Value -is [System.Management.Automation.WarningRecord]) {
    [string]$Value.Message
  }
  else {
    [string]$Value
  }

  $parts = Convert-TextToLogRecord -Text $rawText
  $level = 'warning'
  $msg = $parts.Message
  $comment = $parts.Comment

  if ($parts.Message -match '^\s*\[([a-z]+)\]\s*(.*)$') {
    $candidate = $matches[1].ToLowerInvariant()
    if ($candidate -in @('debug', 'pass', 'info', 'notice', 'warning', 'failure')) {
      $level = $candidate
      $msg = [string]$matches[2]
    }
  }

  if ([string]::IsNullOrWhiteSpace($msg)) { $msg = '<empty warning message>' }
  [pscustomobject]@{
    Level   = $level
    Msg     = $msg.Trim()
    Comment = $comment
  }
}

function Invoke-PrettifyWriteWarningMode {
  [CmdletBinding()]
  param([AllowNull()][object[]]$Values)

  Initialize-LogSystem `
    -OutputConsoleMessages $true `
    -HideStr '' `
    -SuppressionFilePath $script:Config.SuppressSignaturesPath `
    -AdditionalSuppressedSignatures @()

  foreach ($item in @($Values)) {
    $record = Convert-WarningLikeObjectToLogRecord -Value $item
    if ($null -eq $record) { continue }
    Log-Msg -Level $record.Level -Msg $record.Msg -Comment $record.Comment
  }
}

#=============================================================================
#
# MAIN CODE
#
#=============================================================================

# This is only helpful during debuging
# (Built-in test files are dot-sourced into the current session, and then tests
# are discovered with a broad Get-Command -Name 'HealthTest-*' . That allows 
# previously loaded functions in the same shell to be picked up. 
# With this command we remove all HealthTest-* functions)
Get-ChildItem Function:\HealthTest-*, Function:\Global:HealthTest-* -ErrorAction SilentlyContinue |
Remove-Item -Force -ErrorAction SilentlyContinue

if ($PrettifyWriteWarning) {
  $allValues = if ($PSBoundParameters.ContainsKey('InputObject')) {
    @($InputObject)
  }
  else {
    @($input)
  }
  Invoke-PrettifyWriteWarningMode -Values $allValues
  return
}

if ($ListAllBuiltInTests) {
  Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'health-tests') -Filter *.ps1 -File |
  Sort-Object Name |
  ForEach-Object { . $_.FullName }

  $allHealthTests = Get-Command -CommandType Function -Name 'HealthTest-*' -ErrorAction SilentlyContinue
  Get-HealthTest $allHealthTests
  return
}

#+-----------------------------------------------------------
#| Collect system information
#|

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
$isHostVM = Test-IsVirtualMachine
$isHostMobile = Test-IsLaptopOrMobile
$isHostDomainJoined = ($domainRole -in 1, 3, 4, 5)
$isHostServer = ($domainRole -in 3, 4, 5)
$isHostDC = ($domainRole -in 4, 5)
$isHostDnsServer = $null -ne (Get-Service -Name DNS -ErrorAction SilentlyContinue)
$isHostDHCPServer = ($isHostServer -and (Get-WindowsFeature DHCP -ErrorAction SilentlyContinue).InstallState -eq 'Installed')
if (-not $RunWithoutElevation) {
  $isHostHyperisor = (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V).State -eq 'Enabled'
}
else {
  $isHostHyperisor = $false
}
$isHostInDomainButNotDC = (Get-CimInstance Win32_ComputerSystem).DomainRole -in 1, 3
$isHostPDC = $false
$currentDomain = $null
if ($isHostDC) {
  $isHostPDC = $false
  $domainInfo = $null
  try {
    $domainInfo = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
    $currentDomain = $domainInfo
    $isHostPDC = (($domainInfo.PdcRoleOwner.Name -replace '[.].*') -eq $env:COMPUTERNAME)
  }
  catch {
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
  }
  else {
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

# Explicitly created so host-fact values are publicly accessible to all health tests,
# including custom health tests loaded at runtime.
$Global:GCHDQMTA = [pscustomobject]@{
  isHostVM               = $isHostVM
  isHostMobile           = $isHostMobile
  isHostDomainJoined     = $isHostDomainJoined
  isHostServer           = $isHostServer
  isHostDC               = $isHostDC
  isHostPDC              = $isHostPDC
  isHostDnsServer        = $isHostDnsServer
  isHostDHCPServer       = $isHostDHCPServer
  isHostHyperisor        = $isHostHyperisor
  isHostInDomainButNotDC = $isHostInDomainButNotDC
  GetCurrentDomain       = $currentDomain
  SkipSlowTests          = $SkipSlowTests
  IpsOfAllDcs            = @($validIpsOfAllDcs)
}

#|
#| Collect system information
#+-----------------------------------------------------------

#+-----------------------------------------------------------
#| Dot source health tests
#|

. (Join-Path -Path $PSScriptRoot -ChildPath "health-tests\syscfg-featdisc.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "health-tests\srvc-exe-resolve.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "health-tests\file-dir-anlz.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "health-tests\schtasks-master.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "health-tests\net-conn.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "health-tests\os-perf-hw.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "health-tests\win-os-hyg.ps1")

if ($isHostDC -or $isHostPDC) { . (Join-Path -Path $PSScriptRoot -ChildPath "health-tests\DC-PDC.ps1") }
if ($isHostDnsServer) { . (Join-Path -Path $PSScriptRoot -ChildPath "health-tests\DNS.ps1") }
if ($isHostDHCPServer) { . (Join-Path -Path $PSScriptRoot -ChildPath "health-tests\DHCP.ps1") }
if ($isHostDomainJoined) { . (Join-Path -Path $PSScriptRoot -ChildPath "health-tests\domjoined.ps1") }
if ($isHostInDomainButNotDC) { . (Join-Path -Path $PSScriptRoot -ChildPath "health-tests\member.ps1") }
if ($isHostMobile) { . (Join-Path -Path $PSScriptRoot -ChildPath "health-tests\mobile.ps1") }
if ($isHostHyperisor) { . (Join-Path -Path $PSScriptRoot -ChildPath "health-tests\hypervisor.ps1") }
if ($isHostServer) { . (Join-Path -Path $PSScriptRoot -ChildPath "health-tests\servers.ps1") }
#|
#| Dot source health tests
#+-----------------------------------------------------------

$allHealthTests = Get-Command -CommandType Function -Name 'HealthTest-*' -ErrorAction SilentlyContinue

if ($ListAllBuiltInTests) { Get-HealthTest $allHealthTests; return }

# Fail if not run as Administrator (elevated)
# None of the functionality that follows is available to non-admins
if ((-not $RunWithoutElevation) -and (-not ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent() `
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
  Write-Error "This script must be run as Administrator (elevated)."
  exit 1
}

if ($AddWhitelisting ) {
  if (-not $Signature) { throw "You must supply a -Signature" }
  if (-not $ComputerName) { throw "You must supply a -ComputerName" }
  if ($Signature -notmatch '^[0-9A-Fa-f]{8}$') {
    throw "Invalid -Signature: $Signature"
  }
  if ($ComputerName -ne $env:COMPUTERNAME) {
    throw "Running on $($env:COMPUTERNAME) but suppression is for $ComputerName"
  }
  if ($Until) {
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $dt = [datetime]::MinValue
    $ok = [DateTime]::TryParseExact($Until, 'yyyy-MM-dd', $culture, [System.Globalization.DateTimeStyles]::None, [ref]$dt)
    if (-not $ok) { $ok = [DateTime]::TryParse($Until, [System.IFormatProvider]$culture, [System.Globalization.DateTimeStyles]::None, [ref]$dt) }
    if (-not $ok) { throw "Invalid date: `$Until" }
    $line = '{0} UNTIL {1:yyyy-MM-dd} # {2:yyyy-MM-dd HH:mm} # {3}' -f $Signature, $dt, (Get-Date), $Comment
    Add-AsciiLine -Line $line -Path $script:Config.SuppressSignaturesPath
  }
  else {
    $line = "$Signature # $(Get-Date -format yyyy-MM-dd` HH:mm) # $Comment"
    Add-AsciiLine -Line $line -Path $script:Config.SuppressSignaturesPath
  }
  return
}


if ($DoNothing) { return }

if ($isHostDomainJoined -and $validIpsOfAllDcs.Count -eq 0) {
  Log-failure "Cannot run many domain-related tests because no valid IPv4 addresses were provided in -IpsOfAllDcs. Marking this host as non-domain for test applicability."
  $isHostDomainJoined = $false
  $isHostDC = $false
  $isHostPDC = $false
  $currentDomain = $null
}

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
Log-Debug "`$global:GCHDQMTA" -Comment "$(($global:GCHDQMTA|Format-List|Out-String).trim())"
Log-Debug '$allHealthTests' -comment "$(($allHealthTests).name -join ', ')"

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
Log-Debug "-SkipNonEssentialTests '$SkipNonEssentialTests'"
Log-Debug "-WhitelistSigs '$WhitelistSigs'"
$cfg = Get-LogConfig
Log-debug "Final list of suppressed signatures: $((@($cfg.SuppressedSignatures) | Sort-Object -Unique) -join ', ')"

#=============================================================================
#
# START OF TESTS
#
#=============================================================================

if ($OnlyTheseTests) {
  # -OnlyTheseTests
  $valid_cmdlet_name_regex = '^ *[A-Za-z][A-Za-z0-9_-]*[A-Za-z0-9]+ *$'
  $loadedTestsByName = @{}
  $loadedTestsByBaseName = @{}
  $loadedTestsByShortName = @{}
  $allHealthTests | ForEach-Object {
    $loadedTestsByName[$_.Name] = $_.Name
    $meta = Get-HealthTestTagsMetadata -FunctionName $_.Name
    $baseName = "HealthTest-$($meta.TestName)"
    if (-not $loadedTestsByBaseName.ContainsKey($baseName)) {
      $loadedTestsByBaseName[$baseName] = $_.Name
    }
    if (-not $loadedTestsByShortName.ContainsKey($meta.TestName)) {
      $loadedTestsByShortName[$meta.TestName] = $_.Name
    }
  }

  foreach ($item in $OnlyTheseTests) {
    if ($item -match $valid_cmdlet_name_regex) {
      $testName = $item.Trim()
      if ($loadedTestsByName.ContainsKey($testName)) {
        Invoke-HealthTestWithPolicyAutoset $loadedTestsByName[$testName]
      }
      elseif ($loadedTestsByBaseName.ContainsKey($testName)) {
        Invoke-HealthTestWithPolicyAutoset $loadedTestsByBaseName[$testName]
      }
      elseif ($loadedTestsByShortName.ContainsKey($testName)) {
        Invoke-HealthTestWithPolicyAutoset $loadedTestsByShortName[$testName]
      }
      else {
        Log-Notice "Skipping unavailable test '$testName' (not loaded/applicable on this host)."
      }
    }
    else {
      Log-Warning "Input '$item' is not a valid cmdlet name."
    }
  }
  return
}
else {
  # All tests
  foreach ($fn in $allHealthTests) {
    Invoke-HealthTestWithPolicyAutoset $fn.Name
  }
}

if ($IncludeTestsFromFolder) {
  # Also Custom HealthTest-*
  Invoke-HealthTestsFromFolder $IncludeTestsFromFolder
}
