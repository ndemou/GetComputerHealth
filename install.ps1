<#
.SYNOPSIS
Installs or updates GetComputerHealth into the current `bin` folder.

.DESCRIPTION
Resolves a source zip (local file, URI, or GitHub release), stages and validates it,
then performs an internal staged deployment pass to atomically update files.

.PARAMETER Source
Source selector. Supported forms:
- Local zip path
- GitHub repo (`owner/repo`, `github:owner/repo`, `github.com/owner/repo`, or a GitHub URL)
- Direct `http(s)` zip URL

.PARAMETER ForceRequery
Forces fresh source resolution for internet-backed selectors.

.PARAMETER Reinstall
Reinstalls even if the resolved package hash matches installed state.

.PARAMETER DevMode
After extracting the zip to the stage folder, replaces staged `install.ps1`
with the currently running script before handoff. This allows in-progress installer
changes to run through the full staged flow during development.

.PARAMETER Config
Hashtable or PowerShell data file path for customized installs. `Options.InstallDir`
sets the install root; `ConfigFiles` writes named .psd1 files under the config folder.

.PARAMETER GenerateConfigPsd1
Writes a sample `GetComputerHealth-install-config.psd1` file in the current folder.

.NOTES
Architecture and execution model:
- Purpose: install/update GetComputerHealth into the current `bin` tree safely.
- Modes:
  - outer mode: resolves source, stages zip, validates package, launches internal pass
  - internal mode (`-InternalStageRun`): performs file deployment and final state/summary commit
- Deployment model: staged two-phase handoff so installer self-update is safe.
- Commit point: installer copy is intentionally the final file write in deployment.
- Owned artifacts:
  - state: `config\\install-gch-state.json`
  - logs: `log\\install-gch-detailed-*.log`, `log\\install-gch-summary-YYYY.log`
  - cache/temp: `temp\\install-gch-install-v*.zip`, stage/download folders
- Deliberately not done:
  - no rollback transaction across all files
  - no trust in `bin\\VERSION` as install truth; state is authoritative
#>
[CmdletBinding()]
param(
  [string]$Source,
  [switch]$ForceRequery,
  [switch]$Reinstall,
  [switch]$DevMode,
  [object]$Config,
  [switch]$GenerateConfigPsd1,

  [Parameter(DontShow = $true)][switch]$InternalStageRun,
  [Parameter(DontShow = $true)][switch]$SkipMutexAcquire,
  [Parameter(DontShow = $true)][string]$PathToBin,
  [Parameter(DontShow = $true)][string]$StagedPackageRoot,
  [Parameter(DontShow = $true)][string]$StagedZipPath,
  [Parameter(DontShow = $true)][string]$SourceContextPath,
  [Parameter(DontShow = $true)][string]$DetailedLogPath
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$DEFAULT_REPO_URL = 'https://github.com/ndemou/GetComputerHealth'
$DEFAULT_SHOW_AS_POSTPONED_WINDOW_DAYS = 150

function Ensure-Directory {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    throw ('Path exists as a file, not a directory: {0}' -f $Path)
  }

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Write-TextFileUtf8NoBom {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Text
  )

  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Read-TextFileUtf8 {
  param([Parameter(Mandatory = $true)][string]$Path)

  $enc = New-Object System.Text.UTF8Encoding($false)
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $text = $enc.GetString($bytes)

  if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
    $text = $text.Substring(1)
  }

  $text
}

function Add-TextLineUtf8NoBom {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Line
  )

  $dir = Split-Path -Parent $Path
  if ($dir) {
    Ensure-Directory -Path $dir
  }

  $enc = New-Object System.Text.UTF8Encoding($false)
  $text = $Line + [Environment]::NewLine
  [System.IO.File]::AppendAllText($Path, $text, $enc)
}

function ConvertTo-GchPsd1Literal {
  param(
    [AllowNull()]$Value,
    [int]$Indent = 0
  )

  $spaces = ''.PadLeft($Indent)
  $childIndent = $Indent + 4
  $childSpaces = ''.PadLeft($childIndent)

  if ($null -eq $Value) { return '$null' }
  if ($Value -is [bool]) {
    if ($Value) { return '$true' }
    return '$false'
  }
  if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
    return ([string]$Value)
  }
  if ($Value -is [hashtable]) {
    $lines = @('@{')
    foreach ($key in @($Value.Keys | Sort-Object)) {
      $keyText = ConvertTo-GchPsd1KeyLiteral -Key ([string]$key)
      $valueText = ConvertTo-GchPsd1Literal -Value $Value[$key] -Indent $childIndent
      $lines += ('{0}{1} = {2}' -f $childSpaces, $keyText, $valueText)
    }
    $lines += ($spaces + '}')
    return ($lines -join [Environment]::NewLine)
  }
  if ($Value -is [System.Collections.IDictionary]) {
    $copy = @{}
    foreach ($key in $Value.Keys) {
      $copy[[string]$key] = $Value[$key]
    }
    return (ConvertTo-GchPsd1Literal -Value $copy -Indent $Indent)
  }
  if (($Value -is [System.Collections.IEnumerable]) -and (-not ($Value -is [string]))) {
    $items = @($Value)
    if ($items.Count -eq 0) { return '@()' }
    $itemTexts = @()
    foreach ($item in $items) {
      $itemTexts += (ConvertTo-GchPsd1Literal -Value $item -Indent $childIndent)
    }
    return ('@({0}{1}{0})' -f [Environment]::NewLine, (($itemTexts | ForEach-Object { $childSpaces + $_ }) -join (',' + [Environment]::NewLine)))
  }

  $text = [string]$Value
  return ("'{0}'" -f ($text -replace "'", "''"))
}

function ConvertTo-GchPsd1KeyLiteral {
  param([Parameter(Mandatory = $true)][string]$Key)

  if ($Key -match '^[A-Za-z_][A-Za-z0-9_]*$') {
    return $Key
  }

  return ("'{0}'" -f ($Key -replace "'", "''"))
}

function ConvertTo-GchPsd1Text {
  param([Parameter(Mandatory = $true)]$Value)

  (ConvertTo-GchPsd1Literal -Value $Value -Indent 0) + [Environment]::NewLine
}

function Get-GchInstallConfigTemplateText {
  @'
@{
    Options = @{
        # InstallDir is the folder that will contain bin, config, log, temp, and data.
        InstallDir = 'C:\IT\GetComputerHealth'
    }
    ConfigFiles = @{
        'Send-Message.psd1' = @{
            Server = 'smtp.contoso.com'
            From = 'SERVER01+alerts@contoso.com'
            To = 'ops@contoso.com;admin@contoso.com'
        }
        'gch.psd1' = @{
            AutomaticUpdates = $false
            RepoUrl = 'https://github.com/ndemou/GetComputerHealth'
            SendReports = 'Auto'
            ShowAsPostponedWindowDays = 15
            IpsOfAllDCs = @('10.1.2.3', '10.1.2.4')
        }
    }
}
'@
}

function Write-GchInstallConfigTemplate {
  $path = Join-Path (Get-Location).Path 'GetComputerHealth-install-config.psd1'
  Write-TextFileUtf8NoBom -Path $path -Text (Get-GchInstallConfigTemplateText)
  Write-Host ("Generated install configuration template: {0}" -f $path)
}

function Resolve-GchInstallConfig {
  param([AllowNull()]$InputObject)

  if ($null -eq $InputObject) { return $null }

  if ($InputObject -is [string]) {
    $configPath = [string]$InputObject
    if ([string]::IsNullOrWhiteSpace($configPath)) { return $null }
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
      throw "Install configuration file not found: '$configPath'"
    }
    return (Import-PowerShellDataFile -LiteralPath $configPath -ErrorAction Stop)
  }

  return $InputObject
}

function Get-GchInstallConfigSection {
  param(
    [AllowNull()]$ConfigObject,
    [Parameter(Mandatory = $true)][string]$Key
  )

  if ($null -eq $ConfigObject) { return $null }
  if ($ConfigObject -is [hashtable]) {
    if ($ConfigObject.ContainsKey($Key)) { return $ConfigObject[$Key] }
    return $null
  }
  if ($ConfigObject.PSObject.Properties[$Key]) { return $ConfigObject.$Key }
  return $null
}

function Write-GchCustomConfigFiles {
  param(
    [AllowNull()]$InstallConfig,
    [Parameter(Mandatory = $true)][string]$ConfigDir
  )

  $configFiles = Get-GchInstallConfigSection -ConfigObject $InstallConfig -Key 'ConfigFiles'
  if ($null -eq $configFiles) { return }
  if (-not ($configFiles -is [System.Collections.IDictionary])) {
    throw 'ConfigFiles must be a hashtable whose keys are config file names.'
  }

  Ensure-Directory -Path $ConfigDir
  foreach ($name in @($configFiles.Keys | Sort-Object)) {
    $fileName = [string]$name
    if ([string]::IsNullOrWhiteSpace($fileName)) {
      throw 'ConfigFiles contains an empty config file name.'
    }
    if ($fileName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $fileName -match '[\\/]') {
      throw "ConfigFiles file name '$fileName' must be a simple file name."
    }

    $path = Join-Path $ConfigDir $fileName
    $text = ConvertTo-GchPsd1Text -Value $configFiles[$name]
    Write-TextFileUtf8NoBom -Path $path -Text $text
  }
}

function Get-GchDefaultConfigText {
  param(
    [Parameter(Mandatory = $true)][string]$RepoUrl,
    [Parameter(Mandatory = $true)][int]$ShowAsPostponedWindowDays
  )

  @"
@{
    AutomaticUpdates = `$true
    RepoUrl = '$RepoUrl'
    ShowAsPostponedWindowDays = $ShowAsPostponedWindowDays
}
"@
}

function Ensure-GchConfigFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$RepoUrl,
    [Parameter(Mandatory = $true)][int]$ShowAsPostponedWindowDays
  )

  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    return
  }

  $dir = Split-Path -Parent $Path
  if ($dir) {
    Ensure-Directory -Path $dir
  }

  $text = Get-GchDefaultConfigText -RepoUrl $RepoUrl -ShowAsPostponedWindowDays $ShowAsPostponedWindowDays
  Write-TextFileUtf8NoBom -Path $Path -Text $text
}

function Read-GchConfigFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return @{}
  }

  try {
    $config = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
  }
  catch {
    throw "Failed reading configuration file '$Path': $($_.Exception.Message)"
  }

  if ($null -eq $config) {
    return @{}
  }

  return $config
}

function Test-GchConfigKey {
  param(
    [Parameter(Mandatory = $true)]$Config,
    [Parameter(Mandatory = $true)][string]$Key
  )

  if ($Config -is [hashtable]) {
    return $Config.ContainsKey($Key)
  }

  return ($Config.PSObject.Properties[$Key] -ne $null)
}

function Get-GchConfigValue {
  param(
    [Parameter(Mandatory = $true)]$Config,
    [Parameter(Mandatory = $true)][string]$Key
  )

  if ($Config -is [hashtable]) {
    return $Config[$Key]
  }

  return $Config.$Key
}

function Test-GchFalsyValue {
  param([AllowNull()]$Value)

  if ($null -eq $Value) { return $true }
  if ($Value -is [bool]) { return (-not $Value) }
  if ($Value -is [int]) { return ($Value -eq 0) }
  if ($Value -is [string]) {
    $text = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $true }
    return ($text -in @('0', 'false', 'no', 'off'))
  }

  return (-not [bool]$Value)
}

function Resolve-GchConfiguredRepoUrl {
  param([Parameter(Mandatory = $true)][string]$RepoUrl)

  $value = $RepoUrl.Trim()
  $uri = $null
  if (([string]::IsNullOrWhiteSpace($value)) -or (-not [System.Uri]::TryCreate($value, [System.UriKind]::Absolute, [ref]$uri))) {
    throw "Invalid RepoUrl value in gch.psd1: '$RepoUrl'. Use a GitHub repository URL such as https://github.com/owner/repo."
  }

  if (($uri.Scheme -notin @('http', 'https')) -or ($uri.Host -ine 'github.com')) {
    throw "Invalid RepoUrl value in gch.psd1: '$RepoUrl'. Use a GitHub repository URL such as https://github.com/owner/repo."
  }

  $parts = @($uri.AbsolutePath.Trim('/') -split '/')
  if (($parts.Count -lt 2) -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
    throw "Invalid RepoUrl value in gch.psd1: '$RepoUrl'. Use a GitHub repository URL such as https://github.com/owner/repo."
  }

  $normalizedPath = ('{0}/{1}' -f $parts[0], (($parts[1] -replace '\.git$', '')))
  return ('{0}://github.com/{1}' -f $uri.Scheme.ToLowerInvariant(), $normalizedPath)
}

function Resolve-GchConfiguredNonNegativeInteger {
  param(
    [Parameter(Mandatory = $true)]$Value,
    [Parameter(Mandatory = $true)][string]$Key
  )

  $text = ([string]$Value).Trim()
  $number = 0
  if (([string]::IsNullOrWhiteSpace($text)) -or (-not [int]::TryParse($text, [ref]$number)) -or ($number -lt 0)) {
    throw "Invalid $Key value in gch.psd1: '$Value'. Use an integer greater than or equal to 0."
  }

  return $number
}

function Get-StringSha256Hex {
  param([Parameter(Mandatory = $true)][string]$Text)

  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = $sha.ComputeHash($bytes)
    (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
  }
  finally {
    $sha.Dispose()
  }
}

function Get-FileSha256Hex {
  param([Parameter(Mandatory = $true)][string]$Path)
  (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-ShortHash {
  param([Parameter(Mandatory = $true)][string]$Hash)
  $Hash.Substring(0,8).ToLowerInvariant()
}

function Get-SafeTempLeafName {
  param([Parameter(Mandatory = $true)][string]$Text)
  (($Text -replace '[^\p{L}\p{Nd}\._-]', '_').Trim('_'))
}

function New-AtomicTempPath {
  param([Parameter(Mandatory = $true)][string]$DestinationPath)

  # Temp files intentionally live beside the destination so ACL inheritance matches final writes.
  # The '~install-gch-' prefix is relied on by stale-temp cleanup logic.
  $destFull = [System.IO.Path]::GetFullPath($DestinationPath)
  $destDir = Split-Path -Parent $destFull
  Ensure-Directory -Path $destDir

  $leaf = [System.IO.Path]::GetFileName($destFull)
  $safeLeaf = Get-SafeTempLeafName -Text $leaf
  if ([string]::IsNullOrWhiteSpace($safeLeaf)) {
    $safeLeaf = 'file'
  }

  $hash8 = Get-ShortHash -Hash (Get-StringSha256Hex -Text $destFull.ToLowerInvariant())
  Join-Path $destDir ('~install-gch-{0}-{1}-{2}.tmp' -f $safeLeaf, $hash8, ([guid]::NewGuid().ToString('N')))
}

function Write-Log {
  param(
    [Parameter(Mandatory = $true)][string]$Message,
    [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
  )

  $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

  if ($script:DetailedLogPath) {
    Add-TextLineUtf8NoBom -Path $script:DetailedLogPath -Line $line
  }

  if ($Level -eq 'ERROR') {
    Write-Error -Message $Message -ErrorAction Continue
  }
  elseif ($Level -eq 'WARN') {
    Write-Warning $Message
  }
  else {
    Write-Verbose $line
  }
}

function Invoke-WithRetry {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
    [Parameter(Mandatory = $true)][string]$ActionDescription,
    [int]$MaxAttempts = 6,
    [int]$DelayMilliseconds = 250
  )

  $attempt = 0
  while ($true) {
    $attempt++
    try {
      & $ScriptBlock
      return
    }
    catch {
      if ($attempt -ge $MaxAttempts) {
        throw
      }

      Write-Log -Level WARN -Message ('{0} failed on attempt {1}/{2}: {3}' -f $ActionDescription, $attempt, $MaxAttempts, $_.Exception.Message)
      Start-Sleep -Milliseconds $DelayMilliseconds
    }
  }
}

function Move-FileIntoPlaceAtomic {
  param(
    [Parameter(Mandatory = $true)][string]$TempPath,
    [Parameter(Mandatory = $true)][string]$DestinationPath
  )

  # Guarantees on success: destination contains temp content and temp is consumed.
  # Partial effects on failure are acceptable because caller retries and higher-level
  # ordering keeps installer self-update as the final committed file operation.
  Invoke-WithRetry -ActionDescription ('Place file {0}' -f $DestinationPath) -ScriptBlock {
    if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
      $destDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($DestinationPath))
      $backupPath = Join-Path $destDir ('~install-gch-backup-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
      try {
        [System.IO.File]::Replace($TempPath, $DestinationPath, $backupPath, $false)
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
          Remove-Item -LiteralPath $backupPath -Force
        }
      }
      catch [System.ArgumentException] {
        Remove-Item -LiteralPath $DestinationPath -Force
        [System.IO.File]::Move($TempPath, $DestinationPath)
      }
    }
    else {
      [System.IO.File]::Move($TempPath, $DestinationPath)
    }
  }
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  $raw = Read-TextFileUtf8 -Path $Path
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return $null
  }

  $raw | ConvertFrom-Json
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Object
  )

  $json = $Object | ConvertTo-Json -Depth 12
  $dir = Split-Path -Parent $Path
  Ensure-Directory -Path $dir

  $tempPath = New-AtomicTempPath -DestinationPath $Path
  try {
    Write-TextFileUtf8NoBom -Path $tempPath -Text $json
    Move-FileIntoPlaceAtomic -TempPath $tempPath -DestinationPath $Path
  }
  finally {
    if (Test-Path -LiteralPath $tempPath) {
      try { Remove-Item -LiteralPath $tempPath -Force } catch {}
    }
  }
}

function Normalize-InstallerState {
  param([Parameter(Mandatory = $true)]$State)

  # State schema (SchemaVersion=2):
  # - LastSuccessfulInstall: authoritative installed package/hash/source snapshot
  # - RememberedInternetSource: remembered remote source + cached zip metadata
  # - InternetSourceQueryHistory: recent query attempts used for cooldown/rate safety
  # Compatibility expectation: normalize missing/extra fields without failing installs.
  $history = @()
  if ($State -and $State.PSObject.Properties.Name -contains 'InternetSourceQueryHistory' -and $State.InternetSourceQueryHistory) {
    $history = @($State.InternetSourceQueryHistory)
  }

  ([ordered]@{
      SchemaVersion = 2
      LastSuccessfulInstall = $State.LastSuccessfulInstall
      RememberedInternetSource = $State.RememberedInternetSource
      InternetSourceQueryHistory = $history
    })
}

function Read-InstallerState {
  param([Parameter(Mandatory = $true)][string]$Path)

  try {
    $state = Read-JsonFile -Path $Path
    if ($state) {
      return (Normalize-InstallerState -State $state)
    }
  }
  catch {
    Write-Log -Level WARN -Message ('State file is unreadable; ignoring it: {0}' -f $_.Exception.Message)
  }

  ([ordered]@{
      SchemaVersion = 2
      LastSuccessfulInstall = $null
      RememberedInternetSource = $null
      InternetSourceQueryHistory = @()
    })
}

function Save-InstallerState {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$State
  )

  $normalized = Normalize-InstallerState -State $State
  Write-JsonFile -Path $Path -Object $normalized
}

function Get-InternetSourceKey {
  param(
    [Parameter(Mandatory = $true)][string]$Kind,
    [Parameter(Mandatory = $true)][string]$Value
  )

  ('{0}|{1}' -f $Kind.ToLowerInvariant(), $Value.ToLowerInvariant())
}

function Get-InternetSourceQueryEntry {
  param(
    [Parameter(Mandatory = $true)]$State,
    [Parameter(Mandatory = $true)][string]$Kind,
    [Parameter(Mandatory = $true)][string]$Value
  )

  $key = Get-InternetSourceKey -Kind $Kind -Value $Value
  foreach ($entry in @($State.InternetSourceQueryHistory)) {
    if ($entry) {
      $entryKey = Get-InternetSourceKey -Kind ([string]$entry.Kind) -Value ([string]$entry.Value)
      if ($entryKey -eq $key) {
        return $entry
      }
    }
  }

  $null
}

function Set-InternetSourceAttemptState {
  param(
    [Parameter(Mandatory = $true)]$State,
    [Parameter(Mandatory = $true)][string]$Kind,
    [Parameter(Mandatory = $true)][string]$Value,
    [Parameter(Mandatory = $true)][string]$AttemptUtc
  )

  $key = Get-InternetSourceKey -Kind $Kind -Value $Value
  $history = @()

  foreach ($entry in @($State.InternetSourceQueryHistory)) {
    if (-not $entry) { continue }
    $entryKey = Get-InternetSourceKey -Kind ([string]$entry.Kind) -Value ([string]$entry.Value)
    if ($entryKey -ne $key) {
      $history += [ordered]@{
        Kind = [string]$entry.Kind
        Value = [string]$entry.Value
        LastAttemptUtc = [string]$entry.LastAttemptUtc
      }
    }
  }

  $history += [ordered]@{
    Kind = $Kind
    Value = $Value
    LastAttemptUtc = $AttemptUtc
  }

  if ($history.Count -gt 24) {
    $history = @($history[($history.Count - 24)..($history.Count - 1)])
  }

  ([ordered]@{
      SchemaVersion = 2
      LastSuccessfulInstall = $State.LastSuccessfulInstall
      RememberedInternetSource = $State.RememberedInternetSource
      InternetSourceQueryHistory = $history
    })
}

function Get-TargetBinPath {
  $installOptions = Get-GchInstallConfigSection -ConfigObject $script:InstallConfig -Key 'Options'

  if ($InternalStageRun) {
    if ([string]::IsNullOrWhiteSpace($PathToBin)) {
      throw 'Internal staged execution requires -PathToBin.'
    }
    return ([System.IO.Path]::GetFullPath($PathToBin))
  }

  if ($installOptions -and (Test-GchConfigKey -Config $installOptions -Key 'InstallDir')) {
    $installDir = [string](Get-GchConfigValue -Config $installOptions -Key 'InstallDir')
    if ([string]::IsNullOrWhiteSpace($installDir)) {
      throw 'Config.Options.InstallDir cannot be empty.'
    }
    return ([System.IO.Path]::GetFullPath((Join-Path $installDir 'bin')))
  }

  $cwd = (Get-Location).Path
  $leaf = Split-Path -Leaf $cwd
  if ($leaf -ine 'bin') {
    throw 'This installer must be run from a folder named "bin" unless -Config @{ Options = @{ InstallDir = ... } } is provided.'
  }

  ([System.IO.Path]::GetFullPath($cwd))
}

function Initialize-Paths {
  param([Parameter(Mandatory = $true)][string]$BinPath)

  $root = Split-Path -Parent $BinPath

  $script:BinPath = $BinPath
  $script:RootPath = $root
  $script:LogDir = Join-Path $root 'log'
  $script:TempDir = Join-Path $root 'temp'
  $script:ConfigDir = Join-Path $root 'config'

  Ensure-Directory -Path $script:LogDir
  Ensure-Directory -Path $script:TempDir
  Ensure-Directory -Path $script:ConfigDir
  $script:GchConfigPath = Join-Path $script:ConfigDir 'gch.psd1'

  if ([string]::IsNullOrWhiteSpace($DetailedLogPath)) {
    $script:DetailedLogPath = Join-Path $script:LogDir ('install-gch-detailed-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd-HH.mm.ss'))
  }
  else {
    $script:DetailedLogPath = [System.IO.Path]::GetFullPath($DetailedLogPath)
    Ensure-Directory -Path (Split-Path -Parent $script:DetailedLogPath)
  }

  $script:SummaryLogPath = Join-Path $script:LogDir ('install-gch-summary-{0}.log' -f (Get-Date -Format 'yyyy'))
  $script:StatePath = Join-Path $script:ConfigDir 'install-gch-state.json'
}

function Get-MutexName {
  param([Parameter(Mandatory = $true)][string]$BinPath)
  $hash8 = Get-ShortHash -Hash (Get-StringSha256Hex -Text $BinPath.ToLowerInvariant())
  # Scope lock per target bin tree; independent bins should not block each other.
  # Local\\ is intentional to avoid global-machine lock contention across unrelated installs.
  'Local\install-gch-{0}' -f $hash8
}

function Enter-InstallMutex {
  param(
    [Parameter(Mandatory = $true)][string]$BinPath,
    [int]$WaitTimeoutSec = 0
  )

  $name = Get-MutexName -BinPath $BinPath
  $mutex = New-Object System.Threading.Mutex($false, $name)
  $acquired = $false

  try {
    if ($WaitTimeoutSec -lt 0) {
      $acquired = $mutex.WaitOne()
    }
    else {
      $acquired = $mutex.WaitOne(([TimeSpan]::FromSeconds($WaitTimeoutSec)), $false)
    }

    if (-not $acquired) {
      throw 'Another install.ps1 instance is already running for this bin folder.'
    }

    $mutex
  }
  catch [System.Threading.AbandonedMutexException] {
    Write-Log -Level WARN -Message 'Recovered an abandoned installer mutex.'
    $mutex
  }
  catch {
    if ($mutex) {
      $mutex.Dispose()
    }
    throw
  }
}

function Exit-InstallMutex {
  param($Mutex)

  if ($Mutex) {
    try { $Mutex.ReleaseMutex() } catch {}
    try { $Mutex.Dispose() } catch {}
  }
}

function Get-WebStatusCodeFromError {
  param([Parameter(Mandatory = $true)]$ErrorRecord)

  if ($ErrorRecord.Exception -and $ErrorRecord.Exception.Response) {
    try {
      return [int]$ErrorRecord.Exception.Response.StatusCode
    }
    catch {}
  }

  $null
}

function Invoke-WebRequestFast {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [string]$Method = 'Get',
    [hashtable]$Headers,
    [string]$OutFile,
    [int]$TimeoutSec = 120
  )

  $oldProgressPreference = $global:ProgressPreference
  $global:ProgressPreference = 'SilentlyContinue'
  try {
    if ($OutFile) {
      Invoke-WebRequest -UseBasicParsing -Uri $Uri -Method $Method -Headers $Headers -OutFile $OutFile -TimeoutSec $TimeoutSec
    }
    else {
      Invoke-WebRequest -UseBasicParsing -Uri $Uri -Method $Method -Headers $Headers -TimeoutSec $TimeoutSec
    }
  }
  finally {
    $global:ProgressPreference = $oldProgressPreference
  }
}

function Test-FileMatchesHash {
  param(
    [string]$Path,
    [string]$ExpectedHash
  )

  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  if ([string]::IsNullOrWhiteSpace($ExpectedHash)) { return $false }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }

  try {
    ((Get-FileSha256Hex -Path $Path) -eq $ExpectedHash.ToLowerInvariant())
  }
  catch {
    Write-Log -Level WARN -Message ('Could not hash file {0}: {1}' -f $Path, $_.Exception.Message)
    $false
  }
}

function Test-RememberedCachedZipUsable {
  param($RememberedInternetSource)

  if (-not $RememberedInternetSource) { return $false }
  Test-FileMatchesHash -Path ([string]$RememberedInternetSource.CachedZipPath) -ExpectedHash ([string]$RememberedInternetSource.CachedZipHash)
}

function Test-CanSafelyFallbackToRememberedZip {
  param($RememberedInternetSource)

  if (-not $RememberedInternetSource) { return $false }
  Test-RememberedCachedZipUsable -RememberedInternetSource $RememberedInternetSource
}

function Get-UriFreshnessInfo {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    $PreviousMetadata
  )

  $headers = @{}
  if ($PreviousMetadata) {
    if ($PreviousMetadata.ETag) {
      $headers['If-None-Match'] = [string]$PreviousMetadata.ETag
    }
    elseif ($PreviousMetadata.LastModified) {
      $headers['If-Modified-Since'] = [string]$PreviousMetadata.LastModified
    }
  }

  try {
    $resp = Invoke-WebRequestFast -Uri $Uri -Method Head -Headers $headers
    $etag = $resp.Headers['ETag']
    $lastModified = $resp.Headers['Last-Modified']
    $contentLength = $resp.Headers['Content-Length']

    ([ordered]@{
        QueryUri = $Uri
        NotModified = $false
        HeadSucceeded = $true
        IsReliable = ([bool]$etag -or [bool]$lastModified)
        ETag = $etag
        LastModified = $lastModified
        ContentLength = $contentLength
      })
  }
  catch {
    $code = Get-WebStatusCodeFromError -ErrorRecord $_

    if ($code -eq 304) {
      return ([ordered]@{
          QueryUri = $Uri
          NotModified = $true
          HeadSucceeded = $true
          IsReliable = $true
          ETag = if ($PreviousMetadata) { [string]$PreviousMetadata.ETag } else { $null }
          LastModified = if ($PreviousMetadata) { [string]$PreviousMetadata.LastModified } else { $null }
          ContentLength = if ($PreviousMetadata) { [string]$PreviousMetadata.ContentLength } else { $null }
        })
    }

    if (($code -eq 405) -or ($code -eq 501) -or ($code -eq 403)) {
      Write-Log -Level WARN -Message ('HEAD could not be used reliably for {0}; treating freshness metadata as unreliable.' -f $Uri)
      return ([ordered]@{
          QueryUri = $Uri
          NotModified = $false
          HeadSucceeded = $false
          IsReliable = $false
          ETag = $null
          LastModified = $null
          ContentLength = $null
        })
    }

    throw
  }
}

function Get-GitHubLatestZipAssetInfo {
  param(
    [Parameter(Mandatory = $true)][string]$Repo,
    $PreviousMetadata
  )

  if ($Repo -notmatch '^[^/\s]+/[^/\s]+$') {
    throw '-Source (GitHub) must be in the form "owner/repo".'
  }

  $uri = 'https://api.github.com/repos/{0}/releases/latest' -f $Repo
  $headers = @{
    'User-Agent' = 'install.ps1'
    'Accept'     = 'application/vnd.github+json'
  }

  if ($PreviousMetadata -and $PreviousMetadata.ETag) {
    $headers['If-None-Match'] = [string]$PreviousMetadata.ETag
  }

  try {
    $resp = Invoke-WebRequestFast -Uri $uri -Method Get -Headers $headers
  }
  catch {
    $code = Get-WebStatusCodeFromError -ErrorRecord $_
    if ($code -eq 304) {
      return ([ordered]@{
          Repo = $Repo
          QueryUri = $uri
          NotModified = $true
          ETag = if ($PreviousMetadata) { [string]$PreviousMetadata.ETag } else { $null }
        })
    }
    throw
  }

  $obj = $resp.Content | ConvertFrom-Json

  if ($obj.draft -or $obj.prerelease) {
    throw ('GitHub latest release for {0} is not a stable release.' -f $Repo)
  }

  # Exactly one zip asset is required so source selection is deterministic.
  $zipAssets = @($obj.assets | Where-Object { $_.name -match '(?i)\.zip$' })
  if ($zipAssets.Count -ne 1) {
    throw ('GitHub latest stable release for {0} must contain exactly one .zip asset; found {1}.' -f $Repo, $zipAssets.Count)
  }

  $asset = $zipAssets[0]

  ([ordered]@{
      Repo = $Repo
      QueryUri = $uri
      NotModified = $false
      ETag = $resp.Headers['ETag']
      ReleaseId = [string]$obj.id
      ReleaseTag = [string]$obj.tag_name
      ReleasePublishedUtc = [string]$obj.published_at
      AssetId = [string]$asset.id
      AssetName = [string]$asset.name
      AssetSize = [string]$asset.size
      AssetUpdatedUtc = [string]$asset.updated_at
      DownloadUri = [string]$asset.browser_download_url
      MetadataKey = '{0}|{1}|{2}|{3}' -f $obj.id, $asset.id, $asset.updated_at, $asset.size
    })
}

function Download-File {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [Parameter(Mandatory = $true)][string]$DestinationPath,
    [hashtable]$Headers
  )

  if (Test-Path -LiteralPath $DestinationPath) {
    Remove-Item -LiteralPath $DestinationPath -Force
  }

  try {
    Invoke-WebRequestFast -Uri $Uri -Method Get -Headers $Headers -OutFile $DestinationPath | Out-Null
  }
  catch {
    if (Test-Path -LiteralPath $DestinationPath) {
      try { Remove-Item -LiteralPath $DestinationPath -Force } catch {}
    }
    throw
  }

  if (-not (Test-Path -LiteralPath $DestinationPath)) {
    throw ('Download did not produce a file: {0}' -f $Uri)
  }

  $item = Get-Item -LiteralPath $DestinationPath
  if ($item.Length -le 0) {
    throw ('Downloaded file is empty: {0}' -f $Uri)
  }
}

function Get-NewDownloadPath {
  param([Parameter(Mandatory = $true)][string]$TempDir)
  Join-Path $TempDir ('install-gch-download-{0}-{1}.zip' -f (Get-Date -Format 'yyyy-MM-dd-HH.mm.ss'), ([guid]::NewGuid().ToString('N').Substring(0,8)))
}

function Get-NewStagePath {
  param([Parameter(Mandatory = $true)][string]$TempDir)
  Join-Path $TempDir ('install-gch-stage-{0}-{1}' -f (Get-Date -Format 'yyyy-MM-dd-HH.mm.ss'), ([guid]::NewGuid().ToString('N').Substring(0,8)))
}

function Remove-StaleInstallerArtifacts {
  param(
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][string]$BinPath,
    [int]$MaxAgeHours = 48
  )

  # Best-effort hygiene only. Cleanup failures must not block install/update.
  $cutoff = (Get-Date).AddHours(-1 * $MaxAgeHours)

  if (Test-Path -LiteralPath $TempDir -PathType Container) {
    $staleStageDirs = @(Get-ChildItem -LiteralPath $TempDir -Directory -Filter 'install-gch-stage-*' -ErrorAction SilentlyContinue)
    foreach ($dir in $staleStageDirs) {
      if ($dir.LastWriteTime -lt $cutoff) {
        try {
          Remove-Item -LiteralPath $dir.FullName -Recurse -Force
          Write-Log -Message ('Removed stale stage folder: {0}' -f $dir.FullName)
        }
        catch {
          Write-Log -Level WARN -Message ('Could not remove stale stage folder {0}: {1}' -f $dir.FullName, $_.Exception.Message)
        }
      }
    }

    $staleDownloadZips = @(Get-ChildItem -LiteralPath $TempDir -File -Filter 'install-gch-download-*.zip' -ErrorAction SilentlyContinue)
    foreach ($file in $staleDownloadZips) {
      if ($file.LastWriteTime -lt $cutoff) {
        try {
          Remove-Item -LiteralPath $file.FullName -Force
          Write-Log -Message ('Removed stale temporary downloaded zip: {0}' -f $file.FullName)
        }
        catch {
          Write-Log -Level WARN -Message ('Could not remove stale temporary downloaded zip {0}: {1}' -f $file.FullName, $_.Exception.Message)
        }
      }
    }
  }

  if (Test-Path -LiteralPath $BinPath -PathType Container) {
    $staleBinTemps = @(Get-ChildItem -LiteralPath $BinPath -Recurse -File -Filter '~install-gch-*.tmp' -ErrorAction SilentlyContinue)
    foreach ($file in $staleBinTemps) {
      if ($file.LastWriteTime -lt $cutoff) {
        try {
          Remove-Item -LiteralPath $file.FullName -Force
          Write-Log -Message ('Removed stale atomic temp file from bin tree: {0}' -f $file.FullName)
        }
        catch {
          Write-Log -Level WARN -Message ('Could not remove stale atomic temp file {0}: {1}' -f $file.FullName, $_.Exception.Message)
        }
      }
    }
  }
}

function Compare-UriFreshness {
  param(
    $OldMetadata,
    $NewMetadata
  )

  if (-not $OldMetadata) { return $false }
  if (-not $NewMetadata) { return $false }
  if (-not $OldMetadata.IsReliable) { return $false }
  if (-not $NewMetadata.IsReliable) { return $false }

  if ($OldMetadata.ETag -and $NewMetadata.ETag) {
    return ($OldMetadata.ETag -eq $NewMetadata.ETag)
  }

  if ($OldMetadata.LastModified -and $NewMetadata.LastModified) {
    if ($OldMetadata.ContentLength -and $NewMetadata.ContentLength) {
      return (($OldMetadata.LastModified -eq $NewMetadata.LastModified) -and ($OldMetadata.ContentLength -eq $NewMetadata.ContentLength))
    }
    return ($OldMetadata.LastModified -eq $NewMetadata.LastModified)
  }

  $false
}

function Get-CachedZipByHash {
  param(
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][string]$Hash
  )

  $hash8 = Get-ShortHash -Hash $Hash
  $pattern = 'install-gch-install-v*-{0}-*.zip' -f $hash8
  $candidates = @(Get-ChildItem -LiteralPath $TempDir -File -Filter $pattern -ErrorAction SilentlyContinue)

  foreach ($candidate in $candidates) {
    try {
      $candidateHash = Get-FileSha256Hex -Path $candidate.FullName
      if ($candidateHash -eq $Hash) {
        return $candidate.FullName
      }
    }
    catch {
      Write-Log -Level WARN -Message ('Could not hash cached zip {0}: {1}' -f $candidate.FullName, $_.Exception.Message)
    }
  }

  $null
}

function Prune-CachedInstalledZips {
  param([Parameter(Mandatory = $true)][string]$TempDir)

  $files = @(Get-ChildItem -LiteralPath $TempDir -File -Filter 'install-gch-install-v*.zip' -ErrorAction SilentlyContinue)
  if ($files.Count -le 0) {
    return
  }

  $entries = @()
  foreach ($file in $files) {
    try {
      $entries += [pscustomobject]@{
        File = $file
        Hash = (Get-FileSha256Hex -Path $file.FullName)
      }
    }
    catch {
      Write-Log -Level WARN -Message ('Could not hash cached zip during prune: {0}' -f $file.FullName)
    }
  }

  if ($entries.Count -le 0) {
    return
  }

  $keepers = @()
  foreach ($group in ($entries | Group-Object -Property Hash)) {
    $ordered = @($group.Group | Sort-Object { $_.File.LastWriteTimeUtc } -Descending)
    $keepers += $ordered[0]
    if ($ordered.Count -gt 1) {
      foreach ($dup in $ordered[1..($ordered.Count - 1)]) {
        try {
          Remove-Item -LiteralPath $dup.File.FullName -Force
          Write-Log -Message ('Removed duplicate cached zip: {0}' -f $dup.File.FullName)
        }
        catch {
          Write-Log -Level WARN -Message ('Could not remove duplicate cached zip {0}: {1}' -f $dup.File.FullName, $_.Exception.Message)
        }
      }
    }
  }

  $keepersOrdered = @($keepers | Sort-Object { $_.File.LastWriteTimeUtc } -Descending)
  if ($keepersOrdered.Count -le 4) {
    return
  }

  foreach ($extra in $keepersOrdered[4..($keepersOrdered.Count - 1)]) {
    try {
      Remove-Item -LiteralPath $extra.File.FullName -Force
      Write-Log -Message ('Pruned old cached zip: {0}' -f $extra.File.FullName)
    }
    catch {
      Write-Log -Level WARN -Message ('Could not prune cached zip {0}: {1}' -f $extra.File.FullName, $_.Exception.Message)
    }
  }
}

function Ensure-CachedInstalledZip {
  param(
    [Parameter(Mandatory = $true)][string]$SourceZipPath,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][string]$PackageVersion,
    [Parameter(Mandatory = $true)][string]$ZipHash
  )

  $existing = Get-CachedZipByHash -TempDir $TempDir -Hash $ZipHash
  if ($existing) {
    $item = Get-Item -LiteralPath $existing
    $item.LastWriteTime = Get-Date
    return $existing
  }

  $destName = 'install-gch-install-v{0}-{1}-{2}.zip' -f $PackageVersion, (Get-ShortHash -Hash $ZipHash), (Get-Date -Format 'yyyy-MM-dd-HH.mm.ss')
  $destPath = Join-Path $TempDir $destName
  $tempPath = New-AtomicTempPath -DestinationPath $destPath

  try {
    Invoke-WithRetry -ActionDescription ('Create cached zip {0}' -f $destPath) -ScriptBlock {
      Copy-Item -LiteralPath $SourceZipPath -Destination $tempPath -Force
    }
    Move-FileIntoPlaceAtomic -TempPath $tempPath -DestinationPath $destPath
    return $destPath
  }
  finally {
    if (Test-Path -LiteralPath $tempPath) {
      try { Remove-Item -LiteralPath $tempPath -Force } catch {}
    }
  }
}

function Get-StableZipPathForState {
  param(
    [string]$PreferredPath,
    [string]$FallbackPath,
    [Parameter(Mandatory = $true)][string]$TempDir,
    [Parameter(Mandatory = $true)][string]$Hash
  )

  if (Test-FileMatchesHash -Path $PreferredPath -ExpectedHash $Hash) {
    $name = [System.IO.Path]::GetFileName($PreferredPath)
    if ($name -like 'install-gch-install-v*.zip') {
      return ([System.IO.Path]::GetFullPath($PreferredPath))
    }
  }

  if (Test-FileMatchesHash -Path $FallbackPath -ExpectedHash $Hash) {
    return ([System.IO.Path]::GetFullPath($FallbackPath))
  }

  $cachePath = Get-CachedZipByHash -TempDir $TempDir -Hash $Hash
  if ($cachePath) {
    return ([System.IO.Path]::GetFullPath($cachePath))
  }

  $null
}

function Get-SourceZipNameForSummary {
  param([Parameter(Mandatory = $true)]$SourceContext)

  if ($SourceContext.SourceKind -eq 'GitHub') {
    if ($SourceContext.RememberedInternetSource -and
        $SourceContext.RememberedInternetSource.Metadata -and
        $SourceContext.RememberedInternetSource.Metadata.AssetName) {
      return [string]$SourceContext.RememberedInternetSource.Metadata.AssetName
    }
  }

  if ($SourceContext.SourceKind -eq 'Uri') {
    if ($SourceContext.SourceValue) {
      try {
        $uri = New-Object System.Uri([string]$SourceContext.SourceValue)
        $leaf = [System.IO.Path]::GetFileName($uri.AbsolutePath)
        if (-not [string]::IsNullOrWhiteSpace($leaf)) {
          return $leaf
        }
      }
      catch {}
    }
  }

  if ($SourceContext.Candidate -and $SourceContext.Candidate.ZipName) {
    return [string]$SourceContext.Candidate.ZipName
  }

  $null
}

function Resolve-SourcePlan {
  param(
    [Parameter(Mandatory = $true)]$State,
    [Parameter(Mandatory = $true)][string]$StatePath,
    [string]$Source,
    [switch]$ForceRequery,
    [Parameter(Mandatory = $true)][string]$TempDir
  )

  # Intent: classify source and produce a deterministic acquisition plan.
  # Side effects: may update query-attempt state before remote checks.
  # Invariant: local zip sources must not update RememberedInternetSource.
  $requestedKind = $null
  $requestedValue = $null

  if ($Source) {
    $sourceTrim = ([string]$Source).Trim()
    if ([string]::IsNullOrWhiteSpace($sourceTrim)) {
      throw 'If specified, -Source cannot be empty.'
    }

    if (Test-Path -LiteralPath $sourceTrim) {
      if (-not (Test-Path -LiteralPath $sourceTrim -PathType Leaf)) {
        throw ('Source is not a file: {0}' -f $sourceTrim)
      }

      $resolved = Resolve-Path -LiteralPath $sourceTrim
      $zipPath = $resolved.Path

      return ([ordered]@{
          ZipPath = $zipPath
          IsTemporaryZip = $false
          SourceContext = [ordered]@{
            SourceKind = 'Zip'
            SourceValue = $zipPath
            SourceDisplay = $zipPath
            RememberedInternetSource = $null
            Candidate = [ordered]@{
              ZipPath = $zipPath
              ZipName = [System.IO.Path]::GetFileName($zipPath)
              ZipHash = $null
              ZipHash8 = $null
              PackageName = $null
              PackageVersion = $null
            }
          }
        })
    }

    $absoluteUri = $null
    $isHttpUri = [System.Uri]::TryCreate($sourceTrim, [System.UriKind]::Absolute, [ref]$absoluteUri) -and
      (($absoluteUri.Scheme -eq 'http') -or ($absoluteUri.Scheme -eq 'https'))

    if ($isHttpUri) {
      if ($absoluteUri.Host -match '(^|\.)github\.com$') {
        $parts = @($absoluteUri.AbsolutePath.Trim('/') -split '/')
        if ($parts.Count -ge 2 -and $parts[0] -and $parts[1]) {
          $requestedKind = 'GitHub'
          $requestedValue = ('{0}/{1}' -f $parts[0], $parts[1])
        }
      }

      if (-not $requestedKind) {
        $requestedKind = 'Uri'
        $requestedValue = $sourceTrim
      }
    }
    elseif ($sourceTrim -match '^(?i)github:(?<owner>[A-Za-z0-9_.-]+)/(?<repo>[A-Za-z0-9_.-]+)$') {
      $requestedKind = 'GitHub'
      $requestedValue = ('{0}/{1}' -f $Matches['owner'], $Matches['repo'])
    }
    elseif ($sourceTrim -match '^(?<owner>[A-Za-z0-9_.-]+)/(?<repo>[A-Za-z0-9_.-]+)$') {
      $requestedKind = 'GitHub'
      $requestedValue = ('{0}/{1}' -f $Matches['owner'], $Matches['repo'])
    }
    elseif ($sourceTrim -match '^(?i)github\.com/(?<owner>[A-Za-z0-9_.-]+)/(?<repo>[A-Za-z0-9_.-]+)$') {
      $requestedKind = 'GitHub'
      $requestedValue = ('{0}/{1}' -f $Matches['owner'], $Matches['repo'])
    }
    else {
      throw ('Could not determine source type from -Source value: {0}. Use a local zip path, an http(s) zip URL, or a GitHub repo in owner/repo form.' -f $sourceTrim)
    }
  }
  else {
    if (-not $State.RememberedInternetSource) {
      throw 'No source was specified and no remembered Internet source exists.'
    }
    $requestedKind = [string]$State.RememberedInternetSource.Kind
    $requestedValue = [string]$State.RememberedInternetSource.Value
  }

  $prev = $null
  if ($State.RememberedInternetSource) {
    if (($State.RememberedInternetSource.Kind -eq $requestedKind) -and ($State.RememberedInternetSource.Value -eq $requestedValue)) {
      $prev = $State.RememberedInternetSource
    }
  }

  $cooldownActive = $false
  $queryEntry = Get-InternetSourceQueryEntry -State $State -Kind $requestedKind -Value $requestedValue
  if ($queryEntry -and $queryEntry.LastAttemptUtc -and (-not $ForceRequery)) {
    try {
      $age = [DateTime]::UtcNow - ([DateTime]::Parse([string]$queryEntry.LastAttemptUtc).ToUniversalTime())
      if ($age.TotalMinutes -lt 60) {
        $cooldownActive = $true
      }
    }
    catch {}
  }

  # Cooldown applies to query attempts, not only successful queries.
  if ($cooldownActive) {
    if (Test-RememberedCachedZipUsable -RememberedInternetSource $prev) {
      Write-Log -Message ('Reusing cached zip for {0} during the one-hour cooldown.' -f $requestedValue)

      return ([ordered]@{
          ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
          IsTemporaryZip = $false
          SourceContext = [ordered]@{
            SourceKind = $requestedKind
            SourceValue = $requestedValue
            SourceDisplay = $(if ($requestedKind -eq 'GitHub') { 'github:{0}' -f $requestedValue } else { $requestedValue })
            RememberedInternetSource = $prev
            Candidate = [ordered]@{
              ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
              ZipName = [System.IO.Path]::GetFileName([string]$prev.CachedZipPath)
              ZipHash = $null
              ZipHash8 = $null
              PackageName = $null
              PackageVersion = $null
            }
          }
        })
    }

    throw ('Remote source {0} was already checked less than one hour ago and no usable cached zip is available. Use -ForceRequery to override.' -f $requestedValue)
  }

  # Record attempt before remote calls so repeated failures are also throttled.
  $stateAfterAttempt = Set-InternetSourceAttemptState -State $State -Kind $requestedKind -Value $requestedValue -AttemptUtc ([DateTime]::UtcNow.ToString('o'))
  Save-InstallerState -Path $StatePath -State $stateAfterAttempt
  $State = $stateAfterAttempt

  if ($requestedKind -eq 'GitHub') {
    Write-Log -Message ('Querying GitHub latest stable release for {0}.' -f $requestedValue)

    $prevMeta = $null
    if ($prev) { $prevMeta = $prev.Metadata }

    try {
      $info = Get-GitHubLatestZipAssetInfo -Repo $requestedValue -PreviousMetadata $prevMeta
    }
    catch {
      if (Test-CanSafelyFallbackToRememberedZip -RememberedInternetSource $prev) {
        Write-Log -Level WARN -Message ('GitHub query failed; reusing previously cached zip for {0}: {1}' -f $requestedValue, $_.Exception.Message)

        return ([ordered]@{
            ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
            IsTemporaryZip = $false
            SourceContext = [ordered]@{
              SourceKind = 'GitHub'
              SourceValue = $requestedValue
              SourceDisplay = ('github:{0}' -f $requestedValue)
              RememberedInternetSource = $prev
              Candidate = [ordered]@{
                ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
                ZipName = [System.IO.Path]::GetFileName([string]$prev.CachedZipPath)
                ZipHash = $null
                ZipHash8 = $null
                PackageName = $null
                PackageVersion = $null
              }
            }
          })
      }

      throw
    }

    if ($info.NotModified) {
      if (Test-RememberedCachedZipUsable -RememberedInternetSource $prev) {
        Write-Log -Message ('GitHub release metadata returned not modified; reusing cached zip {0}.' -f $prev.CachedZipPath)

        return ([ordered]@{
            ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
            IsTemporaryZip = $false
            SourceContext = [ordered]@{
              SourceKind = 'GitHub'
              SourceValue = $requestedValue
              SourceDisplay = ('github:{0}' -f $requestedValue)
              RememberedInternetSource = $prev
              Candidate = [ordered]@{
                ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
                ZipName = [System.IO.Path]::GetFileName([string]$prev.CachedZipPath)
                ZipHash = $null
                ZipHash8 = $null
                PackageName = $null
                PackageVersion = $null
              }
            }
          })
      }

      Write-Log -Level WARN -Message 'GitHub returned not modified but the cached zip is missing or does not match its stored hash; querying metadata again without ETag.'
      $info = Get-GitHubLatestZipAssetInfo -Repo $requestedValue -PreviousMetadata $null
    }

    $remember = [ordered]@{
      Kind = 'GitHub'
      Value = $requestedValue
      Display = ('github:{0}' -f $requestedValue)
      LastCheckedUtc = [DateTime]::UtcNow.ToString('o')
      Metadata = [ordered]@{
        QueryUri = $info.QueryUri
        ETag = $info.ETag
        ReleaseId = $info.ReleaseId
        ReleaseTag = $info.ReleaseTag
        ReleasePublishedUtc = $info.ReleasePublishedUtc
        AssetId = $info.AssetId
        AssetName = $info.AssetName
        AssetSize = $info.AssetSize
        AssetUpdatedUtc = $info.AssetUpdatedUtc
        DownloadUri = $info.DownloadUri
        MetadataKey = $info.MetadataKey
      }
      CachedZipPath = $null
      CachedZipHash = $null
      CachedZipHash8 = $null
      CachedPackageVersion = $null
    }

    if ($prev -and $prev.Metadata -and ($prev.Metadata.MetadataKey -eq $info.MetadataKey) -and (Test-RememberedCachedZipUsable -RememberedInternetSource $prev)) {
      Write-Log -Message ('GitHub release asset is unchanged; reusing cached zip {0}.' -f $prev.CachedZipPath)
      $remember.CachedZipPath = [string]$prev.CachedZipPath
      $remember.CachedZipHash = [string]$prev.CachedZipHash
      $remember.CachedZipHash8 = [string]$prev.CachedZipHash8
      $remember.CachedPackageVersion = [string]$prev.CachedPackageVersion

      return ([ordered]@{
          ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
          IsTemporaryZip = $false
          SourceContext = [ordered]@{
            SourceKind = 'GitHub'
            SourceValue = $requestedValue
            SourceDisplay = ('github:{0}' -f $requestedValue)
            RememberedInternetSource = $remember
            Candidate = [ordered]@{
              ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
              ZipName = [System.IO.Path]::GetFileName([string]$prev.CachedZipPath)
              ZipHash = $null
              ZipHash8 = $null
              PackageName = $null
              PackageVersion = $null
            }
          }
        })
    }

    $downloadPath = Get-NewDownloadPath -TempDir $TempDir
    Write-Log -Message ('Downloading GitHub asset {0}.' -f $info.DownloadUri)
    Download-File -Uri $info.DownloadUri -DestinationPath $downloadPath -Headers @{ 'User-Agent' = 'install.ps1' }

    return ([ordered]@{
        ZipPath = $downloadPath
        IsTemporaryZip = $true
        SourceContext = [ordered]@{
          SourceKind = 'GitHub'
          SourceValue = $requestedValue
          SourceDisplay = ('github:{0}' -f $requestedValue)
          RememberedInternetSource = $remember
          Candidate = [ordered]@{
            ZipPath = $downloadPath
            ZipName = [System.IO.Path]::GetFileName($downloadPath)
            ZipHash = $null
            ZipHash8 = $null
            PackageName = $null
            PackageVersion = $null
          }
        }
      })
  }

  if ($requestedKind -eq 'Uri') {
    Write-Log -Message ('Querying URI freshness for {0}.' -f $requestedValue)

    $prevMeta = $null
    if ($prev) { $prevMeta = $prev.Metadata }

    try {
      $fresh = Get-UriFreshnessInfo -Uri $requestedValue -PreviousMetadata $prevMeta
    }
    catch {
      if (Test-CanSafelyFallbackToRememberedZip -RememberedInternetSource $prev) {
        Write-Log -Level WARN -Message ('URI freshness query failed; reusing previously cached zip for {0}: {1}' -f $requestedValue, $_.Exception.Message)

        return ([ordered]@{
            ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
            IsTemporaryZip = $false
            SourceContext = [ordered]@{
              SourceKind = 'Uri'
              SourceValue = $requestedValue
              SourceDisplay = $requestedValue
              RememberedInternetSource = $prev
              Candidate = [ordered]@{
                ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
                ZipName = [System.IO.Path]::GetFileName([string]$prev.CachedZipPath)
                ZipHash = $null
                ZipHash8 = $null
                PackageName = $null
                PackageVersion = $null
              }
            }
          })
      }

      throw
    }

    if ($fresh.NotModified) {
      if (Test-RememberedCachedZipUsable -RememberedInternetSource $prev) {
        Write-Log -Message ('URI source returned not modified; reusing cached zip {0}.' -f $prev.CachedZipPath)

        return ([ordered]@{
            ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
            IsTemporaryZip = $false
            SourceContext = [ordered]@{
              SourceKind = 'Uri'
              SourceValue = $requestedValue
              SourceDisplay = $requestedValue
              RememberedInternetSource = $prev
              Candidate = [ordered]@{
                ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
                ZipName = [System.IO.Path]::GetFileName([string]$prev.CachedZipPath)
                ZipHash = $null
                ZipHash8 = $null
                PackageName = $null
                PackageVersion = $null
              }
            }
          })
      }

      Write-Log -Level WARN -Message 'URI source returned not modified but the cached zip is missing or does not match its stored hash; querying freshness again without validators.'
      $fresh = Get-UriFreshnessInfo -Uri $requestedValue -PreviousMetadata $null
    }

    $remember = [ordered]@{
      Kind = 'Uri'
      Value = $requestedValue
      Display = $requestedValue
      LastCheckedUtc = [DateTime]::UtcNow.ToString('o')
      Metadata = [ordered]@{
        QueryUri = $fresh.QueryUri
        HeadSucceeded = $fresh.HeadSucceeded
        IsReliable = $fresh.IsReliable
        ETag = $fresh.ETag
        LastModified = $fresh.LastModified
        ContentLength = $fresh.ContentLength
      }
      CachedZipPath = $null
      CachedZipHash = $null
      CachedZipHash8 = $null
      CachedPackageVersion = $null
    }

    if ($fresh.IsReliable -and $prev -and (Compare-UriFreshness -OldMetadata $prev.Metadata -NewMetadata $fresh) -and (Test-RememberedCachedZipUsable -RememberedInternetSource $prev)) {
      Write-Log -Message ('URI freshness metadata is unchanged; reusing cached zip {0}.' -f $prev.CachedZipPath)
      $remember.CachedZipPath = [string]$prev.CachedZipPath
      $remember.CachedZipHash = [string]$prev.CachedZipHash
      $remember.CachedZipHash8 = [string]$prev.CachedZipHash8
      $remember.CachedPackageVersion = [string]$prev.CachedPackageVersion

      return ([ordered]@{
          ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
          IsTemporaryZip = $false
          SourceContext = [ordered]@{
            SourceKind = 'Uri'
            SourceValue = $requestedValue
            SourceDisplay = $requestedValue
            RememberedInternetSource = $remember
            Candidate = [ordered]@{
              ZipPath = ([System.IO.Path]::GetFullPath([string]$prev.CachedZipPath))
              ZipName = [System.IO.Path]::GetFileName([string]$prev.CachedZipPath)
              ZipHash = $null
              ZipHash8 = $null
              PackageName = $null
              PackageVersion = $null
            }
          }
        })
    }

    # Unreliable HEAD/metadata means we cannot safely infer unchanged content.
    # After cooldown, force a re-download instead of trusting validators.
    if (-not $fresh.IsReliable) {
      Write-Log -Message ('URI source has no reliable freshness metadata; re-downloading after cooldown.')
    }

    $downloadPath = Get-NewDownloadPath -TempDir $TempDir
    Write-Log -Message ('Downloading URI source {0}.' -f $requestedValue)
    Download-File -Uri $requestedValue -DestinationPath $downloadPath

    return ([ordered]@{
        ZipPath = $downloadPath
        IsTemporaryZip = $true
        SourceContext = [ordered]@{
          SourceKind = 'Uri'
          SourceValue = $requestedValue
          SourceDisplay = $requestedValue
          RememberedInternetSource = $remember
          Candidate = [ordered]@{
            ZipPath = $downloadPath
            ZipName = [System.IO.Path]::GetFileName($downloadPath)
            ZipHash = $null
            ZipHash8 = $null
            PackageName = $null
            PackageVersion = $null
          }
        }
      })
  }

  throw ('Unsupported source kind: {0}' -f $requestedKind)
}

function Expand-ZipToStage {
  param(
    [Parameter(Mandatory = $true)][string]$ZipPath,
    [Parameter(Mandatory = $true)][string]$StageRoot
  )

  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem

  if (Test-Path -LiteralPath $StageRoot) {
    Remove-Item -LiteralPath $StageRoot -Recurse -Force
  }
  Ensure-Directory -Path $StageRoot

  $stageFull = [System.IO.Path]::GetFullPath($StageRoot)
  if (-not $stageFull.EndsWith('\')) {
    $stageFull = $stageFull + '\'
  }

  $archive = $null
  try {
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)

    foreach ($entry in $archive.Entries) {
      $destPath = Join-Path $StageRoot $entry.FullName
      $fullDestPath = [System.IO.Path]::GetFullPath($destPath)

      if (-not $fullDestPath.StartsWith($stageFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ('Zip contains an invalid entry path: {0}' -f $entry.FullName)
      }

      if ([string]::IsNullOrEmpty($entry.Name)) {
        Ensure-Directory -Path $fullDestPath
        continue
      }

      Ensure-Directory -Path (Split-Path -Parent $fullDestPath)
      [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $fullDestPath, $true)
    }
  }
  finally {
    if ($archive) {
      $archive.Dispose()
    }
  }
}

function Get-PowerShellCodeFiles {
  param([Parameter(Mandatory = $true)][string]$PackageRoot)

  $extensions = @('.ps1','.psm1','.psd1','.pssc','.psrc')
  @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -File | Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() })
}

function Test-PowerShellSyntaxFiles {
  param(
    [Parameter(Mandatory = $true)][string]$PackageRoot
  )

  $codeFiles = Get-PowerShellCodeFiles -PackageRoot $PackageRoot
  $errorsFound = @()

  foreach ($file in $codeFiles) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null

    if ($parseErrors -and $parseErrors.Count -gt 0) {
      foreach ($parseError in $parseErrors) {
        $errorsFound += ('{0}({1},{2}): {3}' -f $file.FullName, $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message)
      }
    }
  }

  ([ordered]@{
      FilesChecked = $codeFiles.Count
      Errors = $errorsFound
    })
}

function Test-StagedPackage {
  param([Parameter(Mandatory = $true)][string]$StageRoot)

  $topDirs = @(Get-ChildItem -LiteralPath $StageRoot -Force | Where-Object { $_.PSIsContainer })
  if ($topDirs.Count -ne 1) {
    throw ('Zip must contain exactly one top-level folder; found {0}.' -f $topDirs.Count)
  }

  $packageRoot = $topDirs[0].FullName
  $folderName = $topDirs[0].Name

  if ($folderName -notmatch '^(?<Name>.+)-(?<Version>\d+(?:\.\d+)*)$') {
    throw ('Top-level folder name must be <NAME>-<NUMERICAL_VERSION>; found "{0}".' -f $folderName)
  }

  $packageName = $Matches['Name']
  $packageVersion = $Matches['Version']

  $ps1Files = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -File -Filter '*.ps1')
  if ($ps1Files.Count -lt 1) {
    throw 'Package must contain at least one .ps1 file.'
  }

  $stagedInstaller = Join-Path $packageRoot 'install.ps1'
  if (-not (Test-Path -LiteralPath $stagedInstaller -PathType Leaf)) {
    throw 'Package must contain install.ps1 at package root.'
  }

  $syntax = Test-PowerShellSyntaxFiles -PackageRoot $packageRoot
  if ($syntax.Errors.Count -gt 0) {
    $msg = "Package contains PowerShell syntax errors:`r`n" + ($syntax.Errors -join "`r`n")
    throw $msg
  }

  ([ordered]@{
      PackageRoot = $packageRoot
      PackageName = $packageName
      PackageVersion = $packageVersion
      InstallerPath = $stagedInstaller
      SyntaxFilesChecked = $syntax.FilesChecked
    })
}

function Test-FilesDifferent {
  param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$DestinationPath
  )

  if (-not (Test-Path -LiteralPath $DestinationPath -PathType Leaf)) {
    return $true
  }

  $src = Get-Item -LiteralPath $SourcePath
  $dst = Get-Item -LiteralPath $DestinationPath

  if ($src.Length -ne $dst.Length) {
    return $true
  }

  $srcHash = Get-FileSha256Hex -Path $SourcePath
  $dstHash = Get-FileSha256Hex -Path $DestinationPath

  ($srcHash -ne $dstHash)
}

function Copy-FileAtomic {
  param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$DestinationPath
  )

  $destDir = Split-Path -Parent $DestinationPath
  Ensure-Directory -Path $destDir

  $tempPath = New-AtomicTempPath -DestinationPath $DestinationPath
  try {
    Invoke-WithRetry -ActionDescription ('Stage temp file for {0}' -f $DestinationPath) -ScriptBlock {
      Copy-Item -LiteralPath $SourcePath -Destination $tempPath -Force
    }
    Move-FileIntoPlaceAtomic -TempPath $tempPath -DestinationPath $DestinationPath
  }
  finally {
    if (Test-Path -LiteralPath $tempPath) {
      try { Remove-Item -LiteralPath $tempPath -Force } catch {}
    }
  }
}

function Write-VersionFile {
  param(
    [Parameter(Mandatory = $true)][string]$DestinationPath,
    [Parameter(Mandatory = $true)][string]$Version
  )

  $destDir = Split-Path -Parent $DestinationPath
  Ensure-Directory -Path $destDir

  $tempPath = New-AtomicTempPath -DestinationPath $DestinationPath
  try {
    Write-TextFileUtf8NoBom -Path $tempPath -Text $Version
    Move-FileIntoPlaceAtomic -TempPath $tempPath -DestinationPath $DestinationPath
  }
  finally {
    if (Test-Path -LiteralPath $tempPath) {
      try { Remove-Item -LiteralPath $tempPath -Force } catch {}
    }
  }
}

function Build-StateAfterNoOp {
  param(
    [Parameter(Mandatory = $true)]$OldState,
    [Parameter(Mandatory = $true)]$SourceContext,
    [Parameter(Mandatory = $true)][string]$ZipHash,
    [Parameter(Mandatory = $true)][string]$TempDir
  )

  # No-op updates should only refresh remembered-source/cache metadata.
  # LastSuccessfulInstall remains authoritative and unchanged here.
  $remembered = $OldState.RememberedInternetSource

  if ($SourceContext.RememberedInternetSource) {
    $stableZipPath = Get-StableZipPathForState `
      -PreferredPath $SourceContext.Candidate.ZipPath `
      -FallbackPath ([string]$OldState.LastSuccessfulInstall.InstalledZipPath) `
      -TempDir $TempDir `
      -Hash $ZipHash

    if (-not $stableZipPath) {
      $candidateZipPath = $null
      $packageVersion = $null

      if ($SourceContext.Candidate -and $SourceContext.Candidate.ZipPath) {
        $candidateZipPath = [string]$SourceContext.Candidate.ZipPath
      }

      if ($OldState.LastSuccessfulInstall -and $OldState.LastSuccessfulInstall.PackageVersion) {
        $packageVersion = [string]$OldState.LastSuccessfulInstall.PackageVersion
      }

      if ($candidateZipPath -and $packageVersion -and (Test-FileMatchesHash -Path $candidateZipPath -ExpectedHash $ZipHash)) {
        try {
          $stableZipPath = Ensure-CachedInstalledZip `
            -SourceZipPath $candidateZipPath `
            -TempDir $TempDir `
            -PackageVersion $packageVersion `
            -ZipHash $ZipHash

          Prune-CachedInstalledZips -TempDir $TempDir
          Write-Log -Message ('Promoted source zip into cache during no-op state update: {0}' -f $stableZipPath)
        }
        catch {
          Write-Log -Level WARN -Message ('Could not promote source zip into cache during no-op state update: {0}' -f $_.Exception.Message)
        }
      }
    }

    $remembered = [ordered]@{
      Kind = [string]$SourceContext.RememberedInternetSource.Kind
      Value = [string]$SourceContext.RememberedInternetSource.Value
      Display = [string]$SourceContext.RememberedInternetSource.Display
      LastCheckedUtc = [string]$SourceContext.RememberedInternetSource.LastCheckedUtc
      Metadata = $SourceContext.RememberedInternetSource.Metadata
      CachedZipPath = $stableZipPath
      CachedZipHash = if ($stableZipPath) { $ZipHash } else { $null }
      CachedZipHash8 = if ($stableZipPath) { Get-ShortHash -Hash $ZipHash } else { $null }
      CachedPackageVersion = if ($stableZipPath -and $OldState.LastSuccessfulInstall) { [string]$OldState.LastSuccessfulInstall.PackageVersion } else { $null }
    }
  }

  ([ordered]@{
      SchemaVersion = 2
      LastSuccessfulInstall = $OldState.LastSuccessfulInstall
      RememberedInternetSource = $remembered
      InternetSourceQueryHistory = @($OldState.InternetSourceQueryHistory)
    })
}

function Build-StateAfterSuccess {
  param(
    [Parameter(Mandatory = $true)]$OldState,
    [Parameter(Mandatory = $true)]$SourceContext,
    [Parameter(Mandatory = $true)][string]$CacheZipPath,
    [Parameter(Mandatory = $true)][string]$ZipHash,
    [Parameter(Mandatory = $true)][string]$PackageVersion,
    [Parameter(Mandatory = $true)][string]$PackageName
  )

  # This becomes the authoritative installed snapshot for future no-op checks.
  $installed = [ordered]@{
    InstalledAtUtc = [DateTime]::UtcNow.ToString('o')
    PackageName = $PackageName
    PackageVersion = $PackageVersion
    InstalledZipHash = $ZipHash
    InstalledZipHash8 = (Get-ShortHash -Hash $ZipHash)
    InstalledZipPath = $CacheZipPath
    InstalledZipName = [System.IO.Path]::GetFileName($CacheZipPath)
    SourceKind = [string]$SourceContext.SourceKind
    SourceValue = [string]$SourceContext.SourceValue
    SourceDisplay = [string]$SourceContext.SourceDisplay
  }

  $remembered = $OldState.RememberedInternetSource

  if ($SourceContext.RememberedInternetSource) {
    $remembered = [ordered]@{
      Kind = [string]$SourceContext.RememberedInternetSource.Kind
      Value = [string]$SourceContext.RememberedInternetSource.Value
      Display = [string]$SourceContext.RememberedInternetSource.Display
      LastCheckedUtc = [string]$SourceContext.RememberedInternetSource.LastCheckedUtc
      Metadata = $SourceContext.RememberedInternetSource.Metadata
      CachedZipPath = $CacheZipPath
      CachedZipHash = $ZipHash
      CachedZipHash8 = (Get-ShortHash -Hash $ZipHash)
      CachedPackageVersion = $PackageVersion
    }
  }

  ([ordered]@{
      SchemaVersion = 2
      LastSuccessfulInstall = $installed
      RememberedInternetSource = $remembered
      InternetSourceQueryHistory = @($OldState.InternetSourceQueryHistory)
    })
}

function Invoke-StagedDeployment {
  param(
    [Parameter(Mandatory = $true)][string]$BinPath,
    [Parameter(Mandatory = $true)][string]$StagedPackageRoot,
    [Parameter(Mandatory = $true)][string]$StagedZipPath,
    [Parameter(Mandatory = $true)][string]$SourceContextPath,
    [Parameter(Mandatory = $true)][string]$StatePath,
    [Parameter(Mandatory = $true)][string]$TempDir
  )

  if (-not (Test-Path -LiteralPath $StagedPackageRoot -PathType Container)) {
    throw ('Staged package root does not exist: {0}' -f $StagedPackageRoot)
  }

  if (-not (Test-Path -LiteralPath $StagedZipPath -PathType Leaf)) {
    throw ('Staged zip does not exist: {0}' -f $StagedZipPath)
  }

  $sourceContext = Read-JsonFile -Path $SourceContextPath
  if (-not $sourceContext) {
    throw ('Source context file is missing or invalid: {0}' -f $SourceContextPath)
  }

  # Validate staged content again in internal mode before any bin mutation.
  # Do not move this later in the function.
  $stageRoot = Split-Path -Parent $StagedPackageRoot
  $validated = Test-StagedPackage -StageRoot $stageRoot
  if ([System.IO.Path]::GetFullPath($validated.PackageRoot) -ne [System.IO.Path]::GetFullPath($StagedPackageRoot)) {
    throw 'Validated package root does not match the staged package root passed to internal execution.'
  }

  $allDirs = @(Get-ChildItem -LiteralPath $validated.PackageRoot -Recurse -Directory | Sort-Object FullName)
  foreach ($dir in $allDirs) {
    $relative = $dir.FullName.Substring($validated.PackageRoot.Length).TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($relative)) {
      continue
    }
    $destDir = Join-Path $BinPath $relative
    if (-not (Test-Path -LiteralPath $destDir)) {
      Ensure-Directory -Path $destDir
      Write-Log -Message ('Created directory: {0}' -f $relative)
    }
  }

  $filesCopied = 0
  $filesSkipped = 0

  $allFiles = @(Get-ChildItem -LiteralPath $validated.PackageRoot -Recurse -File | Sort-Object FullName)

  foreach ($file in $allFiles) {
    $relative = $file.FullName.Substring($validated.PackageRoot.Length).TrimStart('\')
    if ($relative -ieq 'install.ps1') { continue }
    if ($relative -ieq 'VERSION') { continue }

    $destPath = Join-Path $BinPath $relative
    if (Test-FilesDifferent -SourcePath $file.FullName -DestinationPath $destPath) {
      Copy-FileAtomic -SourcePath $file.FullName -DestinationPath $destPath
      Write-Log -Message ('Copied file: {0}' -f $relative)
      $filesCopied++
    }
    else {
      Write-Log -Message ('Unchanged file: {0}' -f $relative)
      $filesSkipped++
    }
  }

  # VERSION is written near the end; state remains the source of truth.
  $versionPath = Join-Path $BinPath 'VERSION'
  Write-VersionFile -DestinationPath $versionPath -Version $validated.PackageVersion
  Write-Log -Message ('Wrote VERSION file: {0}' -f $validated.PackageVersion)

  $zipHash = [string]$sourceContext.Candidate.ZipHash
  $cacheZipPath = Ensure-CachedInstalledZip -SourceZipPath $StagedZipPath -TempDir $TempDir -PackageVersion $validated.PackageVersion -ZipHash $zipHash
  Write-Log -Message ('Cached installed zip: {0}' -f $cacheZipPath)

  Prune-CachedInstalledZips -TempDir $TempDir

  # Final committed file step: installer copy must remain last among payload writes.
  # Do not move earlier; this protects recovery behavior after mid-flight failures.
  $installerSource = Join-Path $validated.PackageRoot 'install.ps1'
  $installerDest = Join-Path $BinPath 'install.ps1'
  if (Test-FilesDifferent -SourcePath $installerSource -DestinationPath $installerDest) {
    Copy-FileAtomic -SourcePath $installerSource -DestinationPath $installerDest
    Write-Log -Message 'Copied installer as final committed step: install.ps1'
    $filesCopied++
  }
  else {
    Write-Log -Message 'Installer unchanged; final committed step completed.'
    $filesSkipped++
  }

  $oldState = Read-InstallerState -Path $StatePath
  $newState = Build-StateAfterSuccess `
    -OldState $oldState `
    -SourceContext $sourceContext `
    -CacheZipPath $cacheZipPath `
    -ZipHash $zipHash `
    -PackageVersion $validated.PackageVersion `
    -PackageName $validated.PackageName

  # State and summary are committed only after final file commit succeeds.
  Save-InstallerState -Path $StatePath -State $newState

  $sourceZipName = Get-SourceZipNameForSummary -SourceContext $sourceContext
  $cachedZipName = [System.IO.Path]::GetFileName($cacheZipPath)

  $summary = '{0} | Installed | Version={1} | Package={2} | SourceZipName={3} | CachedZipName={4} | ZipHash={5} | SourceKind={6} | Source={7}' -f `
    (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), `
    $validated.PackageVersion, `
    $validated.PackageName, `
    $(if ($sourceZipName) { $sourceZipName } else { '-' }), `
    $cachedZipName, `
    (Get-ShortHash -Hash $zipHash), `
    $sourceContext.SourceKind, `
    $sourceContext.SourceDisplay

  if ($sourceContext.SourceKind -eq 'Uri' -and $sourceContext.SourceValue) {
    $summary = $summary + (' | Uri={0}' -f $sourceContext.SourceValue)
  }

  if ($sourceContext.SourceKind -eq 'GitHub' -and $sourceContext.SourceValue) {
    $summary = $summary + (' | GitHub={0}' -f $sourceContext.SourceValue)
    if ($sourceContext.RememberedInternetSource -and
        $sourceContext.RememberedInternetSource.Metadata -and
        $sourceContext.RememberedInternetSource.Metadata.DownloadUri) {
      $summary = $summary + (' | AssetUri={0}' -f $sourceContext.RememberedInternetSource.Metadata.DownloadUri)
    }
    if ($sourceContext.RememberedInternetSource -and
        $sourceContext.RememberedInternetSource.Metadata -and
        $sourceContext.RememberedInternetSource.Metadata.AssetName) {
      $summary = $summary + (' | AssetName={0}' -f $sourceContext.RememberedInternetSource.Metadata.AssetName)
    }
  }

  Add-TextLineUtf8NoBom -Path $script:SummaryLogPath -Line $summary

  Write-Host ('Installed version {0} from {1} (zip hash {2}). Files changed: {3}.' -f $validated.PackageVersion, $sourceContext.SourceDisplay, (Get-ShortHash -Hash $zipHash), $filesCopied)

  ([ordered]@{
      PackageVersion = $validated.PackageVersion
      PackageName = $validated.PackageName
      ZipHash = $zipHash
      CacheZipPath = $cacheZipPath
      FilesCopied = $filesCopied
      FilesSkipped = $filesSkipped
    })
}

$mutex = $null
$state = $null
$sourcePlan = $null
$stageRoot = $null
$zipPath = $null
$script:InstallConfig = $null

try {
  if ($GenerateConfigPsd1) {
    Write-GchInstallConfigTemplate
    return
  }

  $script:InstallConfig = Resolve-GchInstallConfig -InputObject $Config
  $targetBin = Get-TargetBinPath
  Initialize-Paths -BinPath $targetBin
  Write-GchCustomConfigFiles -InstallConfig $script:InstallConfig -ConfigDir $script:ConfigDir
  Ensure-GchConfigFile -Path $script:GchConfigPath -RepoUrl $DEFAULT_REPO_URL -ShowAsPostponedWindowDays $DEFAULT_SHOW_AS_POSTPONED_WINDOW_DAYS
  $gchConfig = Read-GchConfigFile -Path $script:GchConfigPath
  if ((-not $InternalStageRun) -and ($null -eq $script:InstallConfig) -and (Test-GchConfigKey -Config $gchConfig -Key 'AutomaticUpdates') -and (Test-GchFalsyValue -Value (Get-GchConfigValue -Config $gchConfig -Key 'AutomaticUpdates'))) {
    Write-Warning "Automatic updates are disabled by '$script:GchConfigPath'. install.ps1 will not make changes."
    return
  }
  if ((-not $InternalStageRun) -and [string]::IsNullOrWhiteSpace($Source) -and (Test-GchConfigKey -Config $gchConfig -Key 'RepoUrl')) {
    $Source = Resolve-GchConfiguredRepoUrl -RepoUrl ([string](Get-GchConfigValue -Config $gchConfig -Key 'RepoUrl'))
  }
  if (Test-GchConfigKey -Config $gchConfig -Key 'ShowAsPostponedWindowDays') {
    $null = Resolve-GchConfiguredNonNegativeInteger -Value (Get-GchConfigValue -Config $gchConfig -Key 'ShowAsPostponedWindowDays') -Key 'ShowAsPostponedWindowDays'
  }
  Remove-StaleInstallerArtifacts -TempDir $script:TempDir -BinPath $targetBin

  Write-Log -Message ('Starting install.ps1. InternalStageRun={0}; Bin={1}' -f $InternalStageRun, $targetBin)

  if (-not $SkipMutexAcquire) {
    if ($InternalStageRun) {
      $mutex = Enter-InstallMutex -BinPath $targetBin -WaitTimeoutSec 120
    }
    else {
      $mutex = Enter-InstallMutex -BinPath $targetBin -WaitTimeoutSec 0
    }
    Write-Log -Message ('Acquired installer mutex. InternalStageRun={0}' -f $InternalStageRun)
  }
  else {
    Write-Log -Message ('Skipping mutex acquisition. InternalStageRun={0}' -f $InternalStageRun)
  }

  $state = Read-InstallerState -Path $script:StatePath

  if ($InternalStageRun) {
    Invoke-StagedDeployment `
      -BinPath $targetBin `
      -StagedPackageRoot $StagedPackageRoot `
      -StagedZipPath $StagedZipPath `
      -SourceContextPath $SourceContextPath `
      -StatePath $script:StatePath `
      -TempDir $script:TempDir | Out-Null

    return
  }

  $sourcePlan = Resolve-SourcePlan `
    -State $state `
    -StatePath $script:StatePath `
    -Source $Source `
    -ForceRequery:$ForceRequery `
    -TempDir $script:TempDir

  $zipPath = [System.IO.Path]::GetFullPath([string]$sourcePlan.ZipPath)
  if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
    throw ('Resolved zip does not exist: {0}' -f $zipPath)
  }

  $zipHash = Get-FileSha256Hex -Path $zipPath
  $zipHash8 = Get-ShortHash -Hash $zipHash

  $sourcePlan.SourceContext.Candidate.ZipPath = $zipPath
  $sourcePlan.SourceContext.Candidate.ZipName = [System.IO.Path]::GetFileName($zipPath)
  $sourcePlan.SourceContext.Candidate.ZipHash = $zipHash
  $sourcePlan.SourceContext.Candidate.ZipHash8 = $zipHash8

  Write-Log -Message ('Resolved source zip: {0} (hash {1})' -f $zipPath, $zipHash8)

  if ((-not $Reinstall) -and (-not $DevMode) -and $state.LastSuccessfulInstall -and ([string]$state.LastSuccessfulInstall.InstalledZipHash -eq $zipHash)) {
    Write-Log -Message ('Zip hash {0} matches installed state; skipping deployment.' -f $zipHash8)

    $latestState = Read-InstallerState -Path $script:StatePath
    $newState = Build-StateAfterNoOp `
      -OldState $latestState `
      -SourceContext $sourcePlan.SourceContext `
      -ZipHash $zipHash `
      -TempDir $script:TempDir

    Save-InstallerState -Path $script:StatePath -State $newState

    Write-Host ('Already current. Installed zip hash is {0}.' -f $zipHash8)
    return
  }

  $stageRoot = Get-NewStagePath -TempDir $script:TempDir
  Write-Log -Message ('Extracting zip to stage: {0}' -f $stageRoot)
  Expand-ZipToStage -ZipPath $zipPath -StageRoot $stageRoot

  # Validate before handoff so internal run never starts from an unchecked package.
  $validated = Test-StagedPackage -StageRoot $stageRoot
  $sourcePlan.SourceContext.Candidate.PackageName = $validated.PackageName
  $sourcePlan.SourceContext.Candidate.PackageVersion = $validated.PackageVersion

  if ($DevMode) {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath) -or (-not (Test-Path -LiteralPath $PSCommandPath -PathType Leaf))) {
      throw 'DevMode requires a valid current script path ($PSCommandPath).'
    }

    Write-Log -Message ('DevMode enabled: replacing staged installer with current script: {0}' -f $PSCommandPath)
    Copy-FileAtomic -SourcePath $PSCommandPath -DestinationPath $validated.InstallerPath
  }

  $contextPath = Join-Path $stageRoot 'install-gch-source-context.json'
  Write-JsonFile -Path $contextPath -Object $sourcePlan.SourceContext

  Write-Log -Message ('Staged package validated. Version={0}; Package={1}; SyntaxFilesChecked={2}' -f $validated.PackageVersion, $validated.PackageName, $validated.SyntaxFilesChecked)
  Write-Log -Message 'Preparing staged installer handoff.'

  $powershellExe = Join-Path $PSHOME 'powershell.exe'
  $handoffInstallerPath = $validated.InstallerPath
  if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath -PathType Leaf)) {
    $handoffInstallerPath = $PSCommandPath
  }

  $handoffArgs = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $handoffInstallerPath,
    '-InternalStageRun',
    '-SkipMutexAcquire',
    '-PathToBin', $targetBin,
    '-StagedPackageRoot', $validated.PackageRoot,
    '-StagedZipPath', $zipPath,
    '-SourceContextPath', $contextPath,
    '-DetailedLogPath', $script:DetailedLogPath
  )

  if ($Reinstall) {
    $handoffArgs += '-Reinstall'
  }

  if ($VerbosePreference -eq 'Continue') {
    $handoffArgs += '-Verbose'
  }

  Write-Log -Message ('Launching staged install with installer: {0}' -f $handoffInstallerPath)
  & $powershellExe @handoffArgs
  $handoffExitCode = $LASTEXITCODE
  if ($handoffExitCode -ne 0) {
    throw ('Staged installer failed with exit code {0}.' -f $handoffExitCode)
  }

  Write-Log -Message 'Staged installer handoff completed successfully.'
}
catch {
  $msg = $_.Exception.Message
  if ($msg) {
    Write-Log -Level ERROR -Message $msg
  }
  throw
}
finally {
  if ($stageRoot -and (Test-Path -LiteralPath $stageRoot)) {
    try {
      Remove-Item -LiteralPath $stageRoot -Recurse -Force
      Write-Log -Message ('Removed stage folder: {0}' -f $stageRoot)
    }
    catch {
      Write-Log -Level WARN -Message ('Could not remove stage folder {0}: {1}' -f $stageRoot, $_.Exception.Message)
    }
  }

  if ((-not $InternalStageRun) -and $sourcePlan -and $sourcePlan.IsTemporaryZip -and $zipPath -and (Test-Path -LiteralPath $zipPath)) {
    try {
      Remove-Item -LiteralPath $zipPath -Force
      Write-Log -Message ('Removed temporary downloaded zip: {0}' -f $zipPath)
    }
    catch {
      Write-Log -Level WARN -Message ('Could not remove temporary downloaded zip {0}: {1}' -f $zipPath, $_.Exception.Message)
    }
  }

  Exit-InstallMutex -Mutex $mutex
}
