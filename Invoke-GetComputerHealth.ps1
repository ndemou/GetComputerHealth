<#
.SYNOPSIS
Updates and then runs Get-ComputerHealth locally and/or via PowerShell remoting across multiple target computers, exports Excel reports, and emails a summary.

.DESCRIPTION
Wraps `.\bin\Get-ComputerHealth.ps1` to support multiple targets (including an AD-derived "all domain servers" set), then collects all returned health messages into Excel workbooks and optionally emails "notable" (non-suppressed, non-pass/info/debug/help) messages.

Per target:
- Runs `.\bin\Update-GetHealthCode.ps1` then executes `.\bin\Get-ComputerHealth.ps1` with `-OutputObjects -OutputConsoleMessages`, plus the provided filters and optional custom tests folder (`.\config\Custom-HealthTests\`).
- For remote targets, checks basic TCP reachability and if reachable, uses `New-PSSession` to run the tests.

After collection:
- Exports all messages to `${TEMP_DIR}\all-messages-<timestamp>.xlsx`
- Exports notable messages (if any) to `${TEMP_DIR}\notable-messages-<timestamp>.xlsx`
- Sends email via `.\bin\Send-Message.ps1` (with attachment when notable messages exist)

Other effects:
- Requires the PowerShell module `ImportExcel` to be already installed (typically by `Update-GetHealthCode.ps1`).
- Starts a transcript at `.\log\Invoke-GetHealthDomainComputers-<timestamp>.log`.
- Sends email and may attach the notable-messages workbook.

Dependencies & execution context:
- Requires `.\bin\lib-write-log-objects.ps1` (dot-sourced) for logging/Excel export helper(s).
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
- `-NoSendReport` overrides the default and disables email sending.
- `-SendReport` overrides the default and enables email sending.

.EXAMPLE
# Run against the local computer, export Excel, and email if notable messages exist:
.\Invoke-GetComputerHealth.ps1

.EXAMPLE
# Run against all domain servers, excluding one, and keep console noise low:
.\Invoke-GetComputerHealth.ps1 -Computers ALL_DOMAIN_SERVERS -ExcludeServers SRV1 -Hide DIP

.EXAMPLE
# Run a small set of tests across domain servers plus a couple of extra targets:
.\Invoke-GetComputerHealth.ps1 -Computers ALL_DOMAIN_SERVERS,APP01,FS01 -OnlyTheseTests HealthTest-ShareReasonableness,HealthTest-NonDefaultShares

.NOTES
- AD enumeration for `ALL_DOMAIN_SERVERS` uses `System.DirectoryServices` (LDAP/GC) and DNS SRV lookup to choose a DC if needed.
- Remote targets are executed via PowerShell remoting sessions; ensure WinRM is enabled and reachable (5985/5986) and that `.\bin\` and `.\config\` content exists on the remote machines as referenced.
- Output paths used:
  - Transcript: `.\log\Invoke-GetHealthDomainComputers-<timestamp>.log`
  - Excel: `${TEMP_DIR}\all-messages-<timestamp>.xlsx`, `${TEMP_DIR}\notable-messages-<timestamp>.xlsx`
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
  [Parameter(ValueFromRemainingArguments = $true)]
  [object[]]$PassThruArgs = @()
)

#------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------

$SCRIPT_BIN_DIR = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$ROOT_DIR = Split-Path -Parent $SCRIPT_BIN_DIR
$CONFIG_DIR = Join-Path $ROOT_DIR 'config'
$TEMP_DIR = Join-Path $ROOT_DIR 'temp'
$LOG_DIR = Join-Path $ROOT_DIR 'log'
$UPDATE_SCRIPT_PATH = Join-Path $SCRIPT_BIN_DIR 'Update-GetHealthCode.ps1'
$GET_HEALTH_SCRIPT_PATH = Join-Path $SCRIPT_BIN_DIR 'Get-ComputerHealth.ps1'
$SEND_MESSAGE_SCRIPT_PATH = Join-Path $SCRIPT_BIN_DIR 'Send-Message.ps1'
$LIB_LOG_OBJECTS_PATH = Join-Path $SCRIPT_BIN_DIR 'lib-write-log-objects.ps1'
$VERSION_FILE_PATH = Join-Path $SCRIPT_BIN_DIR 'VERSION'
$IPS_OF_ALL_DCS_CACHE_PATH = Join-Path $TEMP_DIR 'cache.IpsOfAllDcs.clixml'
$LAST_REPORT_HTML_PATH = Join-Path $TEMP_DIR 'last-report.html'
$PROJECT_URL = 'https://github.com/ndemou/GetComputerHealth'

$SmtpSubject = 'Notable Messages from Get-ComputerHealth of LIST_OF_COMPUTERS'
$SmtpSubjectAllGood = 'RELAX. No notable Messages from Get-ComputerHealth of LIST_OF_COMPUTERS'
$SmtpConfig = Join-Path $CONFIG_DIR 'Send-Message.conf'
#------------------------------------------------------------------------
# Functions
#------------------------------------------------------------------------

function Invoke-HealthEmail {
  # Send the final report via email (except if -NoSendReport is passed)
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Subject,
    [Parameter(Mandatory)][string]$ConfigFile,
    [Parameter(Mandatory)][string]$Body,
    [switch]$BodyAsHtml,
    [string[]]$Attachments,
    [switch]$NoSendReport,
    [string]$SkipReason
  )

  if ($NoSendReport) {
    if ([string]::IsNullOrWhiteSpace($SkipReason)) {
      $SkipReason = 'Email sending disabled.'
    }
    Write-Host -for Yellow ("Will not send email report. Reason: {0}" -f $SkipReason)
    return
  }

  if (-not (Test-Path $ConfigFile)) {
    Write-Host -for Yellow ("Will not send email report. Reason: send-message.ps1 is not configured. If you want to configure it run ``Send-Message.ps1 -GenerateConfig '{0}'``." -f $ConfigFile)
    return
  }
  $mailParams = @{
    Subject    = $Subject
    Body       = $Body
    ConfigFile = $ConfigFile
  }
  if ($BodyAsHtml) { $mailParams['BodyAsHtml'] = $true }
  if ($Attachments -and $Attachments.Count) { $mailParams['Attachments'] = $Attachments }
  Write-host -for gray   ("Attempting to send email report. Subject: {0}" -f $Subject)
  Write-host -for gray   "Sending email... " -NoNewLine
  try {
    & $SEND_MESSAGE_SCRIPT_PATH @mailParams
    Write-host -for gray   "email sent."
  }
  catch {
    Write-host -for yellow "email failed."
    throw
  }
}

function Test-IsNonInteractiveContext {
  [CmdletBinding()]
  param(
    [int]$SessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId,
    [bool]$UserInteractive = [Environment]::UserInteractive
  )

  return ($SessionId -eq 0 -or (-not $UserInteractive))
}

function Resolve-HealthEmailPreference {
  [CmdletBinding()]
  param(
    [switch]$NoSendReport,
    [switch]$SendReport,
    [switch]$NonInteractiveContext
  )

  if ($NoSendReport) { return $false }
  if ($SendReport) { return $true }
  return [bool]$NonInteractiveContext
}

function Get-HealthEmailDecision {
  [CmdletBinding()]
  param(
    [switch]$NoSendReport,
    [switch]$SendReport,
    [switch]$NonInteractiveContext
  )

  if ($NoSendReport) {
    return [pscustomobject]@{
      ShouldSend = $false
      Reason = 'Email sending disabled by -NoSendReport.'
    }
  }

  if ($SendReport) {
    return [pscustomobject]@{
      ShouldSend = $true
      Reason = 'Email sending forced by -SendReport.'
    }
  }

  if ($NonInteractiveContext) {
    return [pscustomobject]@{
      ShouldSend = $true
      Reason = 'Email sending enabled by default because the script is running in a non-interactive context.'
    }
  }

  return [pscustomobject]@{
    ShouldSend = $false
    Reason = 'Email sending disabled by default because the script is running in an interactive context.'
  }
}

function Get-HealthEmailSignature {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$VersionFilePath,
    [Parameter(Mandatory)][string]$FallbackVersion,
    [Parameter(Mandatory)][string]$FallbackTimestampPath,
    [string]$ProjectUrl = 'https://github.com/ndemou/GetComputerHealth',
    [ValidateSet('Domain', 'Workgroup')]
    [string]$DomainRole = $(if ($env:USERDNSDOMAIN) { 'Domain' } else { 'Workgroup' }),
    [string]$DomainName = $(if ($env:USERDNSDOMAIN) { $env:USERDNSDOMAIN } elseif ($env:USERDOMAIN) { $env:USERDOMAIN } else { $env:COMPUTERNAME })
  )

  $version = $FallbackVersion
  $timestampPath = $FallbackTimestampPath

  if (Test-Path -LiteralPath $VersionFilePath -PathType Leaf) {
    try {
      $rawVersion = Get-Content -LiteralPath $VersionFilePath -Raw -ErrorAction Stop
      $trimmedVersion = [string]$rawVersion
      if ($trimmedVersion) {
        $trimmedVersion = $trimmedVersion.Trim()
      }
      if (-not [string]::IsNullOrWhiteSpace($trimmedVersion)) {
        $version = $trimmedVersion
      }
      $timestampPath = $VersionFilePath
    }
    catch {
      # Fall back to the embedded version and script timestamp.
    }
  }

  $lastUpdate = 'unknown'
  try {
    $item = Get-Item -LiteralPath $timestampPath -ErrorAction Stop
    $lastUpdate = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
  }
  catch {
    # Keep "unknown" if file metadata is unavailable.
  }

  $domainText = if ([string]::IsNullOrWhiteSpace($DomainName)) { 'unknown' } else { $DomainName.Trim() }
  $locationText = "$DomainRole $domainText"
  $signatureText = "Get-ComputerHealth version $version, last update $lastUpdate, domain $domainText"
  $encodedProjectUrl = [System.Net.WebUtility]::HtmlEncode($ProjectUrl)
  $encodedVersion = [System.Net.WebUtility]::HtmlEncode([string]$version)
  $encodedLastUpdate = [System.Net.WebUtility]::HtmlEncode([string]$lastUpdate)
  $encodedLocation = [System.Net.WebUtility]::HtmlEncode([string]$locationText)

  return [pscustomobject]@{
    Text = ($locationText + "`r`n" + $signatureText)
    Html = "<div>$encodedLocation</div><div><a href='$encodedProjectUrl'>Get-ComputerHealth</a> version $encodedVersion, last update $encodedLastUpdate</div>"
    HtmlTop = $encodedLocation
    HtmlBottom = "<a href='$encodedProjectUrl'>Get-ComputerHealth</a> version $encodedVersion, last update $encodedLastUpdate"
  }
}

function Add-HealthEmailSignature {
  [CmdletBinding()]
  param(
    [string]$Body,
    [switch]$BodyAsHtml,
    [Parameter(Mandatory)]$Signature
  )

  if ($BodyAsHtml) {
    $baseBody = if ([string]::IsNullOrEmpty($Body)) { '' } else { $Body }
    return ($baseBody + "<div style='margin-top:12px; font-family:Segoe UI, Arial, sans-serif'><div style='color:#000; font-size:12px'>$($Signature.HtmlTop)</div><div style='color:#666; font-size:10px'>$($Signature.HtmlBottom)</div></div>")
  }

  if ([string]::IsNullOrEmpty($Body)) {
    return $Signature.Text
  }

  return ($Body.TrimEnd() + "`r`n`r`n" + $Signature.Text)
}

function Get-HealthSuppressionCommand {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$MessageRecord
  )

  $hash = if ($MessageRecord.PSObject.Properties['Hash']) { [string]$MessageRecord.Hash } else { '' }
  $computer = if ($MessageRecord.PSObject.Properties['Computer']) { [string]$MessageRecord.Computer } else { '' }

  if (($hash -match '^[0-9a-fA-F]{8}$') -and (-not [string]::IsNullOrWhiteSpace($computer))) {
    $messageText = if ($MessageRecord.PSObject.Properties['Message']) { [string]$MessageRecord.Message } else { '' }
    $levelText = if ($MessageRecord.PSObject.Properties['Level']) { [string]$MessageRecord.Level } else { '' }
    $safeMessageText = $messageText -replace '"', "''"
    $commentText = "$levelText - $safeMessageText"
    if ($commentText.Length -gt 400) {
      $commentText = $commentText.Substring(0, 400)
    }
    return ("Invoke-Command {0} {{c:\it\Get-ComputerHealth\bin\Get-ComputerHealth.ps1 -AddWhitelisting -until 2999-12-31 -sig '{1}' -ComputerName {0} -comment ""{2}""}}" -f $computer.Trim(), $hash.ToLowerInvariant(), $commentText)
  }

  return ''
}

function Convert-HealthMessagesToHtmlTable {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object[]]$Messages
  )

  $rows = foreach ($message in $Messages) {
    $level = if ($message.PSObject.Properties['Level']) { [string]$message.Level } else { '' }
    $computer = if ($message.PSObject.Properties['Computer']) { [string]$message.Computer } else { '' }
    $text = if ($message.PSObject.Properties['Message']) { [string]$message.Message } else { '' }
    $comment = if ($message.PSObject.Properties['Comment']) { [string]$message.Comment } else { '' }
    $suppressionCommand = Get-HealthSuppressionCommand -MessageRecord $message
    $displayLevel = if ([string]::IsNullOrWhiteSpace($level)) { '' } else { $level.Substring(0, 1).ToUpperInvariant() + $level.Substring(1).ToLowerInvariant() }
    $levelBackground = switch ($level.ToLowerInvariant()) {
      'failure' { '#f3caca' }
      'warning' { '#f4ddbf' }
      'notice' { '#cfe0f5' }
      default { '#eef1f4' }
    }

    $messageHtml = [System.Net.WebUtility]::HtmlEncode($text)
    $detailsHtml = "<div>$messageHtml</div>"

    if (-not [string]::IsNullOrWhiteSpace($comment)) {
      $commentHtml = [System.Net.WebUtility]::HtmlEncode($comment) -replace '(\r\n|\n|\r)', '<br>'
      $detailsHtml += "<div style='margin-top:4px; color:#1f5fa8; font-size:10px; font-family:Consolas, ""Courier New"", monospace'>$commentHtml</div>"
    }

    if (-not [string]::IsNullOrWhiteSpace($suppressionCommand)) {
      $detailsHtml += "<div style='margin-top:4px; color:#666; font-size:6pt; font-family:""Arial Narrow"", Arial, sans-serif'>" + ([System.Net.WebUtility]::HtmlEncode($suppressionCommand)) + "</div>"
    }

    $computerLevelHtml = "<div style='font-weight:700; color:rgba(0,0,0,0.8)'>" + ([System.Net.WebUtility]::HtmlEncode($computer)) + "</div><div style='margin-top:2px'>" + ([System.Net.WebUtility]::HtmlEncode($displayLevel)) + "</div>"
    "<tr><td style='padding:6px 8px; border:1px solid rgba(0,0,0,0.5); vertical-align:top; white-space:nowrap; background-color:$levelBackground; color:#000'>$computerLevelHtml</td><td style='padding:6px 8px; border:1px solid rgba(0,0,0,0.5); vertical-align:top; color:#000'>$detailsHtml</td></tr>"
  }

  return @(
    "<table style='border-collapse:collapse; width:100%; font-family:Segoe UI, Arial, sans-serif; font-size:12px'>"
    "<tbody>"
    ($rows -join '')
    "</tbody></table>"
  ) -join ''
}

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

  $cachedIps = Get-CachedIpsOfAllDcs -CachePath $CachePath
  if ($cachedIps.Count -gt 0) {
    Write-Verbose "Using cached IpsOfAllDcs from '$CachePath'"
  }
  return $cachedIps
}

function Save-HealthHtmlReport {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Html
  )

  $parentDir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($parentDir) -and (-not (Test-Path -LiteralPath $parentDir -PathType Container))) {
    New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
  }

  Set-Content -LiteralPath $Path -Value $Html -Encoding UTF8
}

function Convert-HealthMessagesToExcelRows {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object[]]$Messages
  )

  foreach ($message in $Messages) {
    $level = if ($message.PSObject.Properties['Level']) { [string]$message.Level } else { '' }
    $suppressed = if ($message.PSObject.Properties['Suppressed']) { [bool]$message.Suppressed } else { $false }

    $commandToSuppressMsg = ''
    if ((-not $suppressed) -and ($level -notin @('info', 'debug'))) {
      $commandToSuppressMsg = Get-HealthSuppressionCommand -MessageRecord $message
    }

    [pscustomobject]@{
      Computer             = if ($message.PSObject.Properties['Computer']) { [string]$message.Computer } else { '' }
      Suppressed           = $suppressed
      Level                = $level
      Message              = if ($message.PSObject.Properties['Message']) { [string]$message.Message } else { '' }
      Comment              = if ($message.PSObject.Properties['Comment']) { [string]$message.Comment } else { '' }
      Hash                 = if ($message.PSObject.Properties['Hash']) { [string]$message.Hash } else { '' }
      Emitter              = if ($message.PSObject.Properties['Emitter']) { [string]$message.Emitter } else { '' }
      CommandToSuppressMsg = $commandToSuppressMsg
    }
  }
}

function Export-HealthMessagesReportToExcel {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object[]]$Messages,
    [Parameter(Mandatory)][string]$FileName
  )

  $rows = @(Convert-HealthMessagesToExcelRows -Messages $Messages)
  Export-ObjectsToExcel -Data $rows -FileName $FileName -WorksheetName 'Messages'
}

function Get-HealthNotableSubject {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$FallbackSubject,
    [Parameter(Mandatory)][object[]]$NotableMessages
  )

  $levelToSubjectPrefix = @{
    'failure' = 'Failure(s)'
    'warning' = 'Warning(s)'
    'notice'  = 'Notice(s)'
  }
  $priority = @('failure', 'warning', 'notice')

  $levelsInRun = @(
    $NotableMessages |
      Where-Object { $_ -and $_.PSObject.Properties['Level'] } |
      ForEach-Object { ([string]$_.Level).Trim().ToLowerInvariant() } |
      Where-Object { $levelToSubjectPrefix.ContainsKey($_) } |
      Select-Object -Unique
  )

  $highestLevel = $priority | Where-Object { $_ -in $levelsInRun } | Select-Object -First 1
  if ($highestLevel) {
    return $FallbackSubject -replace 'Notable Messages', $levelToSubjectPrefix[$highestLevel]
  }

  return $FallbackSubject
}

function Get-EmbeddedGetComputerHealthVersion {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$ScriptPath)

  try {
    $content = Get-Content -LiteralPath $ScriptPath -Raw -ErrorAction Stop
    $match = [regex]::Match($content, '(?m)^\$VERSION\s*=\s*"(?<Version>[^"]+)"')
    if ($match.Success) {
      return $match.Groups['Version'].Value
    }
  }
  catch {
    # Fall back to unknown if the file cannot be read.
  }

  return 'unknown'
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

#------------------------------------------------------------------------
# MAIN CODE
#------------------------------------------------------------------------

$timestamp = $(get-date -Format 'yyyy-MM-dd_HH.mm')
if (-not (Test-Path -LiteralPath $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null }
if (-not (Test-Path -LiteralPath $TEMP_DIR)) { New-Item -ItemType Directory -Path $TEMP_DIR -Force | Out-Null }
Start-Transcript (Join-Path $LOG_DIR "Invoke-GetHealthDomainComputers-$timestamp.log")
. $LIB_LOG_OBJECTS_PATH
$embeddedVersion = Get-EmbeddedGetComputerHealthVersion -ScriptPath $GET_HEALTH_SCRIPT_PATH
$emailSignature = Get-HealthEmailSignature -VersionFilePath $VERSION_FILE_PATH -FallbackVersion $embeddedVersion -FallbackTimestampPath $GET_HEALTH_SCRIPT_PATH
$emailDecision = Get-HealthEmailDecision -NoSendReport:$NoSendReport -SendReport:$SendReport -NonInteractiveContext:(Test-IsNonInteractiveContext)
$sendMailByDefault = [bool]$emailDecision.ShouldSend
$IpsOfAllDcs = Resolve-IpsOfAllDcs -IpsOfAllDcs $IpsOfAllDcs -WasProvided:$PSBoundParameters.ContainsKey('IpsOfAllDcs') -CachePath $IPS_OF_ALL_DCS_CACHE_PATH
Write-Host -for Gray ("Email report decision: {0}" -f $emailDecision.Reason)

if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
  throw "Required module 'ImportExcel' is missing. Run Update-GetHealthCode.ps1 to install prerequisites."
}

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
$SmtpSubject = $SmtpSubject -replace 'LIST_OF_COMPUTERS', ($targets -join ',')
$SmtpSubjectAllGood = $SmtpSubjectAllGood -replace 'LIST_OF_COMPUTERS', ($targets -join ',')

$localReleaseZip = $null
if ($PushUpdate) {
  $localReleaseZip = Get-LatestLocalReleaseZip
  if (-not $localReleaseZip) {
    Write-Warning "-PushUpdate was requested but no local update zip was found (metadata marker or cached zip in ${TEMP_DIR}). Falling back to normal update behavior."
  }
}

$all_messages = @()
Write-host "`n`n`n"
foreach ($target in $targets) {
  Write-Progress -Activity "Checking $target" -Status "Phase #1 (copy Get-ComputerHealth.ps1)"
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
    $records = New-Object System.Collections.Generic.List[object]

    if (-not (Test-Path -LiteralPath $logLibPath)) {
      throw "Logging helper file not found: $logLibPath"
    }
    . $logLibPath

    if (-not $NoUpdate) {
      try {
        $updateOutput = if ($PushUpdate -and $UpdateZipPath) {
          & $updateScriptPath -UpdateFromZip $UpdateZipPath 2>&1
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
      $healthOutput = & $getHealthScriptPath @getHealthParams @PassThruArgs 2>&1

      foreach ($item in @($healthOutput)) {
        if ($item -is [System.Management.Automation.ErrorRecord]) {
          $records.Add((Log-Failure "PowerShell error while running Get-ComputerHealth.ps1" -Comment (($item | Out-String).Trim()))) | Out-Null
          continue
        }

        if ($item -and $item.PSObject.Properties['Level'] -and $item.PSObject.Properties['Message']) {
          $records.Add([pscustomobject]@{
              Computer   = if ($item.PSObject.Properties['Computer']) { [string]$item.Computer } else { $env:COMPUTERNAME }
              Level      = [string]$item.Level
              Hash       = if ($item.PSObject.Properties['Hash']) { [string]$item.Hash } else { '00000000' }
              Suppressed = if ($item.PSObject.Properties['Suppressed']) { [bool]$item.Suppressed } else { $false }
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
    $output = & $healthCheckBlock $ROOT_DIR $Hide $OnlyTheseTests $ExcludeTests $WhitelistSigs $SkipSlowTests $SkipPolicyTests $SkipNonEssentialTests $NoUpdate $RunWithoutElevation $IpsOfAllDcs $PushUpdate $localReleaseZip $PassThruArgs
  }
  else {
    if (Get-TcpPortStateFast $target @(5985, 5986, 80, 443, 88, 135, 389, 636, 445, 3268, 3269) | Where-Object { $_.Open }) {
      Write-Progress -Activity "Checking $target" -Status "Phase #2 (copying updater and running Get-ComputerHealth.ps1)"

      $session = $null
      try {
        $session = New-PSSession -ComputerName $target

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

        $localUpdaterPath = $UPDATE_SCRIPT_PATH
        $remoteUpdaterPath = Join-Path (Join-Path $remoteExecutionRoot 'bin') 'Update-GetHealthCode.ps1'

        if (-not (Test-Path -LiteralPath $localUpdaterPath)) {
          throw "Local updater file not found: $localUpdaterPath"
        }

        Copy-Item -Path $localUpdaterPath -Destination $remoteUpdaterPath -ToSession $session -Force

        $remoteZipPath = $null
        if ($PushUpdate -and $localReleaseZip) {
          $remoteZipPath = Join-Path (Join-Path $remoteExecutionRoot 'temp') (Split-Path -Path $localReleaseZip -Leaf)
          Copy-Item -Path $localReleaseZip -Destination $remoteZipPath -ToSession $session -Force
        }

        $output = Invoke-Command -Session $session -ScriptBlock $healthCheckBlock -ArgumentList $remoteExecutionRoot, $Hide, $OnlyTheseTests, $ExcludeTests, $WhitelistSigs, $SkipSlowTests, $SkipPolicyTests, $SkipNonEssentialTests, $NoUpdate, $RunWithoutElevation, $IpsOfAllDcs, $PushUpdate, $remoteZipPath, $PassThruArgs
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

$SortOrder = @{'failure' = 1; 'warning' = 2; 'notice' = 3; 'info' = 4; 'pass' = 5; 'debug' = 6 }
$notable_msgs = @()
if ($all_messages) {
  # save
  Export-HealthMessagesReportToExcel -Messages $all_messages -FileName "${TEMP_DIR}\all-messages-$($timestamp).xlsx"
  $notable_msgs = @(`
      $all_messages `
    | Where-Object { -not($_.Suppressed) -and $_.level -notin @('debug', 'help', 'pass', 'info') } `
    | Sort-Object -Property @{ Expression = { $SortOrder[$_.Level] } }, Computer `
  )
  if ($notable_msgs) {
    Export-HealthMessagesReportToExcel -Messages $notable_msgs -FileName "${TEMP_DIR}\notable-messages-$($timestamp).xlsx"
  }

  $synopsis = " " + ($notable_msgs | Where-Object { $_.Level } |
    Group-Object Level -NoElement |
    Sort-Object -Property @{ Expression = { $SortOrder[$_.Name] } } | ForEach-Object {
      if ($_.Count) {
        "    $($_.Count.ToString().PadRight(5)) $($_.Name)`r`n"
      }
    })

  write-host ""
  Write-host -for white    "Synopsis of notable messages per level"
  Write-host -for gray   $synopsis
  write-host ""
  if ($notable_msgs) {
    Write-host -for yellow "Found notable messages. I have saved them in these files:"
    Write-host -for yellow "    ${TEMP_DIR}\notable-messages-$($timestamp).xlsx"
    Write-host -for gray   "    ${TEMP_DIR}\all-messages-$($timestamp).xlsx"
    Write-host -for gray   "Open them on Excel or if you prefer PowerShell load them like this:"
    Write-host -for gray   "    `$data = Import-Excel ${TEMP_DIR}\notable-messages-$($timestamp).xlsx"
    Write-host -for gray   '    $data|ogv # GUI review'
    Write-host -for gray   '    $data|select -Property Computer,Level,Message # Console review'

    Write-host -for gray   ""
    Write-host -for gray   "Preparing notable report"

    $htmlParts = @()
    if ($notable_msgs.count -gt 10) {
      $encodedSynopsis = [System.Net.WebUtility]::HtmlEncode(("Synopsis of messages per level`r`n" + $synopsis).TrimEnd())
      $htmlParts += "<pre style='font-family:Consolas, ""Courier New"", monospace; white-space:pre-wrap; margin:0 0 12px 0; font-size:12px; line-height:1.35'>$encodedSynopsis</pre>"
    }
    $htmlParts += Convert-HealthMessagesToHtmlTable -Messages @(
      $notable_msgs | Sort-Object -Property @{ Expression = { $SortOrder[$_.Level] } }, Computer
    )
    $html = $htmlParts -join ''

    $signedHtml = Add-HealthEmailSignature -Body $html -BodyAsHtml -Signature $emailSignature
    Save-HealthHtmlReport -Path $LAST_REPORT_HTML_PATH -Html $signedHtml
    $smtpNotableSubject = Get-HealthNotableSubject -FallbackSubject $SmtpSubject -NotableMessages $notable_msgs
    Invoke-HealthEmail -Subject $smtpNotableSubject -Body $signedHtml -BodyAsHtml -Attachments "${TEMP_DIR}\notable-messages-$($timestamp).xlsx" -ConfigFile $SmtpConfig -NoSendReport:(-not $sendMailByDefault) -SkipReason $emailDecision.Reason
  }
  else {
    Write-host -for green    "GOOD, Nothing notable to record. I have saved less notable messages here:"
    Write-host -for gray     "    ${TEMP_DIR}\all-messages-$($timestamp).xlsx"
    $signedBody = Add-HealthEmailSignature -Body '<div>Relax :-)</div>' -BodyAsHtml -Signature $emailSignature
    Save-HealthHtmlReport -Path $LAST_REPORT_HTML_PATH -Html $signedBody
    Invoke-HealthEmail -Subject $SmtpSubjectAllGood -Body $signedBody -BodyAsHtml -ConfigFile $SmtpConfig -NoSendReport:(-not $sendMailByDefault) -SkipReason $emailDecision.Reason
  }
}
else {
}

Stop-Transcript
