<#
.SYNOPSIS
  Sends an email alert using SMTP settings stored in a JSON config file.

.DESCRIPTION
  Required parameters:
    -Subject
    -ConfigFile

  Optional parameters:
    -Body
    -Attachments
    -BodyAsHtml
    -GenerateConfig <Path> : Interactively creates a new JSON config file at the specified path.

  Config file (JSON) required keys:
    Server, From, To

  Optional config keys:
    Port   (default: 25)
    UseSsl (default: false)

  Behavior:
  - Supports -WhatIf / -Confirm (ShouldProcess).
  - Validates config and attachment paths before sending.

.NOTES
  - Send-MailMessage is obsolete (shows a warning), but still works in many environments.
  - If UseSsl=true, STARTTLS will be attempted. This can fail if the SMTP certificate is invalid.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low', DefaultParameterSetName = 'Send')]
param(
  [Parameter(Mandatory, ParameterSetName = 'Send')]
  [ValidateNotNullOrEmpty()]
  [string]$Subject,

  [Parameter(Mandatory, ParameterSetName = 'Send')]
  [ValidateNotNullOrEmpty()]
  [string]$ConfigFile,

  [Parameter(Mandatory, ParameterSetName = 'Generate')]
  [string]$GenerateConfig,

  [Parameter(ParameterSetName = 'Send')]
  [string]$Body = "",

  [Parameter(ParameterSetName = 'Send')]
  [string[]]$Attachments,

  [Parameter(ParameterSetName = 'Send')]
  [string[]]$Encoding = "UTF8",

  [Parameter(ParameterSetName = 'Send')]
  [switch]$BodyAsHtml
)

function Send-MailMessageWithRetry {
  param(
    [hashtable]$MailParams,
    [int]$MaxAttempts = 5,
    [int]$BaseDelaySeconds = 2
  )

  $attempt = 0
  $lastErr = $null

  while ($true) {
    $attempt++
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
      Microsoft.PowerShell.Utility\Send-MailMessage @MailParams
      $sw.Stop()
      Write-Verbose "Send-MailMessage succeeded on attempt $attempt in $([int]$sw.Elapsed.TotalMilliseconds) ms."
      return
    } catch {
      $sw.Stop()
      $ex = $_.Exception
      $lastErr = $_

      $msg = $ex.Message
      $inner = if ($ex.InnerException) { $ex.InnerException.Message } else { $null }

      $isTransient = $false

      if ($msg -match '^\s*4\.\d\.\d') { $isTransient = $true }               # 4.x.x SMTP temp
      elseif ($msg -match '4\d{2}\s') { $isTransient = $true }                # "4xx " (some servers)
      elseif ($msg -match 'timeout|timed out|closing transmission channel') { $isTransient = $true }
      elseif ($inner -match 'timeout|timed out|temporar|connection|reset|refused|unreachable') { $isTransient = $true }
      elseif ($ex -is [System.Net.Mail.SmtpException] -and $ex.StatusCode -ne [System.Net.Mail.SmtpStatusCode]::GeneralFailure) {
        if ($ex.StatusCode.ToString() -match 'MailboxBusy|ServiceNotAvailable|TransactionFailed|ClientNotPermitted') { $isTransient = $true }
      }

      Write-Warning ("Send-MailMessage FAILED (attempt $attempt/$MaxAttempts, {0} ms): {1}" -f ([int]$sw.Elapsed.TotalMilliseconds), $msg)
      if ($inner) { Write-Verbose ("InnerException: " + $inner) }

      if (-not $isTransient -or $attempt -ge $MaxAttempts) { throw }

      $delay = [Math]::Min(60, [Math]::Pow(2, ($attempt-1)) * $BaseDelaySeconds)
      $jitter = Get-Random -Minimum 0 -Maximum 1000
      $sleepMs = [int]($delay*1000 + $jitter)
      Write-Verbose "Transient SMTP failure detected; sleeping $sleepMs ms then retrying..."
      Start-Sleep -Milliseconds $sleepMs
    }
  }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Generation Logic ---
if ($PSCmdlet.ParameterSetName -eq 'Generate') {
    $outPath = [System.IO.Path]::GetFullPath($GenerateConfig)
    Write-Host "Answer the following questions to generate the config file." -ForegroundColor Cyan
    
    $genCfg = [ordered]@{
        Server = Read-Host "Enter SMTP Server (e.g., smtp.office365.com)"
        From   = Read-Host "Enter From Address"
        To     = Read-Host "Enter To Address(es) (comma or semi-colon separated)"
        Port   = [int]((Read-Host "Enter Port [25]") -replace '', '25')
        UseSsl = (Read-Host "Use SSL? (y/N)").Trim().ToLower() -eq 'y'
    }

    $genCfg | ConvertTo-Json | Out-File -FilePath $outPath -Encoding "UTF8"
    Write-Host "Successfully created config: $outPath" -ForegroundColor Green
    return
}
function Convert-ToStringArray {
  <#
  .SYNOPSIS
    Normalizes a config field into a string[].

  .DESCRIPTION
    Accepts:
      - JSON array: ["a@x","b@x"]
      - Delimited string: "a@x;b@x" or "a@x, b@x"
      - Single string: "a@x"
  #>
  param(
    [Parameter(Mandatory)]
    $Value
  )

  if ($Value -is [System.Array]) {
    return [string[]]@($Value | ForEach-Object { [string]$_ } | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
  }

  return [string[]]@(
    ([string]$Value -split '[,;]') |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ }
  )
}

function Get-SendAlertConfig {
  <#
  .SYNOPSIS
    Loads and validates the Send-Message JSON configuration.

  .DESCRIPTION
    Ensures required keys exist, applies defaults, and normalizes recipient fields.
  #>
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Config file not found: $Path"
  }

  $raw = Get-Content -LiteralPath $Path -Raw
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "Config file is empty: $Path"
  }

  try {
    $cfg = $raw | ConvertFrom-Json
  } catch {
    throw "Config file is not valid JSON: $Path. Error: $($_.Exception.Message)"
  }

  foreach ($k in @("Server", "From", "To")) {
    if (-not ($cfg.PSObject.Properties.Name -contains $k)) {
      throw "Config is missing required field '$k'. Required: Server, From, To"
    }
    if ([string]::IsNullOrWhiteSpace([string]$cfg.$k)) {
      throw "Config field '$k' is blank."
    }
  }

  $to = Convert-ToStringArray -Value $cfg.To
  if (@($to).Count -lt 1) {
    throw "Config field 'To' produced no recipients after parsing."
  }

  $port = 25
  if ($cfg.PSObject.Properties.Name -contains "Port" -and $cfg.Port) {
    if (-not ($cfg.Port -as [int])) { throw "Config field 'Port' must be an integer (e.g. 25)." }
    $port = [int]$cfg.Port
  }

  $useSsl = $false
  if ($cfg.PSObject.Properties.Name -contains "UseSsl") {
    $useSsl = [bool]$cfg.UseSsl
  }

  [pscustomobject]@{
    Server = [string]$cfg.Server
    From   = [string]$cfg.From
    To     = $to
    Port   = $port
    UseSsl = $useSsl
  }
}

function Resolve-Attachments {
  <#
  .SYNOPSIS
    Validates attachment paths and returns resolved paths.

  .DESCRIPTION
    Expands environment variables and verifies each file exists.
    Output may be empty; callers should wrap invocation in @(...) to avoid $null.
  #>
  param(
    [string[]]$Paths
  )

  $pathsArray = @(
    @($Paths) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )

  foreach ($p in $pathsArray) {
    $expanded = [Environment]::ExpandEnvironmentVariables($p)

    if (-not (Test-Path -LiteralPath $expanded)) {
      throw "Attachment not found: $p"
    }

    try { (Resolve-Path -LiteralPath $expanded).Path }
    catch { $expanded }
  }
}

# --- Load config and inputs ---
$cfg = Get-SendAlertConfig -Path $ConfigFile

# Force array context so empty output becomes @() instead of $null (StrictMode-safe)
$paths = @(Resolve-Attachments -Paths $Attachments)
$attCount = @($paths).Count

$subjectWithTrace = "$Subject"
$finalBody = if ([string]::IsNullOrWhiteSpace($Body)) {
  ""
} else {
  $Body
}

Write-Verbose "Sending Message"
Write-Verbose "  ConfigFile  : $ConfigFile"
Write-Verbose "  SMTP Server : $($cfg.Server)"
Write-Verbose "  Port        : $($cfg.Port)"
Write-Verbose "  UseSsl      : $($cfg.UseSsl)"
Write-Verbose "  From        : $($cfg.From)"
Write-Verbose "  To          : $($cfg.To -join '; ')"
Write-Verbose "  Subject     : $subjectWithTrace"
Write-Verbose "  BodyAsHtml  : $($BodyAsHtml.IsPresent)"
Write-Verbose ("  Attachments : " + ($(if ($attCount -gt 0) { $paths -join '; ' } else { '<none>' })))

# --- Build Send-MailMessage parameters ---
$mailParams = @{
  SmtpServer  = $cfg.Server
  Port        = $cfg.Port
  From        = $cfg.From
  To          = $cfg.To
  Subject     = $subjectWithTrace
  Encoding    = $Encoding
  ErrorAction = "Stop"
}
if ([string]::IsNullOrWhiteSpace($finalBody)) {
  $mailParams.Body = $subjectWithTrace
} else {
  $mailParams.Body = $finalBody
}

if ($BodyAsHtml) { $mailParams.BodyAsHtml = $true }
if ($attCount -gt 0) { $mailParams.Attachments = $paths }
if ($cfg.UseSsl) { $mailParams.UseSsl = $true }

# --- Send (supports -WhatIf / -Confirm) ---
$target = "$($cfg.Server):$($cfg.Port) -> $($cfg.To -join ', ')"
$action = "Send email '$subjectWithTrace'"

if ($PSCmdlet.ShouldProcess($target, $action)) {
  try {
    Send-MailMessageWithRetry -MailParams $mailParams -MaxAttempts 5 -BaseDelaySeconds 2
    Write-Verbose "Mail send completed."
  } catch {
    throw
  }
}
