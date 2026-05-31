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
.\Invoke-GetComputerHealth.ps1 -Computers ALL_DOMAIN_SERVERS,APP01,FS01 -OnlyTheseTests HealthTest-ShareReasonableness,HealthTest-NonDefaultShares

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
$LAST_INTERACTIVE_REPORT_HTML_PATH = Join-Path $TEMP_DIR 'last-interactive-report.html'
$LAST_REPORT_HTML_PATH = Join-Path $TEMP_DIR 'last-report.html'
$PROJECT_URL = 'https://github.com/ndemou/GetComputerHealth'
$GCH_CONFIG_PATH = Join-Path $CONFIG_DIR 'gch.psd1'
$SHOW_AS_POSTPONED_WINDOW_DAYS = 150

$SmtpSubject = 'Notable Messages from Get-ComputerHealth of LIST_OF_COMPUTERS'
$SmtpSubjectAllGood = 'RELAX. No notable Messages from Get-ComputerHealth of LIST_OF_COMPUTERS'
$SmtpConfig = Join-Path $CONFIG_DIR 'Send-Message.conf'
$SmtpConfigPsd1 = Join-Path $CONFIG_DIR 'Send-Message.psd1'
if ((-not (Test-Path -LiteralPath $SmtpConfig -PathType Leaf)) -and (Test-Path -LiteralPath $SmtpConfigPsd1 -PathType Leaf)) {
  $SmtpConfig = $SmtpConfigPsd1
}
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
    [string]$DomainName = $(if ($env:USERDNSDOMAIN) { $env:USERDNSDOMAIN } elseif ($env:USERDOMAIN) { $env:USERDOMAIN } else { $env:COMPUTERNAME }),
    [string]$SourceComputerName = $env:COMPUTERNAME,
    [string[]]$SourceIpv4Addresses = $(
      try {
        @(
          (Get-NetIPAddress | Where-Object { $_.AddressFamily -eq 'IPv4' -and $_.IPAddress -notmatch '^169\.254\.|^127\.' }).IPAddress |
            Sort-Object
        )
      }
      catch {
        @()
      }
    )
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
  $sourceComputerText = if ([string]::IsNullOrWhiteSpace($SourceComputerName)) { 'unknown' } else { $SourceComputerName.Trim() }
  $sourceIpText = @($SourceIpv4Addresses | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ', '
  $locationText = "Tests started from $sourceComputerText $DomainRole $domainText"
  if (-not [string]::IsNullOrWhiteSpace($sourceIpText)) {
    $locationText += " $sourceIpText"
  }
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
    [Parameter(Mandatory)]$MessageRecord,
    [switch]$WrapInInvokeCommand = $true
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
    $baseCommand = ("c:\it\Get-ComputerHealth\bin\Get-ComputerHealth.ps1 -AddWhitelisting -until 2999-12-31 -sig '{0}' -ComputerName {1} -comment ""{2}""" -f $hash.ToLowerInvariant(), $computer.Trim(), $commentText)
    if ($WrapInInvokeCommand) {
      return ("Invoke-Command {0} {{{1}}}" -f $computer.Trim(), $baseCommand)
    }
    return $baseCommand
  }

  return ''
}

function Convert-HealthSynopsisToHtml {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object[]]$Messages,
    [hashtable]$SortOrder = @{'failure' = 1; 'warning' = 2; 'notice' = 3; 'postponed' = 4; 'info' = 5; 'pass' = 6; 'debug' = 7 }
  )

  $levelMeta = @{
    'failure' = @{ Label = 'failure'; Background = '#ff4d4f'; Foreground = '#fff' }
    'warning' = @{ Label = 'warning'; Background = '#ffb300'; Foreground = '#111' }
    'notice'  = @{ Label = 'notice'; Background = '#1e88e5'; Foreground = '#fff' }
    'postponed' = @{ Label = 'postponed'; Background = '#2e7d32'; Foreground = '#fff' }
    'info'    = @{ Label = 'info'; Background = '#c7d0d9'; Foreground = '#111' }
    'pass'    = @{ Label = 'passes'; Background = '#3cb371'; Foreground = '#fff' }
    'debug'   = @{ Label = 'debug'; Background = '#c7d0d9'; Foreground = '#111' }
  }

  $parts = @(
    $Messages |
      Where-Object { if ($_.PSObject.Properties['EffectiveLevel']) { $_.EffectiveLevel } else { $_.Level } } |
      Group-Object -Property @{ Expression = { if ($_.PSObject.Properties['EffectiveLevel']) { $_.EffectiveLevel } else { $_.Level } } } -NoElement |
      Sort-Object -Property @{ Expression = { $SortOrder[$_.Name] } } |
      ForEach-Object {
        $levelKey = ([string]$_.Name).ToLowerInvariant()
        if (-not $levelMeta.ContainsKey($levelKey)) { return }
        $meta = $levelMeta[$levelKey]
        $countHtml = "<span style='font-weight:700; font-size:120%'>" + ([System.Net.WebUtility]::HtmlEncode([string]$_.Count)) + "</span>"
        $labelHtml = "<span style='display:inline-block; margin:0 12px 0 4px; padding:1px 6px; border-radius:999px; background-color:$($meta.Background); color:$($meta.Foreground)'>$([System.Net.WebUtility]::HtmlEncode($meta.Label))</span>"
        $countHtml + ' ' + $labelHtml
      }
  )

  if ($parts.Count -eq 0) {
    return ''
  }

    return "<div style='margin:0 0 8px 0; font-family:Segoe UI, Arial, sans-serif; font-size:12px; color:#000'>" + ($parts -join '   ') + "</div><div style='border-top:1px solid #cfcfcf; margin:0 0 12px 0'></div>"
}

function Convert-HealthMessagesToHtmlTable {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object[]]$Messages
  )

  $wrapSuppressionInInvokeCommand = (@($Messages | Where-Object { $_.Computer } | Select-Object -ExpandProperty Computer -Unique).Count -gt 1)

  $rows = foreach ($message in $Messages) {
    $realLevel = if ($message.PSObject.Properties['Level']) { [string]$message.Level } else { '' }
    $level = if ($message.PSObject.Properties['EffectiveLevel']) { [string]$message.EffectiveLevel } else { $realLevel }
    $computer = if ($message.PSObject.Properties['Computer']) { [string]$message.Computer } else { '' }
    $text = if ($message.PSObject.Properties['Message']) { [string]$message.Message } else { '' }
    $comment = if ($message.PSObject.Properties['Comment']) { [string]$message.Comment } else { '' }
    $suppressionCommand = Get-HealthSuppressionCommand -MessageRecord $message -WrapInInvokeCommand:$wrapSuppressionInInvokeCommand
    $displayLevel = if ([string]::IsNullOrWhiteSpace($level)) { '' } else { $level.Substring(0, 1).ToUpperInvariant() + $level.Substring(1).ToLowerInvariant() }
    $levelBackground = switch ($level.ToLowerInvariant()) {
      'failure' { '#ff4d4f' }
      'warning' { '#ffb300' }
      'notice'  { '#1e88e5' }
      'postponed' { '#2e7d32' }
      default   { '#c7d0d9' }
    }
    $levelForeground = switch ($level.ToLowerInvariant()) {
      'warning' { '#111' }
      default   { '#fff' }
    }

    $messageHtml = [System.Net.WebUtility]::HtmlEncode($text)
    $headerHtml = "<div><span style='font-weight:700; color:rgba(0,0,0,0.8)'>" + ([System.Net.WebUtility]::HtmlEncode($computer)) + "</span><span style='display:inline-block; margin-left:8px; padding:1px 6px; border-radius:999px; background-color:$levelBackground; color:$levelForeground'>" + ([System.Net.WebUtility]::HtmlEncode($displayLevel)) + "</span><span style='margin-left:8px'>$messageHtml</span></div>"
    $detailsHtml = $headerHtml

    if (-not [string]::IsNullOrWhiteSpace($comment)) {
      $commentHtml = [System.Net.WebUtility]::HtmlEncode($comment) -replace '(\r\n|\n|\r)', '<br>'
      $detailsHtml += "<div style='margin-top:4px; color:#1f5fa8; font-size:10px; font-family:Consolas, ""Courier New"", monospace'>$commentHtml</div>"
    }

    if (($level -ieq 'postponed') -and (-not [string]::IsNullOrWhiteSpace($realLevel))) {
      $postponedUntilText = 'unknown date'
      if ($message.PSObject.Properties['SuppressedUntil']) {
        $suppressedUntilValue = $message.SuppressedUntil
        if ($suppressedUntilValue -is [datetime]) {
          $postponedUntilText = $suppressedUntilValue.ToString('yyyy-MM-dd')
        }
      }

      $detailsHtml += "<div style='margin-top:4px; color:#2e7d32; font-size:10px; font-family:Segoe UI, Arial, sans-serif'>Postponed until " + ([System.Net.WebUtility]::HtmlEncode($postponedUntilText)) + ", real level " + ([System.Net.WebUtility]::HtmlEncode($realLevel.ToLowerInvariant())) + "</div>"
    }

    if (($level -ine 'postponed') -and (-not [string]::IsNullOrWhiteSpace($suppressionCommand))) {
      $detailsHtml += "<div style='margin-top:4px; color:#666; font-size:6pt; font-family:""Arial Narrow"", Arial, sans-serif'>" + ([System.Net.WebUtility]::HtmlEncode($suppressionCommand)) + "</div>"
    }

    "<div style='margin-bottom:10px; font-family:Segoe UI, Arial, sans-serif; font-size:12px; color:#000'>$detailsHtml</div>"
  }

  return @(
    "<div style='width:100%; font-family:Segoe UI, Arial, sans-serif; font-size:12px'>"
    ($rows -join '')
    "</div>"
  ) -join ''
}

function Get-RelaxHtmlBody {
  [CmdletBinding()]
  param()

  return @'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Relax - Email Safe Version</title>
    <style>
        .swing-effect {
            display: inline-block;
            transform-origin: top center;
            animation: pendulum 4s infinite ease-in-out;
        }

        @keyframes pendulum {
            0%, 100% { transform: rotate(-8deg); }
            50% { transform: rotate(8deg); }
        }
    </style>
</head>
<body style="background-color: #eef2f5; margin: 0; padding: 50px 20px; text-align: center; font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;">
    <table align="center" border="0" cellpadding="0" cellspacing="0" width="220" style="background-color: #ffffff; border-radius: 20px; box-shadow: 0 10px 25px rgba(0,0,0,0.05); border: 1px solid #e2e8f0; margin: 0 auto;">
        <tr>
            <td align="center" valign="middle" height="150" style="padding: 20px;">
                <div class="swing-effect" style="text-align: center;">
                    <div style="font-size: 24px; margin-bottom: 10px; font-family: 'Segoe UI Emoji', 'Apple Color Emoji', 'Noto Color Emoji', sans-serif;">🍃</div>
                    <div style="font-weight: 300; letter-spacing: 10px; color: #718096; font-size: 28px; margin-left: 10px;">
                        Relax
                    </div>
                </div>
            </td>
        </tr>
    </table>
</body>
</html>
'@
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

  $cachedIps = @(Get-CachedIpsOfAllDcs -CachePath $CachePath)
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

function Move-HealthReportFile {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$DestinationPath
  )

  $destinationDir = Split-Path -Parent $DestinationPath
  if (-not [string]::IsNullOrWhiteSpace($destinationDir)) {
    New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
  }

  if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
    Remove-Item -LiteralPath $DestinationPath -Force
  }

  Move-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
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

function Get-HealthSuppressionExpiryMap {
  [CmdletBinding()]
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

function Get-HealthEffectiveLevel {
  [CmdletBinding()]
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

function Convert-HealthTimeValueToUtcIsoString {
  [CmdletBinding()]
  param(
    $Value
  )

  if ($null -eq $Value) {
    return ''
  }

  if ($Value -is [datetimeoffset]) {
    return ([datetimeoffset]$Value).ToUniversalTime().ToString('o')
  }

  if ($Value -is [datetime]) {
    return ([datetime]$Value).ToUniversalTime().ToString('o')
  }

  if ($Value.PSObject -and $Value.PSObject.Properties['UtcDateTime'] -and $Value.UtcDateTime) {
    return ([datetime]$Value.UtcDateTime).ToUniversalTime().ToString('o')
  }

  if ($Value.PSObject -and $Value.PSObject.Properties['DateTime'] -and $Value.DateTime) {
    return ([datetime]$Value.DateTime).ToUniversalTime().ToString('o')
  }

  $text = [string]$Value
  if ([string]::IsNullOrWhiteSpace($text)) {
    return ''
  }

  return ([datetime]$text).ToUniversalTime().ToString('o')
}

function Convert-HealthMessagesToReportRows {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object[]]$Messages
  )

  foreach ($message in $Messages) {
    $level = if ($message.PSObject.Properties['Level']) { [string]$message.Level } else { '' }
    $suppressed = if ($message.PSObject.Properties['Suppressed']) { [bool]$message.Suppressed } else { $false }
    $timeUtc = ''
    if ($message.PSObject.Properties['TimeUtc'] -and $message.TimeUtc) {
      $timeUtc = Convert-HealthTimeValueToUtcIsoString -Value $message.TimeUtc
    }

    [pscustomobject]@{
      TimeUtc              = $timeUtc
      Computer             = if ($message.PSObject.Properties['Computer']) { [string]$message.Computer } else { '' }
      Suppressed           = $suppressed
      Level                = $level
      EffectiveLevel       = if ($message.PSObject.Properties['EffectiveLevel']) { [string]$message.EffectiveLevel } else { $level }
      WhatToDo             = 'not-sure'
      Message              = if ($message.PSObject.Properties['Message']) { [string]$message.Message } else { '' }
      Comment              = if ($message.PSObject.Properties['Comment']) { [string]$message.Comment } else { '' }
      Hash                 = if ($message.PSObject.Properties['Hash']) { [string]$message.Hash } else { '' }
      SuppressedUntil      = if ($message.PSObject.Properties['SuppressedUntil'] -and $message.SuppressedUntil) { ([datetime]$message.SuppressedUntil).ToString('yyyy-MM-dd') } else { '' }
      Emitter              = if ($message.PSObject.Properties['Emitter']) { [string]$message.Emitter } else { '' }
    }
  }
}

function Export-HealthMessagesReportData {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object[]]$Messages,
    [Parameter(Mandatory)][string]$FileName
  )

  $rows = @(Convert-HealthMessagesToReportRows -Messages $Messages)
  $rows | Export-Clixml -LiteralPath $FileName
}

function Compress-HealthReportDataFile {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$DestinationPath
  )

  Add-Type -AssemblyName 'System.IO.Compression'
  Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

  $destinationDir = Split-Path -Parent $DestinationPath
  if (-not [string]::IsNullOrWhiteSpace($destinationDir)) {
    New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
  }

  if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
    Remove-Item -LiteralPath $DestinationPath -Force
  }

  $sourceItem = Get-Item -LiteralPath $SourcePath -ErrorAction Stop
  $archive = [System.IO.Compression.ZipFile]::Open($DestinationPath, [System.IO.Compression.ZipArchiveMode]::Create)
  try {
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
      $archive,
      $sourceItem.FullName,
      $sourceItem.Name,
      [System.IO.Compression.CompressionLevel]::Optimal
    ) | Out-Null
  }
  finally {
    $archive.Dispose()
  }

  Remove-Item -LiteralPath $SourcePath -Force
}

function Convert-HealthReportRowsToInteractiveRows {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object[]]$Rows
  )

  foreach ($row in $Rows) {
    if (-not $row) {
      continue
    }

    [pscustomobject]@{
      Computer       = if ($row.PSObject.Properties['Computer']) { [string]$row.Computer } else { '' }
      Suppressed     = if ($row.PSObject.Properties['Suppressed']) { [bool]$row.Suppressed } else { $false }
      Level          = if ($row.PSObject.Properties['Level']) { [string]$row.Level } else { '' }
      EffectiveLevel = if ($row.PSObject.Properties['EffectiveLevel']) { [string]$row.EffectiveLevel } else { '' }
      Message        = if ($row.PSObject.Properties['Message']) { [string]$row.Message } else { '' }
      Comment        = if ($row.PSObject.Properties['Comment']) { [string]$row.Comment } else { '' }
      Hash           = if ($row.PSObject.Properties['Hash']) { [string]$row.Hash } else { '' }
    }
  }
}

function Get-HealthReportArtifactPaths {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$DataDir,
    [Parameter(Mandatory)][string]$TempDir,
    [Parameter(Mandatory)][string]$Timestamp
  )

  return [pscustomobject]@{
    AllMessagesClixmlTempPath      = Join-Path $TempDir "all-messages-$Timestamp.clixml"
    AllMessagesZipPath             = Join-Path $DataDir "all-messages-$Timestamp.clixml.zip"
    InteractiveReportTempPath      = Join-Path $TempDir "interactive-report-$Timestamp.html"
    LastInteractiveReportHtmlPath  = Join-Path $TempDir 'last-interactive-report.html'
    LastEmailBodyHtmlPath          = Join-Path $TempDir 'last-report.html'
  }
}

function Import-HealthMessagesReportData {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$DataDir,
    [datetime]$CutoffDate = (Get-Date).AddMonths(-3),
    [string]$Pattern = 'all-messages-*.clixml.zip'
  )

  if (-not (Test-Path -LiteralPath $DataDir -PathType Container)) {
    return @()
  }

  $items = @(Get-ChildItem -LiteralPath $DataDir -File -Filter $Pattern -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -ge $CutoffDate } |
      Sort-Object -Property LastWriteTime)

  $rows = New-Object System.Collections.ArrayList
  foreach ($item in $items) {
    try {
      if ($item.Extension -ieq '.zip') {
        Add-Type -AssemblyName 'System.IO.Compression'
        Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
        $extractDir = Join-Path ([System.IO.Path]::GetTempPath()) ('gch-report-import-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
        try {
          $archive = [System.IO.Compression.ZipFile]::OpenRead($item.FullName)
          try {
            $entry = $archive.Entries | Where-Object { $_.Name -like '*.clixml' } | Select-Object -First 1
            if ($null -eq $entry) {
              throw "Archive does not contain a .clixml entry."
            }

            $extractedPath = Join-Path $extractDir $entry.Name
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $extractedPath, $true)
          }
          finally {
            $archive.Dispose()
          }

          $imported = Import-Clixml -LiteralPath $extractedPath -ErrorAction Stop
        }
        finally {
          Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        }
      }
      else {
        $imported = Import-Clixml -LiteralPath $item.FullName -ErrorAction Stop
      }

      foreach ($row in @($imported)) {
        if ($row) {
          [void]$rows.Add($row)
        }
      }
    }
    catch {
      Write-Warning ("Failed loading report data from '{0}': {1}" -f $item.FullName, $_.Exception.Message)
    }
  }

  return @($rows)
}

function Get-HealthInteractiveHtmlReport {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object[]]$Rows,
    [string]$Title = 'Get-ComputerHealth Findings Report',
    [string]$FooterHtml = ''
  )

  $safeTitle = [System.Net.WebUtility]::HtmlEncode($Title)
  $safeFooterHtml = [string]$FooterHtml
  $jsonRows = @($Rows) | ConvertTo-Json -Depth 6 -Compress
  $jsonRows = $jsonRows -replace '</script>', '<\/script>'

  return @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$safeTitle</title>
  <style>
    :root {
      --bg: #eef3ee;
      --bg-accent: #dce8df;
      --panel: rgba(255,255,255,0.92);
      --panel-strong: #ffffff;
      --ink: #172126;
      --muted: #607179;
      --line: #d4ddd8;
      --accent: #0f766e;
      --accent-strong: #0b5c56;
      --accent-soft: #d7f0ea;
      --failure: #ff4d4f;
      --warning: #ffb300;
      --notice: #1e88e5;
      --postponed: #2e7d32;
      --pass: #3cb371;
      --debug: #9aa7ad;
      --mustfix: #b42318;
      --suppress: #475467;
      --postpone: #2e7d32;
      --notsure: #8a6f00;
      --shadow: 0 18px 48px rgba(23,33,38,0.10);
    }
    body {
      margin: 0;
      font-family: Segoe UI, Arial, sans-serif;
      background:
        radial-gradient(circle at top left, rgba(15,118,110,0.12), transparent 28%),
        radial-gradient(circle at top right, rgba(30,136,229,0.10), transparent 22%),
        linear-gradient(180deg, var(--bg) 0%, var(--bg-accent) 100%);
      color: var(--ink);
    }
    .shell {
      max-width: 1500px;
      margin: 0 auto;
      padding: 30px 24px 40px 24px;
    }
    .hero {
      background: linear-gradient(180deg, rgba(255,255,255,0.96) 0%, rgba(248,251,249,0.92) 100%);
      border: 1px solid var(--line);
      border-radius: 24px;
      padding: 24px 24px 20px 24px;
      box-shadow: var(--shadow);
      margin-bottom: 18px;
      backdrop-filter: blur(10px);
    }
    h1 {
      margin: 0 0 8px 0;
      font-size: 16px;
      letter-spacing: -0.03em;
    }
    .controls, .column-controls, .summary {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      align-items: center;
      margin-top: 14px;
    }
    .controls input[type=text], .controls select {
      border: 1px solid var(--line);
      border-radius: 14px;
      padding: 10px 14px;
      font-size: 14px;
      background: rgba(255,255,255,0.92);
      color: var(--ink);
      box-shadow: inset 0 1px 0 rgba(255,255,255,0.7);
    }
    .controls input[type=text] {
      min-width: 190px;
      flex: 0 1 210px;
    }
    button, .pill {
      border: 1px solid var(--line);
      border-radius: 999px;
      padding: 9px 14px;
      background: rgba(255,255,255,0.94);
      color: var(--ink);
      cursor: pointer;
      font-size: 13px;
      transition: transform 0.12s ease, box-shadow 0.12s ease, border-color 0.12s ease, background-color 0.12s ease;
      box-shadow: 0 4px 14px rgba(23,33,38,0.06);
    }
    button:hover, .pill:hover {
      transform: translateY(-1px);
      box-shadow: 0 8px 18px rgba(23,33,38,0.10);
    }
    button.active-filter {
      background: var(--accent);
      color: #fff;
      border-color: var(--accent);
    }
    .summary {
      gap: 18px;
      color: var(--muted);
      font-size: 13px;
    }
    .footer {
      margin-top: 10px;
      color: var(--muted);
      font-size: 10px;
      font-family: Segoe UI, Arial, sans-serif;
    }
    .summary .status-item {
      white-space: nowrap;
    }
    .utility-button {
      background: linear-gradient(180deg, #ffffff 0%, #f0f8f5 100%);
    }
    .utility-button strong {
      font-weight: 700;
    }
    .toggle-track {
      position: relative;
      width: 42px;
      height: 24px;
      border-radius: 999px;
      background: #c7d4cf;
      transition: background-color 0.15s ease;
      flex: 0 0 auto;
      display: inline-block;
    }
    .toggle-track::after {
      content: '';
      position: absolute;
      top: 3px;
      left: 3px;
      width: 18px;
      height: 18px;
      border-radius: 50%;
      background: #fff;
      box-shadow: 0 2px 6px rgba(23,33,38,0.18);
      transition: transform 0.15s ease;
    }
    .plain-toggle {
      display: inline-flex;
      align-items: center;
      gap: 10px;
      color: var(--ink);
      user-select: none;
    }
    .plain-toggle input {
      position: absolute;
      opacity: 0;
      width: 1px;
      height: 1px;
      pointer-events: none;
    }
    .plain-toggle input:checked + .toggle-track {
      background: var(--accent);
    }
    .plain-toggle input:checked + .toggle-track::after {
      transform: translateX(18px);
    }
    .plain-toggle .toggle-text {
      font-size: 13px;
      font-weight: 600;
    }
    .controls-label {
      font-size: 13px;
      color: var(--muted);
      font-weight: 600;
    }
    .column-controls label {
      font-size: 13px;
      color: var(--ink);
    }
    .table-wrap {
      background: var(--panel-strong);
      border: 1px solid var(--line);
      border-radius: 24px;
      box-shadow: var(--shadow);
      overflow: auto;
      backdrop-filter: blur(10px);
    }
    table {
      width: 100%;
      border-collapse: collapse;
      table-layout: auto;
    }
    col.col-width-computer { width: 1%; }
    col.col-width-level { width: 1%; }
    col.col-width-action { width: 1%; }
    col.col-width-message { width: 28%; }
    col.col-width-comment { width: 18%; }
    col.col-width-command { width: 24%; }
    thead {
      position: sticky;
      top: 0;
      z-index: 2;
    }
    thead th {
      background: linear-gradient(180deg, #eef6f3 0%, #e7f0ec 100%);
      text-align: left;
      font-size: 12px;
      letter-spacing: 0.04em;
      text-transform: uppercase;
      color: var(--muted);
      border-bottom: 1px solid var(--line);
      padding: 14px 12px;
      white-space: nowrap;
    }
    tbody td {
      padding: 12px;
      border-bottom: 1px solid #edf1ef;
      vertical-align: top;
      font-size: 13px;
      overflow-wrap: anywhere;
    }
    tbody tr:hover {
      background: #f7fbf9;
    }
    .col-computer, .col-level, .col-action {
      white-space: nowrap;
      width: 1%;
    }
    .col-message {
      font-size: 13px;
    }
    tbody td.col-comment {
      color: #41515a;
      font-family: Consolas, "Courier New", monospace;
      font-size: 12px;
      white-space: pre-wrap;
      line-height: 1.45;
    }
    .postponed-text {
      color: #7a7f87;
    }
    .level-badge, .what-badge {
      display: inline-block;
      border-radius: 999px;
      padding: 4px 10px;
      font-weight: 700;
      font-size: 12px;
      white-space: nowrap;
    }
    .level-failure { background: var(--failure); color: #fff; }
    .level-warning { background: var(--warning); color: #111; }
    .level-notice { background: var(--notice); color: #fff; }
    .level-postponed { background: var(--postponed); color: #fff; }
    .level-pass { background: var(--pass); color: #fff; }
    .level-debug, .level-info { background: var(--debug); color: #fff; }
    .what-suppress { background: var(--suppress); color: #fff; }
    .what-postpone { background: var(--postpone); color: #fff; }
    .what-must-fix { background: var(--mustfix); color: #fff; }
    .what-not-sure { background: var(--notsure); color: #fff; }
    .cmd {
      color: #41515a;
      font-family: Consolas, "Courier New", monospace;
      font-size: 12px;
      white-space: pre-wrap;
      line-height: 1.45;
    }
    .hidden-column {
      display: none;
    }
    .muted {
      color: var(--muted);
    }
    .copy-status {
      font-size: 12px;
      color: var(--muted);
      min-height: 18px;
      margin-left: 4px;
    }
    .copy-status.success {
      color: var(--accent-strong);
    }
    .copy-status.error {
      color: var(--mustfix);
    }
    @media (max-width: 1100px) {
      .shell {
        padding: 18px;
      }
      .controls input[type=text] {
        min-width: 240px;
        flex-basis: 100%;
      }
      table {
        min-width: 980px;
      }
    }
  </style>
</head>
<body>
  <div class="shell">
    <div class="hero">
      <h1>$safeTitle</h1>
      <div class="controls">
        <input id="textFilter" type="text" placeholder="Filter text. Example: foo -bar">
        <select id="sortField">
          <option value="Computer">Sort by computer</option>
          <option value="EffectiveLevel">Sort by level</option>
          <option value="Message">Sort by message</option>
        </select>
        <button id="sortDirection" type="button">Ascending</button>
        <button id="copyVisibleCommands" type="button" class="utility-button"><strong>Copy Action Commands</strong></button>
        <span id="copyStatus" class="copy-status"></span>
      </div>
      <div class="controls">
        <span class="controls-label">Show rows with this action:</span>
        <button type="button" class="what-filter active-filter" data-filter="">All actions</button>
        <button type="button" class="what-filter" data-filter="suppress">Suppress</button>
        <button type="button" class="what-filter" data-filter="postpone">Postpone</button>
        <button type="button" class="what-filter" data-filter="must-fix">Must-fix</button>
        <button type="button" class="what-filter" data-filter="not-sure">Not-sure</button>
        <label class="plain-toggle" for="showPostponed">
          <span class="toggle-text">Show Postponed</span>
          <input id="showPostponed" type="checkbox">
          <span class="toggle-track" aria-hidden="true"></span>
        </label>
      </div>
      <div class="column-controls">
        <span class="controls-label">Visible Columns:</span>
        <label><input class="column-toggle" type="checkbox" data-column="computer" checked> Computer</label>
        <label><input class="column-toggle" type="checkbox" data-column="level" checked> Level</label>
        <label><input class="column-toggle" type="checkbox" data-column="message" checked> Message</label>
        <label><input class="column-toggle" type="checkbox" data-column="comment" checked> Comment</label>
        <label><input class="column-toggle" type="checkbox" data-column="command"> AddWhitelist command</label>
      </div>
      <div class="summary" id="summary"></div>
    </div>
    <div class="table-wrap">
      <table>
        <colgroup>
          <col class="col-computer col-width-computer">
          <col class="col-level col-width-level">
          <col class="col-action col-width-action">
          <col class="col-message col-width-message">
          <col class="col-comment col-width-comment">
          <col class="col-command col-width-command">
        </colgroup>
        <thead>
          <tr>
            <th class="col-computer">Computer</th>
            <th class="col-level">Level</th>
            <th class="col-action">Action</th>
            <th class="col-message">Message</th>
            <th class="col-comment">Comment</th>
            <th class="col-command">AddWhitelist command</th>
          </tr>
        </thead>
        <tbody id="reportRows"></tbody>
      </table>
    </div>
    <div class="footer">$safeFooterHtml</div>
  </div>
  <script>
    (function () {
      var storageKey = 'gch-report-actions-v2';
      var rows = $jsonRows;
      if (!Array.isArray(rows)) {
        rows = rows ? [rows] : [];
      }
      var levelOrder = { failure: 1, warning: 2, notice: 3, postponed: 4, info: 5, pass: 6, debug: 7 };
      var actionState = {};
      var actionHistory = [];
      try {
        var saved = window.localStorage.getItem(storageKey);
        if (saved) {
          var parsedState = JSON.parse(saved) || {};
          if (Array.isArray(parsedState)) {
            actionHistory = parsedState.slice(-100);
          } else {
            if (parsedState.ActionHistory && Array.isArray(parsedState.ActionHistory)) {
              actionHistory = parsedState.ActionHistory.slice(-100);
            }
            if (parsedState.ActionState && parsedState.ActionState.constructor === Object) {
              actionState = parsedState.ActionState;
            }
          }
        }
      } catch (error) {
        actionState = {};
        actionHistory = [];
      }

      function keyForRow(row) {
        return [row.Computer || '', row.Hash || ''].join('|');
      }

      if (!Object.keys(actionState).length && actionHistory.length) {
        actionHistory.forEach(function (entry) {
          if (!entry || !entry.ComputerName || !entry.FindingHash || !entry.WhatToDo) {
            return;
          }
          actionState[[entry.ComputerName, entry.FindingHash].join('|')] = entry.WhatToDo;
        });
      }

      function saveState() {
        try {
          window.localStorage.setItem(storageKey, JSON.stringify({
            ActionHistory: actionHistory.slice(-100),
            ActionState: actionState
          }));
        } catch (error) {
        }
      }

      function htmlEncode(value) {
        return String(value || '')
          .replace(/&/g, '&amp;')
          .replace(/</g, '&lt;')
          .replace(/>/g, '&gt;')
          .replace(/"/g, '&quot;')
          .replace(/'/g, '&#39;');
      }

      function actionClass(value) {
        return 'what-' + String(value || 'not-sure').replace(/[^a-z-]/g, '');
      }

      function levelClass(value) {
        return 'level-' + String(value || 'info').toLowerCase().replace(/[^a-z-]/g, '');
      }

      function normalizeAction(row) {
        var key = keyForRow(row);
        if (actionState[key]) {
          row.WhatToDo = actionState[key];
        } else {
          row.WhatToDo = 'not-sure';
        }
      }

      function rememberActionChoice(row) {
        var choice = {
          ComputerName: String(row.Computer || ''),
          FindingHash: String(row.Hash || ''),
          WhatToDo: String(row.WhatToDo || 'not-sure')
        };
        actionHistory = actionHistory.filter(function (entry) {
          return !(
            entry &&
            entry.ComputerName === choice.ComputerName &&
            entry.FindingHash === choice.FindingHash
          );
        });
        actionHistory.push(choice);
        if (actionHistory.length > 100) {
          actionHistory = actionHistory.slice(actionHistory.length - 100);
        }
      }

      function rotateAction(current) {
        var values = ['suppress', 'postpone', 'must-fix', 'not-sure'];
        var index = values.indexOf(current);
        if (index < 0) { index = values.length - 1; }
        return values[(index + 1) % values.length];
      }

      function tokenize(text) {
        return String(text || '').toLowerCase().split(/\s+/).filter(Boolean);
      }

      function rowSearchText(row) {
        return [
          row.Computer || '',
          row.EffectiveLevel || row.Level || '',
          row.Message || '',
          row.Comment || ''
        ].join(' ').toLowerCase();
      }

      function currentWhatFilter() {
        var active = document.querySelector('.what-filter.active-filter');
        return active ? active.getAttribute('data-filter') : '';
      }

      function setCopyStatus(message, cssClass) {
        var status = document.getElementById('copyStatus');
        status.textContent = message || '';
        status.className = 'copy-status' + (cssClass ? ' ' + cssClass : '');
      }

      function compareRows(left, right, field, ascending) {
        var a = left[field] || '';
        var b = right[field] || '';
        if (field === 'EffectiveLevel') {
          a = levelOrder[String(a).toLowerCase()] || 999;
          b = levelOrder[String(b).toLowerCase()] || 999;
        } else {
          a = String(a).toLowerCase();
          b = String(b).toLowerCase();
        }
        if (a === b) { return 0; }
        var result = a > b ? 1 : -1;
        return ascending ? result : result * -1;
      }

      function buildWhitelistCommand(row) {
        var level = String(row.Level || '').toLowerCase();
        var hash = String(row.Hash || '');
        var computer = String(row.Computer || '');
        var message = String(row.Message || '');
        var whatToDo = String(row.WhatToDo || '').toLowerCase();
        if (!hash || !computer || !message) {
          return '';
        }
        if (String(row.Suppressed).toLowerCase() === 'true') {
          return '';
        }
        if (level === 'info' || level === 'debug') {
          return '';
        }
        if (whatToDo === 'must-fix' || whatToDo === 'not-sure' || !whatToDo) {
          return '';
        }
        var until = '2999-12-31';
        if (whatToDo === 'postpone') {
          var untilDate = new Date();
          untilDate.setDate(untilDate.getDate() + 30);
          until = untilDate.getFullYear()
            + '-' + String(untilDate.getMonth() + 1).padStart(2, '0')
            + '-' + String(untilDate.getDate()).padStart(2, '0');
        }
        else if (whatToDo !== 'suppress') {
          return '';
        }
        var safeComment = (level + ' - ' + message).replace(/"/g, '`"');
        return "Invoke-Command " + computer
          + " {\"c:\\it\\Get-ComputerHealth\\bin\\Get-ComputerHealth.ps1\" -AddWhitelisting -until "
          + until
          + " -sig '"
          + hash
          + "' -ComputerName "
          + computer
          + " -comment \""
          + safeComment
          + "\"}";
      }

      function render() {
        var filterText = document.getElementById('textFilter').value;
        var tokens = tokenize(filterText);
        var showPostponed = document.getElementById('showPostponed').checked;
        var sortField = document.getElementById('sortField').value;
        var ascending = document.getElementById('sortDirection').getAttribute('data-direction') !== 'desc';
        var whatFilter = currentWhatFilter();
        var body = document.getElementById('reportRows');
        var filtered = rows.filter(function (row) {
          normalizeAction(row);
          if (!showPostponed && String(row.EffectiveLevel || row.Level || '').toLowerCase() === 'postponed') {
            return false;
          }
          if (whatFilter && row.WhatToDo !== whatFilter) {
            return false;
          }
          var haystack = rowSearchText(row);
          for (var i = 0; i < tokens.length; i++) {
            var token = tokens[i];
            if (token.charAt(0) === '-') {
              if (token.length > 1 && haystack.indexOf(token.substring(1)) !== -1) {
                return false;
              }
            } else if (haystack.indexOf(token) === -1) {
              return false;
            }
          }
          return true;
        });

        filtered.sort(function (left, right) {
          return compareRows(left, right, sortField, ascending);
        });

        body.innerHTML = filtered.map(function (row, index) {
          var key = htmlEncode(keyForRow(row));
          var isPostponed = String(row.EffectiveLevel || row.Level || '').toLowerCase() === 'postponed';
          var postponedClass = isPostponed ? ' postponed-text' : '';
          var commentHtml = htmlEncode(row.Comment || '').replace(/\r?\n/g, '<br>');
          var commandHtml = htmlEncode(buildWhitelistCommand(row)).replace(/\r?\n/g, '<br>');
          var actionHtml = '';
          if (!isPostponed) {
            actionHtml = '<button type="button" class="what-badge ' + actionClass(row.WhatToDo) + '" data-row-key="' + key + '" data-index="' + index + '">' + htmlEncode(row.WhatToDo) + '</button>';
          }
          return ''
            + '<tr>'
            + '<td class="col-computer">' + htmlEncode(row.Computer || '') + '</td>'
            + '<td class="col-level"><span class="level-badge ' + levelClass((row.EffectiveLevel || row.Level || '').toLowerCase()) + '">' + htmlEncode(row.EffectiveLevel || row.Level || '') + '</span></td>'
            + '<td class="col-action">' + actionHtml + '</td>'
            + '<td class="col-message' + postponedClass + '">' + htmlEncode(row.Message || '') + '</td>'
            + '<td class="col-comment' + postponedClass + '">' + commentHtml + '</td>'
            + '<td class="col-command cmd">' + commandHtml + '</td>'
            + '</tr>';
        }).join('');

        document.querySelectorAll('.what-badge').forEach(function (button) {
          button.addEventListener('click', function () {
            var matchingRow = filtered[parseInt(button.getAttribute('data-index'), 10)];
            if (!matchingRow) {
              return;
            }
            matchingRow.WhatToDo = rotateAction(matchingRow.WhatToDo);
            actionState[keyForRow(matchingRow)] = matchingRow.WhatToDo;
            rememberActionChoice(matchingRow);
            saveState();
            render();
          });
        });

        document.getElementById('summary').innerHTML = ''
          + '<span class="status-item">Visible findings: ' + filtered.length + '</span>'
          + '<span class="status-item">Loaded findings: ' + rows.length + '</span>';

        window.__gchVisibleCommands = filtered.map(function (row) {
          return buildWhitelistCommand(row);
        }).filter(function (command) {
          return Boolean(command);
        });

        document.querySelectorAll('.column-toggle').forEach(function (checkbox) {
          var columnClass = '.col-' + checkbox.getAttribute('data-column');
          document.querySelectorAll(columnClass).forEach(function (cell) {
            cell.classList.toggle('hidden-column', !checkbox.checked);
          });
        });
      }

      document.querySelectorAll('.what-filter').forEach(function (button) {
        button.addEventListener('click', function () {
          document.querySelectorAll('.what-filter').forEach(function (item) {
            item.classList.remove('active-filter');
          });
          button.classList.add('active-filter');
          render();
        });
      });

      document.getElementById('sortDirection').setAttribute('data-direction', 'asc');
      document.getElementById('sortDirection').addEventListener('click', function () {
        var current = this.getAttribute('data-direction');
        var next = current === 'asc' ? 'desc' : 'asc';
        this.setAttribute('data-direction', next);
        this.textContent = next === 'asc' ? 'Ascending' : 'Descending';
        render();
      });

      document.getElementById('textFilter').addEventListener('input', render);
      document.getElementById('sortField').addEventListener('change', render);
      document.getElementById('showPostponed').addEventListener('change', render);
      document.getElementById('copyVisibleCommands').addEventListener('click', function () {
        var commands = window.__gchVisibleCommands || [];
        if (!commands.length) {
          setCopyStatus('No visible commands to copy.', 'error');
          return;
        }
        var text = commands.join('\r\n');
        var copyPromise = null;
        if (navigator.clipboard && navigator.clipboard.writeText) {
          copyPromise = navigator.clipboard.writeText(text);
        } else {
          copyPromise = new Promise(function (resolve, reject) {
            var textArea = document.createElement('textarea');
            textArea.value = text;
            textArea.setAttribute('readonly', 'readonly');
            textArea.style.position = 'absolute';
            textArea.style.left = '-9999px';
            document.body.appendChild(textArea);
            textArea.select();
            try {
              if (document.execCommand('copy')) {
                resolve();
              } else {
                reject(new Error('copy failed'));
              }
            } catch (error) {
              reject(error);
            } finally {
              document.body.removeChild(textArea);
            }
          });
        }
        copyPromise.then(function () {
          setCopyStatus(commands.length + ' visible command(s) copied.', 'success');
        }).catch(function () {
          setCopyStatus('Could not copy action commands.', 'error');
        });
      });
      document.querySelectorAll('.column-toggle').forEach(function (checkbox) {
        checkbox.addEventListener('change', render);
      });

      render();
    }());
  </script>
</body>
</html>
"@
}

function Get-HealthNotableSubject {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$FallbackSubject,
    [Parameter(Mandatory)][object[]]$NotableMessages
  )

  $levelToSubjectPrefix = @{
    'failure'   = 'Failure(s)'
    'warning'   = 'Warning(s)'
    'notice'    = 'Notice(s)'
    'postponed' = 'RELAX. No notable Messages'
  }
  $priority = @('failure', 'warning', 'notice', 'postponed')

  $levelsInRun = @(
    $NotableMessages |
      Where-Object { $_ } |
      ForEach-Object {
        if ($_.PSObject.Properties['EffectiveLevel']) {
          ([string]$_.EffectiveLevel).Trim().ToLowerInvariant()
        }
        elseif ($_.PSObject.Properties['Level']) {
          ([string]$_.Level).Trim().ToLowerInvariant()
        }
      } |
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

  $rerunArgs = @(
    Convert-BoundParametersToInvocationArguments -BoundParameters $BoundParameters -Exclude @('AlreadyReranAfterUpdate', 'PassThruArgs')
  )
  $rerunArgs += '-AlreadyReranAfterUpdate'
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

$localUpdateAlreadyRan = $false
if (-not $NoUpdate) {
  $versionBeforeUpdate = Get-EmbeddedGetComputerHealthVersion -ScriptPath $GET_HEALTH_SCRIPT_PATH
  try {
    & $UPDATE_SCRIPT_PATH
    $localUpdateAlreadyRan = $true
    $versionAfterUpdate = Get-EmbeddedGetComputerHealthVersion -ScriptPath $GET_HEALTH_SCRIPT_PATH

    if (
      -not $AlreadyReranAfterUpdate -and
      -not [string]::IsNullOrWhiteSpace($versionBeforeUpdate) -and
      -not [string]::IsNullOrWhiteSpace($versionAfterUpdate) -and
      $versionBeforeUpdate -ne $versionAfterUpdate
    ) {
      Write-Host -ForegroundColor Yellow "Get-ComputerHealth was updated from version $versionBeforeUpdate to $versionAfterUpdate. Re-running Invoke-GetComputerHealth.ps1 once."
      Invoke-SelfAfterUpdate -BoundParameters $PSBoundParameters -PassThruArgs $PassThruArgs
    }
  }
  catch {
    Write-Warning "Early update check failed: $($_.Exception.Message). Continuing with normal target execution."
  }
}

Start-Transcript (Join-Path $LOG_DIR "Invoke-GetHealthDomainComputers-$timestamp.log")
. $LIB_LOG_OBJECTS_PATH
$embeddedVersion = Get-EmbeddedGetComputerHealthVersion -ScriptPath $GET_HEALTH_SCRIPT_PATH
$emailSignature = Get-HealthEmailSignature -VersionFilePath $VERSION_FILE_PATH -FallbackVersion $embeddedVersion -FallbackTimestampPath $GET_HEALTH_SCRIPT_PATH
$emailDecision = Get-HealthEmailDecision -NoSendReport:$NoSendReport -SendReport:$SendReport -NonInteractiveContext:(Test-IsNonInteractiveContext)
$sendMailByDefault = [bool]$emailDecision.ShouldSend
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
$SmtpSubject = $SmtpSubject -replace 'LIST_OF_COMPUTERS', ($targets -join ',')
$SmtpSubjectAllGood = $SmtpSubjectAllGood -replace 'LIST_OF_COMPUTERS', ($targets -join ',')

$localReleaseZip = $null
$localReleaseZipVersion = $null
if ($PushUpdate) {
  $localReleaseZip = Get-LatestLocalReleaseZip
  if (-not $localReleaseZip) {
    Write-Warning "-PushUpdate was requested but no local update zip was found (metadata marker or cached zip in ${TEMP_DIR}). Falling back to normal update behavior."
  } else {
    $localReleaseZipVersion = Get-UpdateZipVersionArgument -ZipPath $localReleaseZip -FallbackVersion $embeddedVersion
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
    $output = & $healthCheckBlock $ROOT_DIR $Hide $OnlyTheseTests $ExcludeTests $WhitelistSigs $SkipSlowTests $SkipPolicyTests $SkipNonEssentialTests $skipTargetUpdate $RunWithoutElevation $IpsOfAllDcs $PushUpdate $localReleaseZip $localReleaseZipVersion $SHOW_AS_POSTPONED_WINDOW_DAYS $PassThruArgs
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

        $output = Invoke-Command -Session $session -ScriptBlock $healthCheckBlock -ArgumentList $remoteExecutionRoot, $Hide, $OnlyTheseTests, $ExcludeTests, $WhitelistSigs, $SkipSlowTests, $SkipPolicyTests, $SkipNonEssentialTests, $NoUpdate, $RunWithoutElevation, $IpsOfAllDcs, $PushUpdate, $remoteZipPath, $localReleaseZipVersion, $SHOW_AS_POSTPONED_WINDOW_DAYS, $PassThruArgs
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

$SortOrder = @{'failure' = 1; 'warning' = 2; 'notice' = 3; 'postponed' = 4; 'info' = 5; 'pass' = 6; 'debug' = 7 }
$notable_msgs = @()
if ($all_messages) {
  foreach ($message in $all_messages) {
    if ($message -and (-not $message.PSObject.Properties['EffectiveLevel'])) {
      $level = if ($message.PSObject.Properties['Level']) { [string]$message.Level } else { '' }
      $message | Add-Member -NotePropertyName EffectiveLevel -NotePropertyValue $level -Force
    }
  }

  # save
  $reportArtifacts = Get-HealthReportArtifactPaths -DataDir $DATA_DIR -TempDir $TEMP_DIR -Timestamp $timestamp
  $allMessagesClixmlTempPath = $reportArtifacts.AllMessagesClixmlTempPath
  $allMessagesZipPath = $reportArtifacts.AllMessagesZipPath
  Export-HealthMessagesReportData -Messages $all_messages -FileName $allMessagesClixmlTempPath
  Compress-HealthReportDataFile -SourcePath $allMessagesClixmlTempPath -DestinationPath $allMessagesZipPath
  $notable_msgs = @(`
      $all_messages `
    | Where-Object { (-not($_.Suppressed) -and $_.level -notin @('debug', 'help', 'pass', 'info')) -or ($_.EffectiveLevel -eq 'postponed') } `
    | Sort-Object -Property @{ Expression = { $SortOrder[$_.EffectiveLevel] } }, Computer `
  )

  $synopsis = " " + ($notable_msgs | Where-Object { $_.EffectiveLevel } |
    Group-Object EffectiveLevel -NoElement |
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
    Write-host -for yellow "    $($reportArtifacts.LastInteractiveReportHtmlPath)"
    Write-host -for gray   "    $allMessagesZipPath"
    Write-host -for gray   "Open the HTML report in a browser or expand/load the CLIXML archive in PowerShell like this:"
    Write-host -for gray   "    Expand-Archive -LiteralPath $allMessagesZipPath -DestinationPath .\temp\report-data -Force"
    Write-host -for gray   "    `$data = Import-Clixml .\temp\report-data\all-messages-$timestamp.clixml"
    Write-host -for gray   '    $data|ogv # GUI review'
    Write-host -for gray   '    $data|select -Property Computer,Level,Message # Console review'

    Write-host -for gray   ""
    Write-host -for gray   "Preparing notable report"

    $htmlParts = @()
    $htmlSynopsis = Convert-HealthSynopsisToHtml -Messages @($notable_msgs)
    if (-not [string]::IsNullOrWhiteSpace($htmlSynopsis)) {
      $htmlParts += $htmlSynopsis
    }
    $htmlParts += Convert-HealthMessagesToHtmlTable -Messages @(
      $notable_msgs | Sort-Object -Property @{ Expression = { $SortOrder[$_.EffectiveLevel] } }, Computer
    )
    $html = $htmlParts -join ''
    $interactiveRows = @(Convert-HealthReportRowsToInteractiveRows -Rows $notable_msgs)
    $interactiveLocationLine = (($emailSignature.Text -split "\r?\n")[0]).Trim()
    $interactiveLocationSuffix = $interactiveLocationLine -replace '^Tests started from\s+\S+\s+', ''
    if ([string]::IsNullOrWhiteSpace($interactiveLocationSuffix)) {
      $interactiveLocationSuffix = ($targets -join ', ')
    }
    $interactiveReportTitle = "Test findings for {0} -- {1}" -f (($targets -join ', '), $interactiveLocationSuffix)
    $interactiveReportHtml = Get-HealthInteractiveHtmlReport -Rows $interactiveRows -Title $interactiveReportTitle -FooterHtml $emailSignature.HtmlBottom
    Save-HealthHtmlReport -Path $reportArtifacts.InteractiveReportTempPath -Html $interactiveReportHtml

    $signedHtml = Add-HealthEmailSignature -Body $html -BodyAsHtml -Signature $emailSignature
    Save-HealthHtmlReport -Path $reportArtifacts.LastEmailBodyHtmlPath -Html $signedHtml
    $smtpNotableSubject = Get-HealthNotableSubject -FallbackSubject $SmtpSubject -NotableMessages $notable_msgs
    Write-Host -for Gray ("Email report decision: {0}" -f $emailDecision.Reason)
    try {
      Invoke-HealthEmail -Subject $smtpNotableSubject -Body $signedHtml -BodyAsHtml -Attachments $reportArtifacts.InteractiveReportTempPath -ConfigFile $SmtpConfig -NoSendReport:(-not $sendMailByDefault) -SkipReason $emailDecision.Reason
    }
    finally {
      if (Test-Path -LiteralPath $reportArtifacts.InteractiveReportTempPath -PathType Leaf) {
        Move-HealthReportFile -SourcePath $reportArtifacts.InteractiveReportTempPath -DestinationPath $reportArtifacts.LastInteractiveReportHtmlPath
      }
    }
  }
  else {
    Write-host -for green    "GOOD, Nothing notable to record. I have saved less notable messages here:"
    Write-host -for gray     "    $allMessagesZipPath"
    $signedBody = Add-HealthEmailSignature -Body (Get-RelaxHtmlBody) -BodyAsHtml -Signature $emailSignature
    Save-HealthHtmlReport -Path $LAST_REPORT_HTML_PATH -Html $signedBody
    Write-Host -for Gray ("Email report decision: {0}" -f $emailDecision.Reason)
    Invoke-HealthEmail -Subject $SmtpSubjectAllGood -Body $signedBody -BodyAsHtml -ConfigFile $SmtpConfig -NoSendReport:(-not $sendMailByDefault) -SkipReason $emailDecision.Reason
  }
}
else {
}

Stop-Transcript
