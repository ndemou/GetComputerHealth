<#
.SYNOPSIS
Updates and then runs Get-ComputerHealth locally and/or via PowerShell remoting across multiple target computers, exports CLIXML plus HTML reports, and emails a summary.

.DESCRIPTION
Wraps `.\bin\Get-ComputerHealth.ps1` to support multiple targets (including an AD-derived "all domain servers" set), then collects all returned health messages into CLIXML data files and optionally emails "notable" (non-suppressed, non-pass/info/debug/help) messages with an attached interactive HTML report.

Per target:
- Runs `.\bin\Update-GetHealthCode.ps1` then executes `.\bin\Get-ComputerHealth.ps1` with `-OutputObjects -OutputConsoleMessages`, plus the provided filters and optional custom tests folder (`.\config\Custom-HealthTests\`).
- For remote targets, checks basic TCP reachability and if reachable, uses `New-PSSession` to run the tests.

After collection:
- Exports all messages to `${DATA_DIR}\all-messages-<timestamp>.clixml`
- Exports notable messages (if any) to `${DATA_DIR}\notable-messages-<timestamp>.clixml`
- Generates an interactive HTML report for notable messages and attaches it to email when notable messages exist

Other effects:
- Starts a transcript at `.\log\Invoke-GetHealthDomainComputers-<timestamp>.log`.
- Sends email and may attach the notable-messages HTML report.

Dependencies & execution context:
- Requires `.\bin\lib-write-log-objects.ps1` (dot-sourced) for logging/report export helper(s).
- Requires these local scripts to exist and be runnable (locally and on remotes):
  - `.\bin\Update-GetHealthCode.ps1`
  - `.\bin\Get-ComputerHealth.ps1`
  - `.\bin\Send-Message.ps1` and `.\config\Send-Message.conf`
- Remote execution requires WinRM / PowerShell remoting connectivity and permissions sufficient to create sessions and run the above scripts remotely.

.PARAMETER Computers
Optional list of target hostnames. If omitted, defaults to the local computer.
Accepts whitespace/comma-separated input (e.g. `"srv1,srv2"` or `"srv1 srv2"`).
Special token `ALL_DOMAIN_SERVERS` expands to all AD computer objects with `operatingSystem=*Server*` (optionally excluding some via `-ExcludeServers`).

.PARAMETER IpsOfAllDcs
Array of IPv4 addresses for all domain controllers. Passed through to `Get-ComputerHealth.ps1` as `-IpsOfAllDcs`.
When provided, the value is cached to `.\temp\cache.IpsOfAllDcs.clixml`.
When omitted, the script reuses the cached value if that file exists.

.PARAMETER ExcludeServers
One or more hostnames to remove from the `ALL_DOMAIN_SERVERS` expansion.

.PARAMETER Hide
Passed through to Get-ComputerHealth as `-Hide`. Default: `DIP`.

.PARAMETER WhitelistSigs
Passed through to Get-ComputerHealth as suppression signatures for this run (script passes it as `-SuppressSigs`).

.PARAMETER OnlyTheseTests
Passed through to Get-ComputerHealth as `-OnlyTheseTests` (limits which tests run).

.PARAMETER ExcludeTests
Passed through to Get-ComputerHealth as `-ExcludeTests` (skips selected tests).

.PARAMETER NoUpdate
Skips execution of `.\bin\Update-GetHealthCode.ps1` before running `Get-ComputerHealth.ps1` on each target.

.PARAMETER RunWithoutElevation
Passes `-RunWithoutElevation` through to `Get-ComputerHealth.ps1` on each target, bypassing its normal elevation guard.

.PARAMETER PushUpdate
When targeting remote computers, copies the latest locally cached release zip from `${TEMP_DIR}` to each target and runs `Update-GetHealthCode.ps1 -UpdateFromZip <copied-zip>` before tests.

.PARAMETER NoSendReport
Suppresses email sending regardless of whether the script is running in an interactive or non-interactive context.
Aliases: `NoSendMessage`, `NoSendMail`.

.PARAMETER SendReport
Forces email sending regardless of whether the script is running in an interactive or non-interactive context.

.NOTES ON EMAIL DEFAULTS
- In an interactive session, email sending defaults to off.
- In a non-interactive session, email sending defaults to on.
- When you run this script after `Enter-PSSession`, the remote PowerShell host can look non-interactive to the script even though you are typing at an interactive prompt. This behavior is expected; use `-NoSendReport` in that case if you do not want the default email report.
- `-NoSendReport` overrides the default and disables email sending.
- `-SendReport` overrides the default and enables email sending.

.EXAMPLE
# Run against the local computer, export report data, and email if notable messages exist:
.\Invoke-GetComputerHealth.ps1

.EXAMPLE
# Run against all domain servers, excluding one, and keep console noise low:
.\Invoke-GetComputerHealth.ps1 -Computers ALL_DOMAIN_SERVERS -ExcludeServers SRV1 -Hide DIP

.EXAMPLE
# Run a small set of tests across domain servers plus a couple of extra targets:
.\Invoke-GetComputerHealth.ps1 -Computers ALL_DOMAIN_SERVERS,APP01,FS01 -OnlyTheseTests HealthTest-ShareReasonableness,HealthTest-ListShares

.NOTES
- AD enumeration for `ALL_DOMAIN_SERVERS` uses `System.DirectoryServices` (LDAP/GC) and DNS SRV lookup to choose a DC if needed.
- Remote targets are executed via PowerShell remoting sessions; ensure WinRM is enabled and reachable (5985/5986) and that `.\bin\` and `.\config\` content exists on the remote machines as referenced.
- Output paths used:
  - Transcript: `.\log\Invoke-GetHealthDomainComputers-<timestamp>.log`
- Data: `${DATA_DIR}\all-messages-<timestamp>.clixml`, `${DATA_DIR}\notable-messages-<timestamp>.clixml`
- HTML: `${DATA_DIR}\notable-messages-<timestamp>.html`
#>

param(
  [string]$Hide = "DIP",
  [string]$WhitelistSigs,
  [string]$OnlyTheseTests,
  [string]$ExcludeTests,
  [string[]]$ExcludeServers = @(),
  [Alias('DebugSkipSlowTests')]
  [switch]$SkipSlowTests,
  [switch]$SkipPolicyTests,
  [Alias('Quick')]
  [switch]$SkipNonEssentialTests,
  [switch]$NoUpdate,
  [switch]$RunWithoutElevation,
  [switch]$PushUpdate,
  [Alias('NoSendMessage', 'NoSendMail')]
  [switch]$NoSendReport,
  [switch]$SendReport,
  [string[]]$IpsOfAllDcs = @(),
  [string[]]$Computers,
  [Parameter(DontShow = $true)]
  [switch]$AlreadyReranAfterUpdate,
  [Parameter(ValueFromRemainingArguments = $true)]
  [object[]]$PassThruArgs = @()
)

if ($null -ne $Hide) {
  $Hide = ([string]$Hide).ToUpperInvariant()
}

#------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------

$SCRIPT_BIN_DIR = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$ROOT_DIR = Split-Path -Parent $SCRIPT_BIN_DIR
$CONFIG_DIR = Join-Path $ROOT_DIR 'config'
$TEMP_DIR = Join-Path $ROOT_DIR 'temp'
$DATA_DIR = Join-Path $ROOT_DIR 'data'
$LOG_DIR = Join-Path $ROOT_DIR 'log'
$UPDATE_SCRIPT_PATH = Join-Path $SCRIPT_BIN_DIR 'Update-GetHealthCode.ps1'
$GET_HEALTH_SCRIPT_PATH = Join-Path $SCRIPT_BIN_DIR 'Get-ComputerHealth.ps1'
$SEND_MESSAGE_SCRIPT_PATH = Join-Path $SCRIPT_BIN_DIR 'Send-Message.ps1'
$LIB_LOG_OBJECTS_PATH = Join-Path $SCRIPT_BIN_DIR 'lib-write-log-objects.ps1'
$VERSION_FILE_PATH = Join-Path $SCRIPT_BIN_DIR 'VERSION'
$IPS_OF_ALL_DCS_CACHE_PATH = Join-Path $TEMP_DIR 'cache.IpsOfAllDcs.clixml'
$PROJECT_URL = 'https://github.com/ndemou/GetComputerHealth'
$GCH_CONFIG_PATH = Join-Path $CONFIG_DIR 'gch.psd1'
$SHOW_AS_POSTPONED_WINDOW_DAYS = 150
$REPORTING_SCRIPT_PATH = Join-Path $SCRIPT_BIN_DIR 'reporting.ps1'
. $REPORTING_SCRIPT_PATH
#------------------------------------------------------------------------
# Functions
#------------------------------------------------------------------------

function Get-CachedIpsOfAllDcs {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$CachePath
  )

  if (-not (Test-Path -LiteralPath $CachePath -PathType Leaf)) {
    return @()
  }

  try {
    $cachedValue = Import-Clixml -LiteralPath $CachePath -ErrorAction Stop
    return @(
      @($cachedValue) |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
  }
  catch {
    Write-Verbose "Failed reading cached IpsOfAllDcs from '$CachePath': $($_.Exception.Message)"
    return @()
  }
}

function Set-CachedIpsOfAllDcs {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$CachePath,
    [Parameter(Mandatory)][string[]]$IpsOfAllDcs
  )

  $cacheDir = Split-Path -Parent $CachePath
  if (-not [string]::IsNullOrWhiteSpace($cacheDir) -and (-not (Test-Path -LiteralPath $cacheDir -PathType Container))) {
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
  }

  @($IpsOfAllDcs) | Export-Clixml -LiteralPath $CachePath -Force
}

function Resolve-IpsOfAllDcs {
  [CmdletBinding()]
  param(
    [string[]]$IpsOfAllDcs = @(),
    [switch]$WasProvided,
    [Parameter(Mandatory)][string]$CachePath
  )

  if ($WasProvided) {
    $resolvedIps = @(
      @($IpsOfAllDcs) |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    if ($resolvedIps.Count -gt 0) {
      Set-CachedIpsOfAllDcs -CachePath $CachePath -IpsOfAllDcs $resolvedIps
      Write-Verbose "Cached IpsOfAllDcs to '$CachePath'"
    }

    return $resolvedIps
  }

  $cachedIps = @(Get-CachedIpsOfAllDcs -CachePath $CachePath)
  if ($cachedIps.Count -gt 0) {
    Write-Verbose "Using cached IpsOfAllDcs from '$CachePath'"
  }
  return $cachedIps
}

function Remove-OldInvokeTranscriptLogs {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$LogDir,
    [datetime]$CutoffDate = (Get-Date).AddMonths(-1)
  )

  if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) {
    return
  }

  try {
    $oldLogs = @(
      Get-ChildItem -LiteralPath $LogDir -File -Filter 'Invoke-GetHealthDomainComputers-*.log' -ErrorAction Stop |
        Where-Object { $_.LastWriteTime -lt $CutoffDate }
    )
  } catch {
    Write-Warning ("Failed enumerating old Invoke-GetComputerHealth transcript logs in {0}: {1}" -f $LogDir, $_.Exception.Message)
    return
  }

  foreach ($log in $oldLogs) {
    try {
      Remove-Item -LiteralPath $log.FullName -Force -ErrorAction Stop
    } catch {
      Write-Warning ("Failed deleting old Invoke-GetComputerHealth transcript log '{0}': {1}" -f $log.FullName, $_.Exception.Message)
    }
  }
}

function Read-GchConfigFile {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return @{}
  }

  try {
    $config = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
  } catch {
    throw "Failed reading configuration file '$Path': $($_.Exception.Message)"
  }

  if ($null -eq $config) {
    return @{}
  }

  return $config
}

function Test-GchConfigKey {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Config,
    [Parameter(Mandatory)][string]$Key
  )

  if ($Config -is [hashtable]) {
    return $Config.ContainsKey($Key)
  }

  return ($Config.PSObject.Properties[$Key] -ne $null)
}

function Get-GchConfigValue {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Config,
    [Parameter(Mandatory)][string]$Key
  )

  if ($Config -is [hashtable]) {
    return $Config[$Key]
  }

  return $Config.$Key
}

function Resolve-GchConfiguredNonNegativeInteger {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$Value,
    [Parameter(Mandatory)][string]$Key
  )

  $text = ([string]$Value).Trim()
  $number = 0
  if (([string]::IsNullOrWhiteSpace($text)) -or (-not [int]::TryParse($text, [ref]$number)) -or ($number -lt 0)) {
    throw "Invalid $Key value in gch.psd1: '$Value'. Use an integer greater than or equal to 0."
  }

  return $number
}

function Resolve-GetComputerHealthRuntimeRoot {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$RootDir)

  $currentMainScript = Join-Path (Join-Path $RootDir 'bin') 'Get-ComputerHealth.ps1'
  if (Test-Path -LiteralPath $currentMainScript -PathType Leaf) {
    return $RootDir
  }

  if ((Split-Path -Leaf $RootDir) -ieq 'Get-ComputerHealth') {
    $legacyRoot = Split-Path -Parent $RootDir
    $legacyMainScript = Join-Path (Join-Path $legacyRoot 'bin') 'Get-ComputerHealth.ps1'
    if (Test-Path -LiteralPath $legacyMainScript -PathType Leaf) {
      return $legacyRoot
    }
  }

  $migratedRoot = Join-Path $RootDir 'Get-ComputerHealth'
  $migratedMainScript = Join-Path (Join-Path $migratedRoot 'bin') 'Get-ComputerHealth.ps1'
  if (Test-Path -LiteralPath $migratedMainScript -PathType Leaf) {
    return $migratedRoot
  }

  return $RootDir
}

function Get-DomainServers {
  [CmdletBinding()]
  param(
    [string]$Domain = $env:USERDNSDOMAIN,
    [switch]$ExcludeDomainControllers,
    [string]$Server,                  # optional: dc01.corp.local
    [switch]$UseGlobalCatalog,        # query GC (3268) if set
    [System.Management.Automation.PSCredential]$Credential
  )

  if (-not $Domain) { throw "No domain detected. Provide -Domain." }

  $results = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)

  # 1) Pick a DC to talk to if not provided
  if (-not $Server) {
    try {
      $srv = Resolve-DnsName -Type SRV ("_ldap._tcp.dc._msdcs.{0}" -f $Domain) -ErrorAction Stop |
      Sort-Object -Property NameTarget -Unique
      $Server = $srv[0].NameTarget.TrimEnd('.')
    }
    catch {
      Write-Warning "Failed to resolve SRV records for $Domain. You can pass -Server dc.example.com. $_"
      return
    }
  }

  # 2) Discover naming context
  try {
    $rootDsePath = if ($UseGlobalCatalog) { "GC://$Server/RootDSE" } else { "LDAP://$Server/RootDSE" }
    $root = New-Object System.DirectoryServices.DirectoryEntry($rootDsePath)
    if ($Credential) {
      $root.Username = $Credential.UserName
      $root.Password = $Credential.GetNetworkCredential().Password
      $root.AuthenticationType = [System.DirectoryServices.AuthenticationTypes]::Secure
    }
    $nc = $root.Properties["defaultNamingContext"][0]
    if (-not $nc) { throw "defaultNamingContext not found." }
  }
  catch {
    Write-Warning "Could not bind to RootDSE on $Server ($rootDsePath): $($_.Exception.Message)"
    return
  }

  # 3) Build a searcher
  try {
    $basePath = if ($UseGlobalCatalog) { "GC://$Server/$nc" } else { "LDAP://$Server/$nc" }
    $searchRoot = New-Object System.DirectoryServices.DirectoryEntry($basePath)
    if ($Credential) {
      $searchRoot.Username = $Credential.UserName
      $searchRoot.Password = $Credential.GetNetworkCredential().Password
      $searchRoot.AuthenticationType = [System.DirectoryServices.AuthenticationTypes]::Secure
    }

    $ds = New-Object System.DirectoryServices.DirectorySearcher($searchRoot)
    $ds.PageSize = 1000
    $ds.ServerTimeLimit = [TimeSpan]::FromSeconds(15)
    $ds.ClientTimeout = [TimeSpan]::FromSeconds(30)
    $ds.ReferralChasing = [System.DirectoryServices.ReferralChasingOption]::All
    [void]$ds.PropertiesToLoad.AddRange(@('dNSHostName', 'name', 'operatingSystem', 'userAccountControl', 'primaryGroupID'))

    $dcExclusion = if ($ExcludeDomainControllers) { '(!(primaryGroupID=516))(!(userAccountControl:1.2.840.113556.1.4.803:=8192))' } else { '' }
    $ds.Filter = "(&(objectCategory=computer)(operatingSystem=*Server*)$dcExclusion)"

    foreach ($r in $ds.FindAll()) {
      $dns = $r.Properties['dnshostname']
      $name = $r.Properties['name']
      if ($dns -and $dns[0]) { [void]$results.Add($dns[0]) }
      elseif ($name -and $name[0]) { [void]$results.Add($name[0]) }
    }
  }
  catch {
    Write-Warning ("Get-DomainServers failed against {0}: {1}" -f $Server, $_.Exception.Message)
    Write-Warning "Tips: verify DNS for $Domain, connectivity to $Server, time sync, and firewall for 389/636 (LDAP/LDAPS) and 3268/3269 (GC)."
    return
  }

  $results
}

function Get-TcpPortStateFast ($hostname, $ports, $timeout = 100) {
  $tcpobj = @{}; $open = @{}; $requestCallback = $state = $null;
  foreach ($port in $ports) {
    $tcpobj[$port] = New-Object System.Net.Sockets.TcpClient; $null = $tcpobj[$port].BeginConnect($hostname, $port, $requestCallback, $state)
  }
  Start-Sleep -milli $timeOut;
  foreach ($port in $ports) {
    $open = ($tcpobj[$port].Connected); $tcpobj[$port].Close(); [pscustomobject]@{port = $port; open = $open }
  }
}

function Get-LatestLocalReleaseZip {
  [CmdletBinding()]
  param(
    [string]$CacheDir = $TEMP_DIR,
    [string]$ConfigDir = $CONFIG_DIR,
    [string[]]$Patterns = @('GetComputerHealth-release-*.zip', 'GetComputerHealth-MANUAL-UPDATE-*.zip')
  )

  try {
    $metadataPath = Join-Path $ConfigDir 'Get-ComputerHealth-latest-release-meta.json'
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
      try {
        $metaRaw = Get-Content -LiteralPath $metadataPath -Raw -ErrorAction Stop
        $meta = $metaRaw | ConvertFrom-Json -ErrorAction Stop
        $markerPath = [string]$meta.installedReleaseMarker
        if (
          -not [string]::IsNullOrWhiteSpace($markerPath) -and
          ($markerPath -match '(?i)\.zip$') -and
          (Test-Path -LiteralPath $markerPath -PathType Leaf)
        ) {
          return (Resolve-Path -LiteralPath $markerPath -ErrorAction Stop).Path
        }
      }
      catch {
        # Fall through to cache-based selection.
      }
    }

    $candidates = @()
    foreach ($pattern in $Patterns) {
      $candidates += @(Get-ChildItem -LiteralPath $CacheDir -File -Filter $pattern -ErrorAction SilentlyContinue)
    }
    return ($candidates |
      Sort-Object -Property LastWriteTime -Descending |
      Select-Object -First 1 -ExpandProperty FullName)
  }
  catch {
    return $null
  }
}

function Get-UpdateZipVersionArgument {
  [CmdletBinding()]
  param(
    [string]$ZipPath,
    [string]$FallbackVersion
  )

  if ([string]::IsNullOrWhiteSpace($ZipPath)) {
    return $null
  }

  $zipLeaf = Split-Path -Path $ZipPath -Leaf
  if (-not [string]::IsNullOrWhiteSpace($zipLeaf) -and ($zipLeaf -match '(?i)\bv\d+\.\d+\.\d+\b')) {
    return $null
  }

  if ([string]::IsNullOrWhiteSpace($FallbackVersion)) {
    return $null
  }

  return $FallbackVersion
}

function Get-UpdateZipEmbeddedVersion {
  [CmdletBinding()]
  param(
    [string]$ZipPath,
    [string]$FallbackVersion
  )

  if ([string]::IsNullOrWhiteSpace($ZipPath)) {
    return $null
  }

  $zipLeaf = Split-Path -Path $ZipPath -Leaf
  if (-not [string]::IsNullOrWhiteSpace($zipLeaf) -and ($zipLeaf -match '(?i)\bv(?<Version>\d+\.\d+\.\d+)\b')) {
    return $Matches['Version']
  }

  if ([string]::IsNullOrWhiteSpace($FallbackVersion)) {
    return $null
  }

  return $FallbackVersion
}

function Convert-BoundParametersToInvocationArguments {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$BoundParameters,
    [string[]]$Exclude = @()
  )

  $arguments = @()
  foreach ($entry in $BoundParameters.GetEnumerator() | Sort-Object -Property Name) {
    if ($entry.Key -in $Exclude) { continue }

    $value = $entry.Value
    if ($value -is [System.Management.Automation.SwitchParameter]) {
      if ($value.IsPresent) { $arguments += "-$($entry.Key)" }
      continue
    }

    if ($null -eq $value) { continue }

    $arguments += "-$($entry.Key)"
    if ($value -is [array]) {
      $arguments += @($value)
    }
    else {
      $arguments += $value
    }
  }

  return $arguments
}

function Invoke-SelfAfterUpdate {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$BoundParameters,
    [object[]]$PassThruArgs = @()
  )

  $rerunArgs = @()
  # Put the internal rerun marker first so it cannot be consumed as a value of a preceding multi-value argument.
  $rerunArgs += '-AlreadyReranAfterUpdate'
  $rerunArgs += @(
    Convert-BoundParametersToInvocationArguments -BoundParameters $BoundParameters -Exclude @('AlreadyReranAfterUpdate', 'PassThruArgs')
  )
  $rerunArgs += @($PassThruArgs)

  $powerShellExe = (Get-Process -Id $PID).Path
  if ([string]::IsNullOrWhiteSpace($powerShellExe)) {
    $powerShellExe = 'powershell.exe'
  }

  & $PSCommandPath @rerunArgs
  return
}

#------------------------------------------------------------------------
# MAIN CODE
#------------------------------------------------------------------------

$timestamp = $(get-date -Format 'yyyy-MM-dd_HH.mm')
if (-not (Test-Path -LiteralPath $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null }
if (-not (Test-Path -LiteralPath $TEMP_DIR)) { New-Item -ItemType Directory -Path $TEMP_DIR -Force | Out-Null }
if (-not (Test-Path -LiteralPath $DATA_DIR)) { New-Item -ItemType Directory -Path $DATA_DIR -Force | Out-Null }
Remove-OldInvokeTranscriptLogs -LogDir $LOG_DIR

$gchConfig = Read-GchConfigFile -Path $GCH_CONFIG_PATH
if (Test-GchConfigKey -Config $gchConfig -Key 'ShowAsPostponedWindowDays') {
  $SHOW_AS_POSTPONED_WINDOW_DAYS = Resolve-GchConfiguredNonNegativeInteger -Value (Get-GchConfigValue -Config $gchConfig -Key 'ShowAsPostponedWindowDays') -Key 'ShowAsPostponedWindowDays'
}

$localEmbeddedVersion = Get-EmbeddedGetComputerHealthVersion -ScriptPath $GET_HEALTH_SCRIPT_PATH
$localUpdateAlreadyRan = $false
if (-not $NoUpdate) {
  $versionBeforeUpdate = $localEmbeddedVersion
  try {
    & $UPDATE_SCRIPT_PATH
    $localUpdateAlreadyRan = $true
    $versionAfterUpdate = Get-EmbeddedGetComputerHealthVersion -ScriptPath $GET_HEALTH_SCRIPT_PATH
    $localEmbeddedVersion = $versionAfterUpdate

    if (
      -not $AlreadyReranAfterUpdate -and
      -not [string]::IsNullOrWhiteSpace($versionBeforeUpdate) -and
      -not [string]::IsNullOrWhiteSpace($versionAfterUpdate) -and
      $versionBeforeUpdate -ne $versionAfterUpdate
    ) {
      Write-Host -ForegroundColor Yellow "Get-ComputerHealth was updated from version $versionBeforeUpdate to $versionAfterUpdate. Re-running Invoke-GetComputerHealth.ps1 once."
      # Do not continue in the pre-update process after the updated copy has been invoked.
      Invoke-SelfAfterUpdate -BoundParameters $PSBoundParameters -PassThruArgs $PassThruArgs
      return
    }
  }
  catch {
    Write-Warning "Early update check failed: $($_.Exception.Message). Continuing with normal target execution."
  }
}

Start-Transcript (Join-Path $LOG_DIR "Invoke-GetHealthDomainComputers-$timestamp.log")
. $LIB_LOG_OBJECTS_PATH
$IpsOfAllDcs = Resolve-IpsOfAllDcs -IpsOfAllDcs $IpsOfAllDcs -WasProvided:$PSBoundParameters.ContainsKey('IpsOfAllDcs') -CachePath $IPS_OF_ALL_DCS_CACHE_PATH

if ($ExcludeServers) {
  $ExcludeServers = $ExcludeServers | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ }
  write-verbose "`$ExcludeServers: $($ExcludeServers -join ';')"
}

if (-not $Computers) {
  $targets = @($env:COMPUTERNAME)
}
else {
  $targets = $Computers | ForEach-Object { $_ -split '[,\s]+' } | ForEach-Object { $_ -replace '\s' } | Where-Object { $_ }
}
if ('ALL_DOMAIN_SERVERS' -in $targets) {
  write-verbose "Adding domain servers"
  $domainServers = (Get-DomainServers | ForEach-Object { $_ -replace '[.].*' -replace '\s' } | Where-Object { $_ -notin $ExcludeServers })
  $targets = ($targets | Where-Object { $_ -ne 'ALL_DOMAIN_SERVERS' }) + $domainServers
}
$targets = @($targets | Sort-Object)

write-verbose "Targets: $($targets -join ';')"

$hasRemoteTargets = @($targets | Where-Object { $_ -ne $env:COMPUTERNAME }).Count -gt 0
$localReleaseZip = $null
$localReleaseZipVersion = $null
$localReleaseZipEmbeddedVersion = $null
$controllerCanPushUpdate = $false
if ((-not $NoUpdate) -and $hasRemoteTargets) {
  $localReleaseZip = Get-LatestLocalReleaseZip
  if (-not $localReleaseZip) {
    if ($PushUpdate) {
      Write-Warning "-PushUpdate was requested but no local update zip was found (metadata marker or cached zip in ${TEMP_DIR}). Falling back to normal update behavior."
    }
  } else {
    $localReleaseZipVersion = Get-UpdateZipVersionArgument -ZipPath $localReleaseZip -FallbackVersion $localEmbeddedVersion
    $localReleaseZipEmbeddedVersion = Get-UpdateZipEmbeddedVersion -ZipPath $localReleaseZip -FallbackVersion $localEmbeddedVersion
    if (
      (-not [string]::IsNullOrWhiteSpace($localReleaseZipEmbeddedVersion)) -and
      (-not [string]::IsNullOrWhiteSpace($localEmbeddedVersion)) -and
      ($localReleaseZipEmbeddedVersion -eq $localEmbeddedVersion)
    ) {
      $controllerCanPushUpdate = $true
    }
    else {
      Write-Warning ("Local update zip '{0}' does not match the controller's Get-ComputerHealth version {1}. Falling back to normal remote update behavior." -f $localReleaseZip, $localEmbeddedVersion)
    }
  }
}

$all_messages = @()
Write-host "`n`n`n"
foreach ($target in $targets) {
  Write-Progress -Activity "Checking $target" -Status "Phase #1 (preparing check)"
  if ($targets.count -gt 1) {
    Write-Host ""
    Write-Host -ForegroundColor DarkGray "Checking " -NoNewline
    Write-Host -ForegroundColor Cyan "$target" -NoNewline
    Write-Host -ForegroundColor DarkGray " at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  }

  # The code to run on the target Computer
  $healthCheckBlock = {
    param(
      $RootDir,
      $Hide,
      $OnlyTheseTests,
      $ExcludeTests,
      $WhitelistSigs,
      $SkipSlowTests,
      $SkipPolicyTests,
      $SkipNonEssentialTests,
      $NoUpdate,
      $RunWithoutElevation,
      $IpsOfAllDcs,
      $PushUpdate,
      $UpdateZipPath,
      $UpdateZipVersion,
      $ShowAsPostponedWindowDays,
      $PassThruArgs
    )

    function Resolve-GetComputerHealthRuntimeRootLocal {
      param([Parameter(Mandatory)][string]$CandidateRootDir)

      $currentMainScript = Join-Path (Join-Path $CandidateRootDir 'bin') 'Get-ComputerHealth.ps1'
      if (Test-Path -LiteralPath $currentMainScript -PathType Leaf) {
        return $CandidateRootDir
      }

      $migratedRoot = Join-Path $CandidateRootDir 'Get-ComputerHealth'
      $migratedMainScript = Join-Path (Join-Path $migratedRoot 'bin') 'Get-ComputerHealth.ps1'
      if (Test-Path -LiteralPath $migratedMainScript -PathType Leaf) {
        return $migratedRoot
      }

      return $CandidateRootDir
    }

    $resolvedRootDir = Resolve-GetComputerHealthRuntimeRootLocal -CandidateRootDir $RootDir
    $binDir = Join-Path $resolvedRootDir 'bin'
    $configDir = Join-Path $resolvedRootDir 'config'
    $updateScriptPath = Join-Path $binDir 'Update-GetHealthCode.ps1'
    $getHealthScriptPath = Join-Path $binDir 'Get-ComputerHealth.ps1'
    $logLibPath = Join-Path $binDir 'lib-write-log-objects.ps1'
    $customTestsDir = Join-Path $configDir 'Custom-HealthTests'
    $suppressionFilePath = Join-Path $configDir 'Get-ComputerHealth.sigs-to-suppress.txt'
    $records = New-Object System.Collections.Generic.List[object]

    function Get-HealthSuppressionExpiryMapLocal {
      param(
        [Parameter(Mandatory)][string]$Path,
        [datetime]$Today = (Get-Date).Date
      )

      $map = @{}
      if ([string]::IsNullOrWhiteSpace($Path)) { return $map }
      if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $map }

      $lines = Get-Content -Encoding utf8 -LiteralPath $Path -ErrorAction SilentlyContinue
      foreach ($line in $lines) {
        if ($null -eq $line) { continue }

        $line = ($line -replace '\s+#.*$', '').Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($line -match '^\[?([0-9A-Fa-f]{8})\]?(?:\s+until\s+(\d{4}-\d{2}-\d{2}))?$') {
          $hash8 = $Matches[1].ToLowerInvariant()

          if ($Matches[2]) {
            try {
              $expiry = [datetime]::ParseExact($Matches[2], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture).Date
            } catch {
              continue
            }

            if ($Today.Date -le $expiry) {
              $map[$hash8] = $expiry
            } else {
              $map.Remove($hash8)
            }
          } else {
            $map[$hash8] = $null
          }
        }
      }

      return $map
    }

    function Get-HealthEffectiveLevelLocal {
      param(
        [string]$Level,
        [bool]$Suppressed,
        [AllowNull()][object]$SuppressedUntil,
        [int]$ShowAsPostponedWindowDays,
        [datetime]$Today = (Get-Date).Date
      )

      $realLevel = ([string]$Level).Trim().ToLowerInvariant()
      if ($Suppressed -and ($null -ne $SuppressedUntil)) {
        $suppressedUntilDate = [datetime]$SuppressedUntil
        $cutoffDate = $Today.Date.AddDays($ShowAsPostponedWindowDays)
        if (($Today.Date -le $suppressedUntilDate.Date) -and ($suppressedUntilDate.Date -le $cutoffDate)) {
          return 'postponed'
        }
      }

      return $realLevel
    }

    function Assert-NoInvokeGetComputerHealthOnlyPassThruArguments {
      # PassThruArgs are appended to the child Get-ComputerHealth.ps1 call.
      # Wrapper-only markers must never reach that child script; if they do,
      # fail loudly instead of silently dropping them and hiding a binding bug.
      [CmdletBinding()]
      param(
        [object[]]$Arguments = @(),
        [string]$DestinationScriptPath = 'Get-ComputerHealth.ps1'
      )

      foreach ($argument in @($Arguments)) {
        if ($null -eq $argument) { continue }

        $argumentText = [string]$argument
        if (($argumentText -ieq '-AlreadyReranAfterUpdate') -or ($argumentText -ieq '/AlreadyReranAfterUpdate')) {
          throw ("Internal Invoke-GetComputerHealth.ps1 argument '{0}' was about to be forwarded to {1}. This indicates an argument-binding bug in Invoke-GetComputerHealth.ps1." -f $argumentText, $DestinationScriptPath)
        }
      }
    }

    if (-not (Test-Path -LiteralPath $logLibPath)) {
      throw "Logging helper file not found: $logLibPath"
    }
    . $logLibPath

    if (-not $NoUpdate) {
      try {
        $updateOutput = if ($PushUpdate -and $UpdateZipPath) {
          if ([string]::IsNullOrWhiteSpace($UpdateZipVersion)) {
            & $updateScriptPath -UpdateFromZip $UpdateZipPath 2>&1
          } else {
            & $updateScriptPath -UpdateFromZip $UpdateZipPath -Version $UpdateZipVersion 2>&1
          }
        }
        else {
          & $updateScriptPath 2>&1
        }

        foreach ($item in @($updateOutput)) {
          if ($item -is [System.Management.Automation.ErrorRecord]) {
            $comment = ($item | Out-String).Trim()
            $records.Add((Log-Failure "PowerShell error while running Update-GetHealthCode.ps1" -Comment $comment)) | Out-Null
          }
        }

        $resolvedRootDir = Resolve-GetComputerHealthRuntimeRootLocal -CandidateRootDir $RootDir
        $binDir = Join-Path $resolvedRootDir 'bin'
        $configDir = Join-Path $resolvedRootDir 'config'
        $getHealthScriptPath = Join-Path $binDir 'Get-ComputerHealth.ps1'
        $customTestsDir = Join-Path $configDir 'Custom-HealthTests'
        $suppressionFilePath = Join-Path $configDir 'Get-ComputerHealth.sigs-to-suppress.txt'
      }
      catch {
        $records.Add((Log-Failure "Terminating error while running Update-GetHealthCode.ps1" -Comment (($_ | Out-String).Trim()))) | Out-Null
        return $records
      }
    }

    try {
      $getHealthParams = @{
        OutputObjects          = $true
        OutputConsoleMessages  = $true
        Hide                   = $Hide
        OnlyTheseTests         = $OnlyTheseTests
        ExcludeTests           = $ExcludeTests
        IncludeTestsFromFolder = $customTestsDir
        SuppressSigs           = $WhitelistSigs
        SkipSlowTests          = $SkipSlowTests
        SkipPolicyTests        = $SkipPolicyTests
        SkipNonEssentialTests  = $SkipNonEssentialTests
        RunWithoutElevation    = $RunWithoutElevation
        IpsOfAllDcs            = $IpsOfAllDcs
      }
      # Guard the argument interface between the wrapper and Get-ComputerHealth.ps1.
      Assert-NoInvokeGetComputerHealthOnlyPassThruArguments -Arguments $PassThruArgs -DestinationScriptPath $getHealthScriptPath
      $healthOutput = & $getHealthScriptPath @getHealthParams @PassThruArgs 2>&1
      $suppressionExpiryMap = Get-HealthSuppressionExpiryMapLocal -Path $suppressionFilePath

      foreach ($item in @($healthOutput)) {
        if ($item -is [System.Management.Automation.ErrorRecord]) {
          $records.Add((Log-Failure "PowerShell error while running Get-ComputerHealth.ps1" -Comment (($item | Out-String).Trim()))) | Out-Null
          continue
        }

        if ($item -and $item.PSObject.Properties['Level'] -and $item.PSObject.Properties['Message']) {
          $hash = if ($item.PSObject.Properties['Hash']) { [string]$item.Hash } else { '00000000' }
          $suppressed = if ($item.PSObject.Properties['Suppressed']) { [bool]$item.Suppressed } else { $false }
          $suppressedUntil = $null
          if ($suppressed -and $hash -and $suppressionExpiryMap.ContainsKey($hash.ToLowerInvariant())) {
            $suppressedUntil = $suppressionExpiryMap[$hash.ToLowerInvariant()]
          }
          $level = [string]$item.Level
          $records.Add([pscustomobject]@{
              TimeUtc    = if ($item.PSObject.Properties['TimeUtc']) { $item.TimeUtc } else { $null }
              Computer   = if ($item.PSObject.Properties['Computer']) { [string]$item.Computer } else { $env:COMPUTERNAME }
              Level      = $level
              EffectiveLevel = Get-HealthEffectiveLevelLocal -Level $level -Suppressed:$suppressed -SuppressedUntil $suppressedUntil -ShowAsPostponedWindowDays $ShowAsPostponedWindowDays
              Hash       = $hash
              Suppressed = $suppressed
              SuppressedUntil = $suppressedUntil
              Message    = [string]$item.Message
              Comment    = if ($item.PSObject.Properties['Comment']) { [string]$item.Comment } else { '' }
              Emitter    = if ($item.PSObject.Properties['Emitter']) { $item.Emitter } else { $null }
            }) | Out-Null
        }
      }
    }
    catch {
      $records.Add((Log-Failure "Terminating error while running Get-ComputerHealth.ps1" -Comment (($_ | Out-String).Trim()))) | Out-Null
    }

    return $records
  }

  if ($target -eq $env:COMPUTERNAME) {
    $skipTargetUpdate = $NoUpdate -or $localUpdateAlreadyRan
    $localHealthCheckParams = @{
      RootDir                   = $ROOT_DIR
      Hide                      = $Hide
      OnlyTheseTests            = $OnlyTheseTests
      ExcludeTests              = $ExcludeTests
      WhitelistSigs             = $WhitelistSigs
      SkipSlowTests             = $SkipSlowTests
      SkipPolicyTests           = $SkipPolicyTests
      SkipNonEssentialTests     = $SkipNonEssentialTests
      NoUpdate                  = $skipTargetUpdate
      RunWithoutElevation       = $RunWithoutElevation
      IpsOfAllDcs               = $IpsOfAllDcs
      PushUpdate                = $PushUpdate
      UpdateZipPath             = $localReleaseZip
      UpdateZipVersion          = $localReleaseZipVersion
      ShowAsPostponedWindowDays = $SHOW_AS_POSTPONED_WINDOW_DAYS
      PassThruArgs              = $PassThruArgs
    }
    $output = & $healthCheckBlock @localHealthCheckParams
  }
  else {
    Write-Progress -Activity "Checking $target" -Status "Phase #1 (probing reachability)"
    if (Get-TcpPortStateFast $target @(5985, 5986, 80, 443, 88, 135, 389, 636, 445, 3268, 3269) | Where-Object { $_.Open }) {
      $session = $null
      try {
        Write-Progress -Activity "Checking $target" -Status "Phase #1 (opening PowerShell session)"
        $session = New-PSSession -ComputerName $target

        Write-Progress -Activity "Checking $target" -Status "Phase #1 (preparing remote folders)"
        $remoteExecutionRoot = Invoke-Command -Session $session -ScriptBlock {
          param($RootDir)
          $resolvedRootDir = $RootDir

          $currentMainScript = Join-Path (Join-Path $resolvedRootDir 'bin') 'Get-ComputerHealth.ps1'
          if (-not (Test-Path -LiteralPath $currentMainScript -PathType Leaf) -and ((Split-Path -Leaf $resolvedRootDir) -ieq 'Get-ComputerHealth')) {
            $legacyRoot = Split-Path -Parent $resolvedRootDir
            $legacyMainScript = Join-Path (Join-Path $legacyRoot 'bin') 'Get-ComputerHealth.ps1'
            if (Test-Path -LiteralPath $legacyMainScript -PathType Leaf) {
              $resolvedRootDir = $legacyRoot
            }
          }

          $remoteBinDir = Join-Path $resolvedRootDir 'bin'
          $remoteTempDir = Join-Path $resolvedRootDir 'temp'
          if (-not (Test-Path $remoteBinDir)) { New-Item -Path $remoteBinDir  -ItemType Directory -Force | Out-Null }
          if (-not (Test-Path $remoteTempDir)) { New-Item -Path $remoteTempDir -ItemType Directory -Force | Out-Null }
          return $resolvedRootDir
        } -ArgumentList $ROOT_DIR

        Write-Progress -Activity "Checking $target" -Status "Phase #1 (reading remote Get-ComputerHealth version)"
        $remoteEmbeddedVersion = Invoke-Command -Session $session -ScriptBlock {
          param($ExecutionRoot)

          $remoteMainScriptPath = Join-Path (Join-Path $ExecutionRoot 'bin') 'Get-ComputerHealth.ps1'
          if (-not (Test-Path -LiteralPath $remoteMainScriptPath -PathType Leaf)) {
            return ''
          }

          try {
            $content = Get-Content -LiteralPath $remoteMainScriptPath -Raw -ErrorAction Stop
            $match = [regex]::Match($content, '(?m)^\$VERSION\s*=\s*"(?<Version>[^"]+)"')
            if ($match.Success) {
              return $match.Groups['Version'].Value
            }
          }
          catch {
            return ''
          }

          return ''
        } -ArgumentList $remoteExecutionRoot

        $skipTargetUpdate = $NoUpdate
        $pushTargetUpdate = $false
        if (
          (-not $skipTargetUpdate) -and
          (-not [string]::IsNullOrWhiteSpace($localEmbeddedVersion)) -and
          (-not [string]::IsNullOrWhiteSpace([string]$remoteEmbeddedVersion)) -and
          ([string]$remoteEmbeddedVersion).Trim() -eq $localEmbeddedVersion
        ) {
          $skipTargetUpdate = $true
          Write-Verbose ("Skipping updater copy/run on {0} because Get-ComputerHealth version {1} already matches local." -f $target, $localEmbeddedVersion)
        }
        elseif ((-not $skipTargetUpdate) -and $controllerCanPushUpdate) {
          $pushTargetUpdate = $true
          Write-Verbose ("Pushing validated local update zip to {0} because remote Get-ComputerHealth version '{1}' differs from local version '{2}'." -f $target, ([string]$remoteEmbeddedVersion).Trim(), $localEmbeddedVersion)
        }

        $localUpdaterPath = $UPDATE_SCRIPT_PATH
        $remoteUpdaterPath = Join-Path (Join-Path $remoteExecutionRoot 'bin') 'Update-GetHealthCode.ps1'

        if ((-not $skipTargetUpdate) -and (-not (Test-Path -LiteralPath $localUpdaterPath))) {
          throw "Local updater file not found: $localUpdaterPath"
        }

        if (-not $skipTargetUpdate) {
          Write-Progress -Activity "Checking $target" -Status "Phase #1 (copying updater)"
          Copy-Item -Path $localUpdaterPath -Destination $remoteUpdaterPath -ToSession $session -Force
        }

        $remoteZipPath = $null
        if ((-not $skipTargetUpdate) -and $pushTargetUpdate -and $localReleaseZip) {
          $remoteZipPath = Join-Path (Join-Path $remoteExecutionRoot 'temp') (Split-Path -Path $localReleaseZip -Leaf)
          Write-Progress -Activity "Checking $target" -Status "Phase #1 (copying update package)"
          Copy-Item -Path $localReleaseZip -Destination $remoteZipPath -ToSession $session -Force
        }

        Write-Progress -Activity "Checking $target" -Status "Phase #2 (running remote update and health checks)"
        $output = Invoke-Command -Session $session -ScriptBlock $healthCheckBlock -ArgumentList $remoteExecutionRoot, $Hide, $OnlyTheseTests, $ExcludeTests, $WhitelistSigs, $SkipSlowTests, $SkipPolicyTests, $SkipNonEssentialTests, $skipTargetUpdate, $RunWithoutElevation, $IpsOfAllDcs, $pushTargetUpdate, $remoteZipPath, $localReleaseZipVersion, $SHOW_AS_POSTPONED_WINDOW_DAYS, $PassThruArgs
      }
      catch {
        $comment = (($_ | Out-String).Trim())
        $null = Log-failure "Failed running update/health scripts on target $target"
        Write-Host -ForegroundColor Red ("  FAILURE: Failed running update/health scripts on target {0}" -f $target)
        if (-not [string]::IsNullOrWhiteSpace($comment)) {
          Write-Host -ForegroundColor DarkGray ("  #       {0}" -f ($comment -replace "(`r`n|`n|`r)", "`n  #       "))
        }
        $all_messages += [pscustomobject]@{
          Computer   = $target
          Level      = 'failure'
          Hash       = '00000000'
          Suppressed = $false
          Message    = "Failed running update/health scripts"
          Comment    = $comment
          Emitter    = $null
        }
        continue
      }
      finally {
        if ($session) { Remove-PSSession $session }
      }
    }
    else {
      if ($target -in $domainServers) {
        $comment = " (either it is down or you have a stale entry in your AD)"
      }
      else {
        $comment = " (are you sure a computer with that name exists?)"
      }
      $null = Log-failure "Target $target is unreachable $comment"
      $all_messages += [pscustomobject]@{
        Computer   = $target
        Level      = 'failure'
        Hash       = '00000000'
        Suppressed = $false
        Message    = "Target is unreachable $comment"
        Comment    = ""
        Emitter    = $null
      }
      continue
    }
  }

  $all_messages += $output
  Write-Progress -Activity "Checking $target" -Completed
}

Invoke-GetComputerHealthReporting `
  -Messages $all_messages `
  -NoSendReport:$NoSendReport `
  -SendReport:$SendReport `
  -Timestamp $timestamp `
  -Targets $targets

Stop-Transcript
