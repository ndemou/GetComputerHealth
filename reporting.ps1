$script:GetComputerHealthReportingScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:GetComputerHealthReportingScriptDir)) {
  $script:GetComputerHealthReportingScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Get-EmbeddedGetComputerHealthVersion {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ScriptPath
  )

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
    Write-Host -for Yellow $SkipReason
    return
  }

  if (-not (Test-Path $ConfigFile)) {
    Write-Host -for Yellow ("Will not send email report. Reason: send-message.ps1 is not configured. If you want to configure it run ``Send-Message.ps1 -GenerateConfig '{0}'``." -f $ConfigFile)
    return
  }
  $sendMessageScriptPath = Join-Path $script:GetComputerHealthReportingScriptDir 'Send-Message.ps1'
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
    & $sendMessageScriptPath @mailParams
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
    if ($baseBody -match '(?is)<html\b') {
      return ($baseBody -replace '(?is)</body\s*>', "<div style='margin-top:12px; font-family:Aptos, Arial, sans-serif'><div style='color:#000; font-size:12px'>$($Signature.HtmlTop)</div><div style='color:#666; font-size:10px'>$($Signature.HtmlBottom)</div></div></body>")
    }

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
$(Get-HealthEmailCss)
  </style>
</head>
<body class="gch-root" style="margin:0; padding:12px; width:100%; font-family:Aptos, Arial, sans-serif; font-size:11pt; color:#000;">
$baseBody<div class="gch-signature"><div class="gch-signature-top">$($Signature.HtmlTop)</div><div class="gch-signature-bottom">$($Signature.HtmlBottom)</div></div>
</body>
</html>
"@
  }

  if ([string]::IsNullOrEmpty($Body)) {
    return $Signature.Text
  }

  return ($Body.TrimEnd() + "`r`n`r`n" + $Signature.Text)
}
function Get-HealthEmailCss {
  [CmdletBinding()]
  param()

  return @'
.gch-root {
  width: 100%;
  font-family: Aptos, Arial, sans-serif;
  font-size: 11pt;
  color: #000;
}

.gch-synopsis {
  margin: 0 0 8px 0;
}

.gch-divider {
  border-top: 1px solid #cfcfcf;
  margin: 0 0 12px 0;
}

.gch-divider-postponed {
  margin: 12px 0;
}

.gch-pill {
  display: inline-block;
  margin: 0 12px 0 4px;
  padding: 1px 6px;
  border-radius: 999px;
  font-weight: 700;
}

.gch-row {
  margin-bottom: 10px;
}

.gch-computer {
  font-weight: 700;
  color: rgba(0,0,0,0.8);
}

.gch-level {
  display: inline-block;
  margin-left: 8px;
  padding: 1px 6px;
  border-radius: 999px;
}

.gch-message {
  margin-left: 8px;
}

.gch-comment {
  margin-left: 8px;
  color: #0D60A8;
  font-family: "Aptos Narrow", Aptos, Arial, sans-serif;
  font-size: 9pt;
}

.gch-postponed {
  color: #2e7d32;
  font-size: 10pt;
  margin-left: 8px;
}

.gch-command {
  margin-top: 4px;
  color: #666;
  font-size: 6pt;
  font-family: "Arial Narrow", Arial, sans-serif;
}

.gch-signature {
  margin-top: 12px;
  font-family: Aptos, Arial, sans-serif;
}

.gch-signature-top {
  color: #000;
  font-size: 9pt;
}

.gch-signature-bottom {
  color: #666;
  font-size: 8pt;
}
'@
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
    $baseCommand = ("& ""c:\it\Get-ComputerHealth\bin\Get-ComputerHealth.ps1"" -AddWhitelisting -until 2999-12-31 -sig '{0}' -ComputerName {1} -comment ""{2}""" -f $hash.ToLowerInvariant(), $computer.Trim(), $commentText)
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
    'postponed' = @{ Label = 'postponed'; Background = '#30510c'; Foreground = '#fff' }
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
        "<span class='gch-pill' style='background-color:$($meta.Background); color:$($meta.Foreground)'>" + ([System.Net.WebUtility]::HtmlEncode([string]$_.Count)) + ' ' + ([System.Net.WebUtility]::HtmlEncode($meta.Label)) + "</span>"
      }
  )

  if ($parts.Count -eq 0) {
    return ''
  }

    return "<div class='gch-synopsis'>" + ($parts -join '   ') + "</div><div class='gch-divider'></div>"
}

function Get-HealthCommentPreviewText {
  [CmdletBinding()]
  param(
    [AllowEmptyString()][string]$Comment,
    [int]$MaxLength = 200
  )

  $text = [string]$Comment
  if ([string]::IsNullOrWhiteSpace($text)) {
    return ''
  }

  $normalized = $text.Trim() -replace "(`r`n|`n|`r)", ' ◆ '
  if ($normalized.Length -gt $MaxLength) {
    return $normalized.Substring(0, $MaxLength)
  }

  return $normalized
}

function Convert-HealthMessagesToHtmlTable {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object[]]$Messages
  )

  $rows = for ($messageIndex = 0; $messageIndex -lt $Messages.Count; $messageIndex++) {
    $message = $Messages[$messageIndex]
    $realLevel = if ($message.PSObject.Properties['Level']) { [string]$message.Level } else { '' }
    $level = if ($message.PSObject.Properties['EffectiveLevel']) { [string]$message.EffectiveLevel } else { $realLevel }
    $computer = if ($message.PSObject.Properties['Computer']) { [string]$message.Computer } else { '' }
    $text = if ($message.PSObject.Properties['Message']) { [string]$message.Message } else { '' }
    $comment = if ($message.PSObject.Properties['Comment']) { [string]$message.Comment } else { '' }
    $suppressionCommand = Get-HealthSuppressionCommand -MessageRecord $message -WrapInInvokeCommand:$false
    $displayLevel = if ([string]::IsNullOrWhiteSpace($level)) { '' } else { $level.Substring(0, 1).ToUpperInvariant() + $level.Substring(1).ToLowerInvariant() }
    $levelBackground = switch ($level.ToLowerInvariant()) {
      'failure' { '#ff4d4f' }
      'warning' { '#ffb300' }
      'notice'  { '#1e88e5' }
      'postponed' { '#30510c' }
      default   { '#c7d0d9' }
    }
    $levelForeground = switch ($level.ToLowerInvariant()) {
      'warning' { '#111' }
      default   { '#fff' }
    }

    $messageHtml = [System.Net.WebUtility]::HtmlEncode($text)
    $commentPreviewText = Get-HealthCommentPreviewText -Comment $comment
    $headerComputerStyle = ''
    $headerMessageStyle = ''
    if ($level -ieq 'postponed') {
      $headerComputerStyle = " style='color:#30510c'"
      $headerMessageStyle = " style='color:#30510c'"
    }

    $headerHtml = "<div><span class='gch-computer'$headerComputerStyle>" + ([System.Net.WebUtility]::HtmlEncode($computer)) + "</span><span class='gch-level' style='background-color:$levelBackground; color:$levelForeground'>" + ([System.Net.WebUtility]::HtmlEncode($displayLevel)) + "</span><span class='gch-message'$headerMessageStyle>$messageHtml</span>"
    if (($level -ine 'postponed') -and (-not [string]::IsNullOrWhiteSpace($suppressionCommand)) -and (-not [string]::IsNullOrWhiteSpace($commentPreviewText))) {
      $headerHtml += "<span class='gch-comment'>" + ([System.Net.WebUtility]::HtmlEncode('◆ ' + $commentPreviewText)) + "</span>"
    }
    if (($level -ieq 'postponed') -and (-not [string]::IsNullOrWhiteSpace($realLevel))) {
      $postponedUntilText = 'unknown date'
      if ($message.PSObject.Properties['SuppressedUntil']) {
        $suppressedUntilValue = $message.SuppressedUntil
        if ($suppressedUntilValue -is [datetime]) {
          $postponedUntilText = $suppressedUntilValue.ToString('yyyy-MM-dd')
        }
      }

      $displayRealLevel = $realLevel.Substring(0, 1).ToUpperInvariant() + $realLevel.Substring(1).ToLowerInvariant()
      $headerHtml += "<span class='gch-postponed' style='color:#30510c'>(" + ([System.Net.WebUtility]::HtmlEncode($displayRealLevel)) + " postponed until " + ([System.Net.WebUtility]::HtmlEncode($postponedUntilText)) + ")</span>"
    }
    $headerHtml += "</div>"
    $detailsHtml = $headerHtml

    if (($level -ine 'postponed') -and (-not [string]::IsNullOrWhiteSpace($suppressionCommand))) {
      $detailsHtml += "<div class='gch-command'>" + ([System.Net.WebUtility]::HtmlEncode($suppressionCommand)) + "</div>"
    }

    $rowHtml = "<div class='gch-row'>$detailsHtml</div>"
    $nextLevel = ''
    if (($messageIndex + 1) -lt $Messages.Count) {
      $nextMessage = $Messages[$messageIndex + 1]
      $nextRealLevel = if ($nextMessage.PSObject.Properties['Level']) { [string]$nextMessage.Level } else { '' }
      $nextLevel = if ($nextMessage.PSObject.Properties['EffectiveLevel']) { [string]$nextMessage.EffectiveLevel } else { $nextRealLevel }
    }

    $previousLevel = ''
    if ($messageIndex -gt 0) {
      $previousMessage = $Messages[$messageIndex - 1]
      $previousRealLevel = if ($previousMessage.PSObject.Properties['Level']) { [string]$previousMessage.Level } else { '' }
      $previousLevel = if ($previousMessage.PSObject.Properties['EffectiveLevel']) { [string]$previousMessage.EffectiveLevel } else { $previousRealLevel }
    }

    if (($level -ieq 'postponed') -and ($previousLevel -ne 'postponed') -and ($messageIndex -gt 0)) {
      $rowHtml = "<div class='gch-divider gch-divider-postponed'></div>" + $rowHtml
    }

    if (($level -ieq 'postponed') -and ($nextLevel -ine 'postponed')) {
      $rowHtml += "<div class='gch-divider gch-divider-postponed'></div>"
    }

    $rowHtml
  }

  return @(
    "<div class='gch-root'>"
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
<body style="background-color: #eef2f5; margin: 0; padding: 50px 20px; text-align: center; font-family: Aptos, Arial, sans-serif;">
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
      Emitter        = if ($row.PSObject.Properties['Emitter']) { [string]$row.Emitter } else { '' }
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
    LastAllFindingsClixmlPath      = Join-Path $TempDir 'last-all-findings.clixml'
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

  $templatePath = Join-Path $script:GetComputerHealthReportingScriptDir 'interactive-report-template.html'
  $template = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8
  $template = $template.Replace('__GCH_REPORT_TITLE__', $safeTitle)
  $template = $template.Replace('__GCH_REPORT_FOOTER_HTML__', $safeFooterHtml)
  $template = $template.Replace('__GCH_REPORT_ROWS_JSON__', $jsonRows)

  return $template
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

function Get-HealthReportingTargets {
  [CmdletBinding()]
  param(
    [AllowEmptyCollection()][string[]]$Targets,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Messages
  )

  if ($Targets -and $Targets.Count -gt 0) {
    return @(
      $Targets |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
    )
  }

  $derivedTargets = New-Object System.Collections.Generic.List[string]
  foreach ($message in $Messages) {
    if ($null -eq $message) {
      continue
    }

    if (-not $message.PSObject.Properties['Computer']) {
      continue
    }

    $computer = ([string]$message.Computer).Trim()
    if (-not [string]::IsNullOrWhiteSpace($computer)) {
      $derivedTargets.Add($computer)
    }
  }

  return @($derivedTargets | Sort-Object -Unique)
}

function Get-HealthReportingSubjects {
  [CmdletBinding()]
  param(
    [AllowEmptyCollection()][string[]]$Targets
  )

  $targetText = @($Targets) -join ','
  $notableSubject = 'Notable Messages from Get-ComputerHealth of LIST_OF_COMPUTERS'
  $allGoodSubject = 'RELAX. No notable Messages from Get-ComputerHealth of LIST_OF_COMPUTERS'

  $notableSubject = $notableSubject -replace 'LIST_OF_COMPUTERS', $targetText
  $allGoodSubject = $allGoodSubject -replace 'LIST_OF_COMPUTERS', $targetText

  return [pscustomobject]@{
    NotableSubject = $notableSubject
    AllGoodSubject = $allGoodSubject
  }
}

function Normalize-HealthMessagesForReporting {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Messages
  )

  $normalized = New-Object System.Collections.Generic.List[object]
  foreach ($message in $Messages) {
    if ($null -eq $message) {
      continue
    }

    $effectiveLevel = ''
    if ($message.PSObject.Properties['EffectiveLevel']) {
      $effectiveLevel = [string]$message.EffectiveLevel
    }
    elseif ($message.PSObject.Properties['Level']) {
      $effectiveLevel = [string]$message.Level
    }

    $copy = $message | Select-Object -Property *
    if ($copy.PSObject.Properties['EffectiveLevel']) {
      $copy.EffectiveLevel = $effectiveLevel
    }
    else {
      $copy | Add-Member -NotePropertyName EffectiveLevel -NotePropertyValue $effectiveLevel
    }

    $normalized.Add($copy)
  }

  return $normalized.ToArray()
}

function Invoke-GetComputerHealthReporting {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [object[]]$Messages,

    [switch]$NoSendReport,

    [switch]$SendReport,

    [string]$Timestamp,

    [string[]]$Targets
  )

  if (-not $Messages -or $Messages.Count -eq 0) {
    return
  }

  if ([string]::IsNullOrWhiteSpace($Timestamp)) {
    $Timestamp = Get-Date -Format 'yyyy-MM-dd_HH.mm'
  }

  $scriptBinDir = (Resolve-Path -LiteralPath $script:GetComputerHealthReportingScriptDir).Path
  $rootDir = Split-Path -Parent $scriptBinDir
  $configDir = Join-Path $rootDir 'config'
  $tempDir = Join-Path $rootDir 'temp'
  $dataDir = Join-Path $rootDir 'data'
  $versionFilePath = Join-Path $scriptBinDir 'VERSION'
  $getHealthScriptPath = Join-Path $scriptBinDir 'Get-ComputerHealth.ps1'
  $lastReportHtmlPath = Join-Path $tempDir 'last-report.html'
  $smtpConfig = Join-Path $configDir 'Send-Message.conf'
  $smtpConfigPsd1 = Join-Path $configDir 'Send-Message.psd1'
  if ((-not (Test-Path -LiteralPath $smtpConfig -PathType Leaf)) -and (Test-Path -LiteralPath $smtpConfigPsd1 -PathType Leaf)) {
    $smtpConfig = $smtpConfigPsd1
  }

  $normalizedMessages = @(Normalize-HealthMessagesForReporting -Messages $Messages)
  $Targets = @(Get-HealthReportingTargets -Targets $Targets -Messages $normalizedMessages)
  $subjects = Get-HealthReportingSubjects -Targets $Targets
  $reportArtifacts = Get-HealthReportArtifactPaths -DataDir $dataDir -TempDir $tempDir -Timestamp $Timestamp
  $allMessagesClixmlTempPath = $reportArtifacts.AllMessagesClixmlTempPath
  $allMessagesZipPath = $reportArtifacts.AllMessagesZipPath
  $lastAllFindingsClixmlPath = $reportArtifacts.LastAllFindingsClixmlPath
  $embeddedVersion = Get-EmbeddedGetComputerHealthVersion -ScriptPath $getHealthScriptPath
  $emailSignature = Get-HealthEmailSignature -VersionFilePath $versionFilePath -FallbackVersion $embeddedVersion -FallbackTimestampPath $getHealthScriptPath
  $emailDecision = Get-HealthEmailDecision -NoSendReport:$NoSendReport -SendReport:$SendReport -NonInteractiveContext:(Test-IsNonInteractiveContext)
  $sendMailByDefault = [bool]$emailDecision.ShouldSend
  $sortOrder = @{ 'failure' = 1; 'warning' = 2; 'notice' = 3; 'postponed' = 4; 'info' = 5; 'pass' = 6; 'debug' = 7 }

  Export-HealthMessagesReportData -Messages $normalizedMessages -FileName $allMessagesClixmlTempPath
  Copy-Item -LiteralPath $allMessagesClixmlTempPath -Destination $lastAllFindingsClixmlPath -Force
  Compress-HealthReportDataFile -SourcePath $allMessagesClixmlTempPath -DestinationPath $allMessagesZipPath

  $notableMessages = @(
    $normalizedMessages |
      Where-Object { (-not $_.Suppressed -and $_.Level -notin @('debug', 'help', 'pass', 'info')) -or ($_.EffectiveLevel -eq 'postponed') } |
      Sort-Object -Property @{ Expression = { $sortOrder[$_.EffectiveLevel] } }, Computer
  )

  $synopsis = " " + ($notableMessages |
    Where-Object { $_.EffectiveLevel } |
    Group-Object EffectiveLevel -NoElement |
    Sort-Object -Property @{ Expression = { $sortOrder[$_.Name] } } |
    ForEach-Object {
      if ($_.Count) {
        "    $($_.Count.ToString().PadRight(5)) $($_.Name)`r`n"
      }
    })

  Write-Host ""
  Write-Host -for White "Synopsis of notable messages per level"
  Write-Host -for Gray $synopsis
  Write-Host ""

  if ($notableMessages) {
    Write-Host -for Yellow "Found notable messages. I have saved them in these files:"
    Write-Host -for Yellow "    $($reportArtifacts.LastInteractiveReportHtmlPath)"
    Write-Host -for Gray "    $lastAllFindingsClixmlPath"
    Write-Host -for Gray "    $allMessagesZipPath"
    Write-Host -for Gray "Open the HTML report in a browser or load the CLIXML findings in PowerShell like this:"
    Write-Host -for Gray "    `$data = Import-Clixml $lastAllFindingsClixmlPath"
    Write-Host -for Gray '    $data|ogv # GUI review'
    Write-Host -for Gray '    $data|select -Property Computer,Level,Message # Console review'
    Write-Host -for Gray ""
    Write-Verbose "Preparing notable report"

    $htmlParts = @()
    $htmlSynopsis = Convert-HealthSynopsisToHtml -Messages @($notableMessages)
    if (-not [string]::IsNullOrWhiteSpace($htmlSynopsis)) {
      $htmlParts += $htmlSynopsis
    }
    $htmlParts += Convert-HealthMessagesToHtmlTable -Messages @(
      $notableMessages | Sort-Object -Property @{ Expression = { $sortOrder[$_.EffectiveLevel] } }, Computer
    )
    $html = $htmlParts -join ''
    $interactiveRows = @(Convert-HealthReportRowsToInteractiveRows -Rows $notableMessages)
    $interactiveLocationLine = (($emailSignature.Text -split "\r?\n")[0]).Trim()
    $interactiveLocationSuffix = $interactiveLocationLine -replace '^Tests started from\s+\S+\s+', ''
    if ([string]::IsNullOrWhiteSpace($interactiveLocationSuffix)) {
      $interactiveLocationSuffix = ($Targets -join ', ')
    }
    $interactiveReportTitle = "Test findings for {0} — {1}" -f (($Targets -join ', '), $interactiveLocationSuffix)
    $interactiveReportHtml = Get-HealthInteractiveHtmlReport -Rows $interactiveRows -Title $interactiveReportTitle -FooterHtml $emailSignature.HtmlBottom
    Save-HealthHtmlReport -Path $reportArtifacts.InteractiveReportTempPath -Html $interactiveReportHtml

    $signedHtml = Add-HealthEmailSignature -Body $html -BodyAsHtml -Signature $emailSignature
    Save-HealthHtmlReport -Path $reportArtifacts.LastEmailBodyHtmlPath -Html $signedHtml
    $smtpNotableSubject = Get-HealthNotableSubject -FallbackSubject $subjects.NotableSubject -NotableMessages $notableMessages
    try {
      Invoke-HealthEmail -Subject $smtpNotableSubject -Body $signedHtml -BodyAsHtml -Attachments $reportArtifacts.InteractiveReportTempPath -ConfigFile $smtpConfig -NoSendReport:(-not $sendMailByDefault) -SkipReason $emailDecision.Reason
    }
    finally {
      if (Test-Path -LiteralPath $reportArtifacts.InteractiveReportTempPath -PathType Leaf) {
        Move-HealthReportFile -SourcePath $reportArtifacts.InteractiveReportTempPath -DestinationPath $reportArtifacts.LastInteractiveReportHtmlPath
      }
    }
    return
  }

  Write-Host -for Green "GOOD, Nothing notable to record. I have saved less notable messages here:"
  Write-Host -for Gray "    $allMessagesZipPath"
  $signedBody = Add-HealthEmailSignature -Body (Get-RelaxHtmlBody) -BodyAsHtml -Signature $emailSignature
  Save-HealthHtmlReport -Path $lastReportHtmlPath -Html $signedBody
  Invoke-HealthEmail -Subject $subjects.AllGoodSubject -Body $signedBody -BodyAsHtml -ConfigFile $smtpConfig -NoSendReport:(-not $sendMailByDefault) -SkipReason $emailDecision.Reason
}
