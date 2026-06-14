<#
.SYNOPSIS
Runs a suite of built-in and optional custom "HealthTest-*" checks and reports their findings; can also whitelist/suppress expected messages by signature.

.DESCRIPTION
Executes many health-test functions (named `HealthTest-*`) and emits their results either as structured objects (`-OutputObjects`) and/or as colorized console messages (`-OutputConsoleMessages`), with optional filtering via `-Hide`.

Supports:
- Listing available built-in tests (`-ListAllBuiltInTests`).
- Running only selected tests (`-OnlyTheseTests`) and/or skipping specific tests (`-ExcludeTests`).
- Running custom tests by executing `.ps1` files directly. `-IncludeTestsFromFolder` remains as a deprecated compatibility parameter that selects which custom scripts to run.
- Suppressing expected notices/warnings/failures by 8-hex "signature" hashes, either temporarily for the current run (`-WhitelistSigs`) or by appending a permanent suppression entry (`-AddWhitelisting`) to a suppression file.
- Requiring specific findings from selected tests. If a required signature is not emitted when that test runs, a failure is emitted. Required findings are stored in `.\config\required_findings.psd1` and can be updated with `-SetAsRequired`.


When `-OutputObjects` is used, each emitted log object includes these fields:
- `TimeUtc` (UTC timestamp for the message; intended for cross-machine sorting/aggregation and report export as UTC)
- `Computer`, `Level`, `Message`, `Hash`, `Suppressed`, `Comment`, `Emitter`

Notable side effects:
- When custom tests are selected, the `.ps1` files are executed directly.
- The health tests themselves may perform read/write operations depending on their implementation (this script invokes them; it does not enforce read-only behavior).

Idempotency:
- `-AddWhitelisting` is append-only (not strictly idempotent): repeated runs add additional lines; last matching line "wins" when loading suppressions.
- `-SetAsRequired` updates or creates a single required-finding entry for the specified test/signature pair.

Dependencies & execution context:
- Requires elevation.
- Relies on companion scripts: `lib-write-log-objects.ps1`, `helpers-for-healthtests.ps1`, and the modules under `health-tests\*.ps1` dot-sourced below.
- Uses a suppression config file at `.\config\Get-ComputerHealth.sigs-to-suppress.txt`.
- Uses a required-findings config file at `.\config\required_findings.psd1`.

.PARAMETER RunWithoutElevation
(Parameter sets: Run, AddWhitelist, SetRequired, List) Bypasses the normal elevation requirement. Default behavior still requires running as Administrator.

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
(Parameter set: Run) One or more built-in function names and/or custom `.ps1` script names/paths to execute (treated as a list; values may be space/comma separated). When provided, only these tests are invoked.

.PARAMETER ExcludeTests
(Parameter set: Run) One or more function names to skip (treated as a list; values may be space/comma separated).

.PARAMETER IncludeTestsFromFolder
(Parameter set: Run) Deprecated compatibility parameter. Path to a folder containing custom `.ps1` scripts (or a single `.ps1` path). Matching files are executed directly.

.PARAMETER SkipSlowTests
(Parameter set: Run) Skips health tests that have high time impact (`Impact: ... High(Time)` in their help block).

.PARAMETER DebugSkipSlowTests
(Parameter set: Run) Alias for `-SkipSlowTests` (kept for backward compatibility).

.PARAMETER SkipPolicyTests
(Parameter set: Run) Skips health tests tagged as policy inventory tests (`Tags: Policy` in their help block), such as `HealthTest-InstalledSW`.

.PARAMETER DontAutosetPolicy
(Parameter set: Run) Disables first-run auto-baselining for policy tests (`Tags: Policy`, e.g. `HealthTest-InstalledSW`). By default, first run auto-suppresses emitted `[NOTICE]`/`[WARNING]` findings for each policy test and records a marker in the suppression file.

.PARAMETER IpsOfAllDcs
(Parameter set: Run) Optional list of Domain Controller IP addresses passed in by the orchestrator. Stored in `$Global:GchData.IpsOfAllDcs` for health tests that need it.

.PARAMETER DoNothing
(Parameter set: Run) Immediate no-op return (useful for smoke-testing invocation/parameter binding).

.PARAMETER AddWhitelisting
(Parameter set: AddWhitelist) Appends a suppression entry for a specific signature to the suppression file and exits (does not run health tests).

.PARAMETER SetAsRequired
(Parameter set: SetRequired) Adds or updates a required-finding entry in `.\config\required_findings.psd1` and exits (does not run health tests).

.PARAMETER ComputerName
(Parameter sets: AddWhitelist, SetRequired; Mandatory) Target computer name for the change. Must match the current computer `$env:COMPUTERNAME`.

.PARAMETER Signature
(Parameter sets: AddWhitelist, SetRequired; Mandatory) 8-hex signature to suppress or require (case-insensitive). Alias: `-Sig`.

.PARAMETER Test
(Parameter set: SetRequired; Mandatory) Health test name that must emit the required signature. You can use the short test name (for example `UnexpectedListeningPorts`) or the full function name (`HealthTest-UnexpectedListeningPorts`).

.PARAMETER Comment
(Parameter sets: AddWhitelist, SetRequired) Optional free text. For `-AddWhitelisting`, it is appended to the suppression line (non-ASCII characters are replaced with `?`). For `-SetAsRequired`, it becomes the stored description and the emitted failure message when the required signature is missing.

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

.EXAMPLE
# Mark a finding as required for a health test on this computer:
.\Get-ComputerHealth.ps1 -SetAsRequired -ComputerName CONTOSO-SRV01 -Test UnexpectedListeningPorts -Signature bfc162fa -Comment "Port 443(IIS) should be listening but is not"

.NOTES
- Elevation is enforced for normal runs, whitelisting operations, and required-finding updates.
- `-RunWithoutElevation` bypasses the elevation guard; some health tests may still fail or produce incomplete results when run non-elevated.
- Permanent suppression file: `.\config\Get-ComputerHealth.sigs-to-suppress.txt`.
- Required findings file: `.\config\required_findings.psd1`.
- Custom tests: scripts may execute arbitrary code when run.
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
  [ValidatePattern('(?i)^[DIPNWFSC]*$')]
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
  [Parameter(ParameterSetName = 'SetRequired')]
  [Parameter(ParameterSetName = 'List')]
  [switch]$RunWithoutElevation,

  # ----------------------------
  # Add whitelisting entry
  # ----------------------------
  [Parameter(ParameterSetName = 'AddWhitelist', Mandatory)]
  [switch]$AddWhitelisting,

  [Parameter(ParameterSetName = 'SetRequired', Mandatory)]
  [switch]$SetAsRequired,

  [Parameter(ParameterSetName = 'AddWhitelist', Mandatory)]
  [Parameter(ParameterSetName = 'SetRequired', Mandatory)]
  [ValidateNotNullOrEmpty()]
  [string]$ComputerName,

  [Parameter(ParameterSetName = 'AddWhitelist', Mandatory)]
  [Parameter(ParameterSetName = 'SetRequired', Mandatory)]
  [Alias('Sig')]
  [ValidatePattern('^[0-9A-Fa-f]{8}$')]
  [string]$Signature,

  [Parameter(ParameterSetName = 'AddWhitelist')]
  [Parameter(ParameterSetName = 'SetRequired')]
  [string]$Comment,

  [Parameter(ParameterSetName = 'AddWhitelist')]
  [ValidatePattern('^\d{4}-\d{2}-\d{2}$')]
  [string]$Until,

  [Parameter(ParameterSetName = 'SetRequired', Mandatory)]
  [ValidateNotNullOrEmpty()]
  [string]$Test,

  # ----------------------------
  # List tests
  # ----------------------------
  [Parameter(ParameterSetName = 'List', Mandatory)]
  [switch]$ListAllBuiltInTests
)

$VERSION="8.5.7"

if ($null -ne $Hide) {
  $Hide = ([string]$Hide).ToUpperInvariant()
}


$SCRIPT_BIN_DIR = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$ROOT_DIR = Split-Path -Parent $SCRIPT_BIN_DIR
$CONFIG_DIR = Join-Path $ROOT_DIR 'config'

#------------------------------------------
# Configuration
#

$script:Config = [pscustomobject]@{
  SuppressSignaturesPath = Join-Path $CONFIG_DIR 'Get-ComputerHealth.sigs-to-suppress.txt'
  RequiredFindingsPath = Join-Path $CONFIG_DIR 'required_findings.psd1'
  DefaultCustomTestsPath = Join-Path $CONFIG_DIR 'Custom-HealthTests'
}

#------------------------------------------
# Dot source libraries of functions
#
. (Join-Path -Path $PSScriptRoot -ChildPath "lib-write-log-objects.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "helpers-for-healthtests.ps1")

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

function Get-RequiredFindingConfigKeys {
  [CmdletBinding()]
  param($Config)

  if ($null -eq $Config) {
    return @()
  }

  if ($Config -is [System.Collections.IDictionary]) {
    return @($Config.Keys)
  }

  return @($Config.PSObject.Properties.Name)
}

function Test-RequiredFindingConfigKey {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Config,
    [Parameter(Mandatory)][string]$Key
  )

  if ($Config -is [System.Collections.IDictionary]) {
    return $Config.Contains($Key)
  }

  return ($Config.PSObject.Properties[$Key] -ne $null)
}

function Get-RequiredFindingConfigValue {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Config,
    [Parameter(Mandatory)][string]$Key
  )

  if ($Config -is [System.Collections.IDictionary]) {
    return $Config[$Key]
  }

  return $Config.$Key
}

function Normalize-RequiredFindingTestName {
  [CmdletBinding()]
  param(
    [AllowEmptyString()][string]$TestName
  )

  $normalized = [string]$TestName
  if ([string]::IsNullOrWhiteSpace($normalized)) {
    return ''
  }

  $normalized = $normalized.Trim()
  if ($normalized -match '^(?i)HealthTest-(.+)$') {
    $normalized = $Matches[1]
  }

  return $normalized.Trim()
}

function Convert-RequiredFindingEntryToHashtable {
  [CmdletBinding()]
  param(
    $Entry
  )

  $description = ''
  if (($null -ne $Entry) -and (Test-RequiredFindingConfigKey -Config $Entry -Key 'Description')) {
    $description = [string](Get-RequiredFindingConfigValue -Config $Entry -Key 'Description')
  }

  $timestamp = $null
  if (($null -ne $Entry) -and (Test-RequiredFindingConfigKey -Config $Entry -Key 'Ts')) {
    $timestampValue = Get-RequiredFindingConfigValue -Config $Entry -Key 'Ts'
    if ($timestampValue -is [datetime]) {
      $timestamp = [datetime]$timestampValue
    }
    elseif ($null -ne $timestampValue) {
      $parsedTimestamp = [datetime]::MinValue
      if ([datetime]::TryParse([string]$timestampValue, [ref]$parsedTimestamp)) {
        $timestamp = $parsedTimestamp
      }
    }
  }

  $user = ''
  if (($null -ne $Entry) -and (Test-RequiredFindingConfigKey -Config $Entry -Key 'User')) {
    $user = [string](Get-RequiredFindingConfigValue -Config $Entry -Key 'User')
  }

  return [ordered]@{
    Description = $description
    Ts = $timestamp
    User = $user
  }
}

function Read-RequiredFindingsConfig {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return [ordered]@{}
  }

  try {
    $rawText = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $scriptBlock = [scriptblock]::Create($rawText)
    $rawConfig = & $scriptBlock
  }
  catch {
    throw "Failed reading required findings configuration file '$Path': $($_.Exception.Message)"
  }

  $config = [ordered]@{}
  foreach ($testKey in @(Get-RequiredFindingConfigKeys -Config $rawConfig | Sort-Object)) {
    $normalizedTestName = Normalize-RequiredFindingTestName -TestName ([string]$testKey)
    if ([string]::IsNullOrWhiteSpace($normalizedTestName)) {
      continue
    }

    $rawTestFindings = Get-RequiredFindingConfigValue -Config $rawConfig -Key $testKey
    $testFindings = [ordered]@{}

    foreach ($signatureKey in @(Get-RequiredFindingConfigKeys -Config $rawTestFindings | Sort-Object)) {
      $signatureText = ([string]$signatureKey).Trim().ToLowerInvariant()
      if ($signatureText -notmatch '^[0-9a-f]{8}$') {
        throw "Invalid required finding signature '$signatureKey' in '$Path' for test '$normalizedTestName'."
      }

      $rawEntry = Get-RequiredFindingConfigValue -Config $rawTestFindings -Key $signatureKey
      $testFindings[$signatureText] = Convert-RequiredFindingEntryToHashtable -Entry $rawEntry
    }

    if ($testFindings.Count -gt 0) {
      $config[$normalizedTestName] = $testFindings
    }
  }

  return $config
}

function ConvertTo-RequiredFindingsPowerShellString {
  [CmdletBinding()]
  param(
    [AllowNull()][string]$Text
  )

  $value = [string]$Text
  return ("'" + ($value -replace "'", "''") + "'")
}

function Save-RequiredFindingsConfig {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)]$RequiredFindings
  )

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('@{') | Out-Null

  foreach ($testName in @(Get-RequiredFindingConfigKeys -Config $RequiredFindings | Sort-Object)) {
    $testFindings = Get-RequiredFindingConfigValue -Config $RequiredFindings -Key $testName
    $lines.Add(("    {0} = @{{" -f (ConvertTo-RequiredFindingsPowerShellString -Text ([string]$testName)))) | Out-Null

    foreach ($signature in @(Get-RequiredFindingConfigKeys -Config $testFindings | Sort-Object)) {
      $entry = Convert-RequiredFindingEntryToHashtable -Entry (Get-RequiredFindingConfigValue -Config $testFindings -Key $signature)
      $timestamp = $entry.Ts
      if ($null -eq $timestamp) {
        $timestamp = Get-Date
      }

      $lines.Add((
          "        {0} = @{{Description = {1}; Ts = [datetime]{2}; User = {3}}};" -f
          (ConvertTo-RequiredFindingsPowerShellString -Text ([string]$signature).ToLowerInvariant()),
          (ConvertTo-RequiredFindingsPowerShellString -Text $entry.Description),
          (ConvertTo-RequiredFindingsPowerShellString -Text ($timestamp.ToString('yyyy-MM-dd HH:mm'))),
          (ConvertTo-RequiredFindingsPowerShellString -Text $entry.User)
        )) | Out-Null
    }

    $lines.Add('    };') | Out-Null
  }

  $lines.Add('}') | Out-Null

  $parentDir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($parentDir) -and (-not (Test-Path -LiteralPath $parentDir -PathType Container))) {
    New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
  }

  Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
}

function Set-RequiredFindingEntry {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$TestName,
    [Parameter(Mandatory)][string]$Signature,
    [string]$Description,
    [datetime]$Timestamp = (Get-Date),
    [string]$User = $(
      try {
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
      }
      catch {
        [string]$env:USERNAME
      }
    )
  )

  $normalizedTestName = Normalize-RequiredFindingTestName -TestName $TestName
  if ([string]::IsNullOrWhiteSpace($normalizedTestName)) {
    throw "You must supply a -Test"
  }

  $normalizedSignature = ([string]$Signature).Trim().ToLowerInvariant()
  if ($normalizedSignature -notmatch '^[0-9a-f]{8}$') {
    throw "Invalid -Signature: $Signature"
  }

  $config = Read-RequiredFindingsConfig -Path $Path
  if (-not (Test-RequiredFindingConfigKey -Config $config -Key $normalizedTestName)) {
    $config[$normalizedTestName] = [ordered]@{}
  }

  if (Test-RequiredFindingConfigKey -Config $config[$normalizedTestName] -Key $normalizedSignature) {
    $existingEntry = Convert-RequiredFindingEntryToHashtable -Entry $config[$normalizedTestName][$normalizedSignature]
    if ([string]$existingEntry.Description -ceq [string]$Description) {
      return
    }
  }

  $config[$normalizedTestName][$normalizedSignature] = [ordered]@{
    Description = [string]$Description
    Ts = $Timestamp
    User = [string]$User
  }

  Save-RequiredFindingsConfig -Path $Path -RequiredFindings $config
}

function Get-RequiredFindingsForTest {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$RequiredFindings,
    [Parameter(Mandatory)][string]$FunctionName
  )

  $shortName = Normalize-RequiredFindingTestName -TestName $FunctionName
  $keysToTry = @($FunctionName, "HealthTest-$shortName", $shortName)

  foreach ($key in $keysToTry) {
    if ([string]::IsNullOrWhiteSpace($key)) {
      continue
    }

    if (Test-RequiredFindingConfigKey -Config $RequiredFindings -Key $key) {
      return (Get-RequiredFindingConfigValue -Config $RequiredFindings -Key $key)
    }
  }

  return $null
}

function Get-MissingRequiredFindings {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object[]]$Records,
    [Parameter(Mandatory)]$RequiredFindingsForTest
  )

  $emittedSignatures = @(
    $Records |
      Where-Object { $_ -and $_.PSObject.Properties['Hash'] } |
      ForEach-Object { ([string]$_.Hash).Trim().ToLowerInvariant() } |
      Where-Object { $_ -match '^[0-9a-f]{8}$' } |
      Sort-Object -Unique
  )

  $missing = New-Object System.Collections.Generic.List[object]
  foreach ($signature in @(Get-RequiredFindingConfigKeys -Config $RequiredFindingsForTest | Sort-Object)) {
    $normalizedSignature = ([string]$signature).Trim().ToLowerInvariant()
    if ($normalizedSignature -notin $emittedSignatures) {
      $entry = Convert-RequiredFindingEntryToHashtable -Entry (Get-RequiredFindingConfigValue -Config $RequiredFindingsForTest -Key $signature)
      $missing.Add([pscustomobject]@{
          Signature = $normalizedSignature
          Description = [string]$entry.Description
          Ts = $entry.Ts
          User = [string]$entry.User
        }) | Out-Null
    }
  }

  return $missing.ToArray()
}

function Invoke-RequiredFindingsValidation {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$FunctionName,
    [Parameter(Mandatory)][object[]]$Records,
    [Parameter(Mandatory)]$RequiredFindings
  )

  $requiredFindingsForTest = Get-RequiredFindingsForTest -RequiredFindings $RequiredFindings -FunctionName $FunctionName
  if ($null -eq $requiredFindingsForTest) {
    return @($Records)
  }

  $shortName = Normalize-RequiredFindingTestName -TestName $FunctionName
  $missingFindings = @(Get-MissingRequiredFindings -Records $Records -RequiredFindingsForTest $requiredFindingsForTest)
  if ($missingFindings.Count -eq 0) {
    return @($Records)
  }

  $validationFailures = @()
  foreach ($missingFinding in $missingFindings) {
    $failureMessage = [string]$missingFinding.Description
    if ([string]::IsNullOrWhiteSpace($failureMessage)) {
      $failureMessage = "Required finding with signature $($missingFinding.Signature) was not emitted."
    }

    $validationFailures += Log-Failure $failureMessage -Comment "Required finding with signature $($missingFinding.Signature) was not emitted by $shortName" -Emitter $FunctionName
  }

  return @($Records) + @($validationFailures)
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

function Get-CustomTestScriptReferenceComment {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ScriptPath
  )

  "(see custom test '$ScriptPath')"
}

function Add-CustomTestScriptReferenceComment {
  [CmdletBinding()]
  param(
    [AllowEmptyString()][string]$Comment = '',
    [Parameter(Mandatory)][string]$ScriptPath
  )

  $reference = Get-CustomTestScriptReferenceComment -ScriptPath $ScriptPath
  $trimmedComment = [string]$Comment
  if ([string]::IsNullOrWhiteSpace($trimmedComment)) {
    return $reference
  }

  $trimmedComment = $trimmedComment.Trim()
  if ($trimmedComment -match [regex]::Escape($reference)) {
    return $trimmedComment
  }

  return ($trimmedComment + "`n" + $reference)
}

function Get-CustomHealthTestFilesFromPath {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Path
  )

  $resolved = $null
  try {
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
  }
  catch {
    Log-Debug "Path '$Path' was not found while resolving custom health tests."
    return @()
  }

  if (Test-Path -LiteralPath $resolved -PathType Container) {
    return @(Get-ChildItem -LiteralPath $resolved -Filter *.ps1 -File -ErrorAction SilentlyContinue | Sort-Object FullName)
  }

  if ((Test-Path -LiteralPath $resolved -PathType Leaf) -and ($resolved -like '*.ps1')) {
    return @((Get-Item -LiteralPath $resolved -ErrorAction SilentlyContinue))
  }

  Log-Debug "Path '$Path' was ignored because it is neither a folder nor a .ps1 script."
  return @()
}

function Resolve-CustomHealthTestScriptSelection {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Selection,
    [string]$CustomTestsPath
  )

  if ([string]::IsNullOrWhiteSpace($Selection)) {
    return $null
  }

  $trimmedSelection = $Selection.Trim()
  if ($trimmedSelection -notlike '*.ps1') {
    return $null
  }

  if (($trimmedSelection -match '^[.][\\/]') -or
      ($trimmedSelection -match '^[.][.][\\/]') -or
      ($trimmedSelection -match '[\\/]') -or
      [System.IO.Path]::IsPathRooted($trimmedSelection)) {
    $resolvedBySelection = Resolve-Path -LiteralPath $trimmedSelection -ErrorAction SilentlyContinue
    if ($resolvedBySelection -and (Test-Path -LiteralPath $resolvedBySelection.Path -PathType Leaf)) {
      return (Get-Item -LiteralPath $resolvedBySelection.Path -ErrorAction SilentlyContinue)
    }
    return $null
  }

  $candidateRoots = @()
  if (-not [string]::IsNullOrWhiteSpace($CustomTestsPath)) {
    $candidateRoots += $CustomTestsPath
  }
  if ($script:Config.DefaultCustomTestsPath -and ($script:Config.DefaultCustomTestsPath -notin $candidateRoots)) {
    $candidateRoots += $script:Config.DefaultCustomTestsPath
  }

  foreach ($candidateRoot in $candidateRoots) {
    $files = @(Get-CustomHealthTestFilesFromPath -Path $candidateRoot)
    $match = $files | Where-Object { $_.Name -ieq $trimmedSelection } | Select-Object -First 1
    if ($match) {
      return $match
    }
  }

  return $null
}

function Invoke-CustomHealthTestScript {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ScriptPath
  )

  if (($ExcludeTests -contains $ScriptPath) -or
      ($ExcludeTests -contains (Split-Path -Leaf $ScriptPath))) {
    Log-Debug "Skipping custom test $ScriptPath"
    return
  }

  Write-Progress -Activity "Starting custom test $ScriptPath"
  Log-Debug "Starting custom test $ScriptPath"
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
      & $ScriptPath 3>&1
    }

    foreach ($item in $result) {
      if ($item -is [System.Management.Automation.WarningRecord]) {
        $record = Convert-WarningLikeObjectToLogRecord -Value $item
        $comment = Add-CustomTestScriptReferenceComment -Comment $record.Comment -ScriptPath $ScriptPath
        Log-Msg -Level $record.Level -Msg $record.Msg -Comment $comment -Emitter $ScriptPath
        $cntProperRecord += 1
        if (($item.Message -as [string]) -match '^\s*\[\s*pass\s*\]') { $cntPassRecord += 1 }
      }
      elseif ($item -and $item.PSObject.Properties['Hash'] -and $null -ne $item.PSObject.Properties['Message'] -and $item.PSObject.Properties['level']) {
        $legacyLogDetected = $true
        $cntProperRecord += 1
        if ($item.level -eq 'pass') { $cntPassRecord += 1 }
        $existingComment = ''
        if ($item.PSObject.Properties['Comment']) {
          $existingComment = [string]$item.Comment
        }
        $item | Add-Member -NotePropertyName Comment -NotePropertyValue (Add-CustomTestScriptReferenceComment -Comment $existingComment -ScriptPath $ScriptPath) -Force
        $item | Add-Member -NotePropertyName Emitter -NotePropertyValue $ScriptPath -Force
        Write-Output $item
      }
      elseif ($item -is [string]) {
        $parts = Convert-TextToLogRecord $item
        $cntImproperRecord += 1
        Log-Debug $parts.Message -Comment $parts.Comment -Emitter $ScriptPath
      }
      else {
        $cntImproperRecord += 1
        $objType = $item.GetType().FullName
        $objText = ($item | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($objText)) { $objText = '<empty object serialization>' }
        Log-Debug "Converted output object of type $objType" -Comment $objText -Emitter $ScriptPath
      }
    }

    if ($legacyLogDetected) {
      $legacyComment = Add-CustomTestScriptReferenceComment -ScriptPath $ScriptPath
      Log-Notice "Consider modernizing the code in custom test script '$ScriptPath' to use Write-Warning instead of Log-Pass/Log-Failure/..." -Comment $legacyComment -Emitter $ScriptPath
    }

    if ($cntProperRecord -eq 0 -and $cntImproperRecord -eq 0) {
      $comment = Add-CustomTestScriptReferenceComment -ScriptPath $ScriptPath
      Log-Notice "Custom test script '$ScriptPath' returned no output (this is due to a programmer's mistake; the test may or may not have passed)" -Comment $comment -Emitter $ScriptPath
    }
  }
  catch {
    $err = $_
    $inv = $err.InvocationInfo
    $innerFunc = $null
    $innerFile = $null
    $innerLine = $null
    $innerCode = $null

    $frames = ($err.ScriptStackTrace -split "`r?`n") |
    Where-Object { $_ -match ':\s*line\s+\d+' }

    $frame = $frames | Where-Object { $_ -notmatch '\bInvoke-CustomHealthTestScript\b' } | Select-Object -First 1
    if (-not $frame) { $frame = $frames | Select-Object -First 1 }

    if ($frame -and $frame -match '^(?:at\s+)?([^,]+),\s*(.+?):\s*line\s+(\d+)\s*$') {
      $innerFunc = $matches[1].Trim()
      $innerFile = $matches[2].Trim()
      $innerLine = [int]$matches[3]

      try {
        if ($innerFile -and (Test-Path -LiteralPath $innerFile)) {
          $innerCode = (Get-Content -LiteralPath $innerFile -TotalCount $innerLine)[-1]
        }
      }
      catch {
        Log-Debug "Program Error: Failed to fetch the actual source line" -Emitter $ScriptPath
      }
    }

    $baseMsg = Get-LeftString $err.Exception.GetBaseException().Message 500
    $outerLine = $inv.ScriptLineNumber
    $outerCode = $inv.Line
    $locationDetails =
    if ($innerLine) {
      "Throw site: $ScriptPath" +
      ($(if ($innerFunc) { "`nFunction: $innerFunc" } else { "" })) +
      ($(if ($innerFile) { "`nFile: $innerFile" } else { "" })) +
      "`nLine: $innerLine" +
      ($(if ($innerCode) { "`n  #       Code: $innerCode" } else { "" }))
    }
    else {
      "Throw site unknown from stack; fallback to caller:`n  #       Line #$($outerLine): $outerCode"
    }

    $comment = "details: $baseMsg`n$locationDetails`n$(Add-CustomTestScriptReferenceComment -ScriptPath $ScriptPath)`nA Program Error during a test means either that the test failed or that its code has a bug."
    Log-Failure "(Program Error) Exception while running custom test script '$ScriptPath'" -Comment $comment -Emitter $ScriptPath
  }
  finally {
    $sw.Stop()
    $ErrorActionPreference = $oldEap
    Write-Progress -Activity "Starting custom test $ScriptPath" -Completed
  }

  Log-Debug "Done with custom test $ScriptPath in $([int]$sw.ElapsedMilliseconds) ms" -Emitter $ScriptPath
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
  param(
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias('ScriptPath')]
    [string]$FolderPath
  )

  if (-not (Test-Path -LiteralPath $FolderPath)) {
    Log-Debug "Custom health test path '$FolderPath' was not found."
    return
  }

  $files = @(Get-CustomHealthTestFilesFromPath -Path $FolderPath)
  if (-not $files) { return }

  foreach ($file in $files) {
    $scriptPath = $null

    if ($file -is [string]) {
      $scriptPath = $file
    }
    elseif ($file -and $file.PSObject.Properties['FullName']) {
      $scriptPath = [string]$file.FullName
    }

    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
      Log-Warning "Skipping a custom test entry from '$FolderPath' because its script path could not be determined."
      continue
    }

    Invoke-CustomHealthTestScript -ScriptPath $scriptPath
  }

  Log-Info "Ran $($files.Count) custom health test script(s) from '$FolderPath'."
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

  $records = @(Invoke-RequiredFindingsValidation -FunctionName $FunctionName -Records $records -RequiredFindings $script:RequiredFindings)

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

$script:RequiredFindings = Read-RequiredFindingsConfig -Path $script:Config.RequiredFindingsPath

# if we were called with -AddWhitelisting or -SetAsRequired we skip some uneeded work to save time
if ((-not $AddWhitelisting) -and (-not $SetAsRequired)) {
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
    $computerSystem = $null
    $domainRole = 0
    try {
      $computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
      if ($null -ne $computerSystem.PSObject.Properties['DomainRole']) {
        $domainRole = $computerSystem.DomainRole
      }
      else {
        Log-Warning "Could not determine host domain role from Win32_ComputerSystem; assuming standalone workstation."
      }
    }
    catch {
      Log-Warning "Could not query Win32_ComputerSystem domain role; assuming standalone workstation."
    }
    #------------------------------------------
    # What type of system are we running on
    #------------------------------------------
    $isHostVM = Test-IsVirtualMachine
    $isHostMobile = Test-IsLaptopOrMobile
    $IsHostInDomain = ($domainRole -in 1, 3, 4, 5)
    $isHostServer = ($domainRole -in 3, 4, 5)
    $isHostDC = ($domainRole -in 4, 5)
    $isHostDnsServer = $null -ne (Get-Service -Name DNS -ErrorAction SilentlyContinue)
    $isHostDhcpServer = ($isHostServer -and (Get-WindowsFeature DHCP -ErrorAction SilentlyContinue).InstallState -eq 'Installed')
    if (-not $RunWithoutElevation) {
      $isHostHyperV = (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V).State -eq 'Enabled'
    }
    else {
      $isHostHyperV = $false
    }
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
    if ($IsHostInDomain -and $validIpsOfAllDcs.Count -eq 0) {
      Log-failure "Cannot run many domain-related tests because no valid IPv4 addresses were provided in -IpsOfAllDcs. Marking this host as non-domain for test applicability."
      $IsHostInDomain = $false
      $isHostDC = $false
      $isHostPDC = $false
      $currentDomain = $null
    }
    
    # Explicitly created so shared run data is publicly accessible to all health tests,
    # including custom health tests loaded at runtime.
    $Global:GchData = [pscustomobject]@{
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

    if ($isHostDC) { . (Join-Path -Path $PSScriptRoot -ChildPath "health-tests\OnlyIfHostIs-DC.ps1") }
    if ($isHostDnsServer) { . (Join-Path -Path $PSScriptRoot -ChildPath "health-tests\OnlyIfHostIs-DnsServer.ps1") }
    if ($isHostDhcpServer) { . (Join-Path -Path $PSScriptRoot -ChildPath "health-tests\OnlyIfHostIs-DhcpServer.ps1") }
    if ($IsHostInDomain) { . (Join-Path -Path $PSScriptRoot -ChildPath "health-tests\OnlyIfHostIs-InDomain.ps1") }
    if ($IsHostInDomain -and -not $isHostDC) { . (Join-Path -Path $PSScriptRoot -ChildPath "health-tests\OnlyIfHostIs-InDomainButNotDC.ps1") }
    if ($isHostMobile) { . (Join-Path -Path $PSScriptRoot -ChildPath "health-tests\OnlyIfHostIs-Mobile.ps1") }
    if ($isHostHyperV) { . (Join-Path -Path $PSScriptRoot -ChildPath "health-tests\OnlyIfHostIs-HyperV.ps1") }
    if ($isHostServer) { . (Join-Path -Path $PSScriptRoot -ChildPath "health-tests\OnlyIfHostIs-Server.ps1") }
    #|
    #| Dot source health tests
    #+-----------------------------------------------------------

    $allHealthTests = Get-Command -CommandType Function -Name 'HealthTest-*' -ErrorAction SilentlyContinue
}

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

if ($SetAsRequired) {
  if (-not $Signature) { throw "You must supply a -Signature" }
  if (-not $ComputerName) { throw "You must supply a -ComputerName" }
  if (-not $Test) { throw "You must supply a -Test" }
  if ($Signature -notmatch '^[0-9A-Fa-f]{8}$') {
    throw "Invalid -Signature: $Signature"
  }
  if ($ComputerName -ne $env:COMPUTERNAME) {
    throw "Running on $($env:COMPUTERNAME) but required finding is for $ComputerName"
  }

  Set-RequiredFindingEntry `
    -Path $script:Config.RequiredFindingsPath `
    -TestName $Test `
    -Signature $Signature `
    -Description $Comment
  return
}


if ($DoNothing) { return }

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
Log-Debug "`$global:GchData" -Comment "$(($global:GchData|Format-List|Out-String).trim())"
Log-Debug '$allHealthTests' -comment "$(($allHealthTests).name -join ', ')"

Log-info "$((Split-Path $PSCommandPath -Leaf) -replace '.ps1'), ver.$VERSION, Nick Demou, enLogic"
$biosSerialNumber = 'Unknown'
try {
  $bios = Get-CimInstance win32_bios -ErrorAction Stop
  if ($null -ne $bios.PSObject.Properties['serialnumber'] -and $bios.serialnumber) {
    $biosSerialNumber = $bios.serialnumber
  }
}
catch {
}
Log-info "$(Get-Date -format yyyy-MM-dd` HH:mm:ss), Computer: $($env:COMPUTERNAME), S/N: $biosSerialNumber"
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
  $selectedBuiltInTests = New-Object System.Collections.Generic.List[string]
  $selectedCustomScripts = New-Object System.Collections.Generic.List[string]
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
    $customScript = Resolve-CustomHealthTestScriptSelection -Selection $item -CustomTestsPath $IncludeTestsFromFolder
    if ($customScript) {
      if ($customScript.FullName -notin $selectedCustomScripts) {
        $selectedCustomScripts.Add($customScript.FullName) | Out-Null
      }
      continue
    }

    if ($item -match $valid_cmdlet_name_regex) {
      $testName = $item.Trim()
      if ($loadedTestsByName.ContainsKey($testName)) {
        if ($loadedTestsByName[$testName] -notin $selectedBuiltInTests) {
          $selectedBuiltInTests.Add($loadedTestsByName[$testName]) | Out-Null
        }
      }
      elseif ($loadedTestsByBaseName.ContainsKey($testName)) {
        if ($loadedTestsByBaseName[$testName] -notin $selectedBuiltInTests) {
          $selectedBuiltInTests.Add($loadedTestsByBaseName[$testName]) | Out-Null
        }
      }
      elseif ($loadedTestsByShortName.ContainsKey($testName)) {
        if ($loadedTestsByShortName[$testName] -notin $selectedBuiltInTests) {
          $selectedBuiltInTests.Add($loadedTestsByShortName[$testName]) | Out-Null
        }
      }
      else {
        Log-Notice "Skipping unavailable test '$testName' (not loaded/applicable on this host)."
      }
    }
    else {
      if ($item -like '*.ps1') {
        Log-Notice "Skipping unavailable custom test script '$item'."
      }
      else {
        Log-Warning "Input '$item' is not a valid cmdlet name."
      }
    }
  }

  foreach ($functionName in $selectedBuiltInTests) {
    Invoke-HealthTestWithPolicyAutoset $functionName
  }

  foreach ($scriptPath in $selectedCustomScripts) {
    Invoke-CustomHealthTestScript -ScriptPath $scriptPath
  }

  return
}
else {
  # All tests
  foreach ($fn in $allHealthTests) {
    Invoke-HealthTestWithPolicyAutoset $fn.Name
  }
}

if (-not [string]::IsNullOrWhiteSpace($IncludeTestsFromFolder)) {
  # Also Custom HealthTest-*
  Invoke-HealthTestsFromFolder -FolderPath $IncludeTestsFromFolder
}
