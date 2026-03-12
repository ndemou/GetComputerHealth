<# 
Helper functions that create, return, and optionally display structured Log Objects.

Messages are emitted (Write-Output) as PSCustomObjects with the following properties:
  Computer   : string   # Computer name that generated the message
  Level      : string   # debug, info, pass, notice, warning, failure
  Message    : string   # Primary human-readable message
  Hash       : string   # 8-character message signature (MD5 prefix); empty for debug
  Suppressed : bool     # True if message signature is configured as suppressed
  Comment    : string   # Optional additional information

These objects are suitable for filtering, aggregation, and export (e.g. Excel).

Optionally, messages are also color-printed to the console (Write-Host).

------------------------------------------------------------------------------
INTENDED USAGE
------------------------------------------------------------------------------

This is the primary function that this library provides:

  Log-Msg     -Level "Info" -Msg "Something happened" -Comment <OPTIONAL>

But these convenience wrappers are easier to type:

  Log-Debug   "Diagnostic detail"        -Comment <OPTIONAL>
  Log-Pass    "Successful outcome"       -Comment <OPTIONAL>
  Log-Info    "Informational message"    -Comment <OPTIONAL>
  Log-Notice  "Notable condition"        -Comment <OPTIONAL>
  Log-Warning "Problem detected"         -Comment <OPTIONAL>
  Log-Failure "Serious problem detected" -Comment <OPTIONAL>

Additional utilities:

  Write-BasedOnTestResult
      Convenience function that logs Pass or Failure based on a boolean test.

  Get-StringSignature "Some text"
      Returns the 8-character signature associated with the message text.

  Export-HealthMessagesToExcel $Data $FileName
      Exports Log Objects to Excel (requires ImportExcel module).

------------------------------------------------------------------------------
CONFIGURATION MODEL
------------------------------------------------------------------------------

Default behavior requires no configuration. These are the default values:

  SuppressedSignatures  : @()   # No messages are suppressed
  OutputConsoleMessages : True  # Messages are also printed on the console with nice colors
  HideStr               : ""    # *All* message levels are printed, including debug, info and pass

To change & inspect configuration, call Set-LogConfig & Get-LogConfig. Example:

  Set-LogConfig -HideStr "DIP" -SuppressedSignatures @('12345678','abcd1234')

This hides Debug, Info, and Pass messages from console and whitelists(suppresses) 2 specific messages.

Valid letters for HideStr are these:
    D : Debug
	P : Pass
	I : Info
	N : Notice
	W : Warning
	F : Failure
	C : Comment (messages are printed but without their comments)

------------------------------------------------------------------------------
SUPPRESSION MODEL
------------------------------------------------------------------------------

Each non-debug message has a stable signature derived from its Message text.

If a signature is included in SuppressedSignatures:

  * Message object is still returned but with Suppressed property set to True.
  * Message is not printed on the Console.

Confusion alert: Why we use the terms "suppress a message" and "whitelist a message" as synonymous:
This library was created to support Get-ComputerHealth. That code generates messages to flag 
percieved "issues". If a message describes something that is not really an issue the administrator
whitelists this false alarm thus suppressing the message about it.

------------------------------------------------------------------------------
OUTPUT CONTRACT
------------------------------------------------------------------------------

All Log-* functions ALWAYS emit exactly one PSCustomObject per call.

Consumers SHOULD rely on returned objects, not console output, for automation.

------------------------------------------------------------------------------
EXCEL EXPORT SUPPORT
------------------------------------------------------------------------------

Export-HealthMessagesToExcel exports structured log data and includes a
prebuilt suppression command for each non-suppressed message. This is
specific to the Get-ComputerHealth consumer of this library.

Requires ImportExcel module.

------------------------------------------------------------------------------
#>

#=============================================================
# Default configuration if the caller doesn't call Set-LogConfig
#
#
$script:cfgSuppressedSignatures=@()
$script:cfgOutputConsoleMessages=$true
$script:cfgHideStr=""

#=============================================================
# START OF Low level functions
#
#

# Compute a hex hash of a string (Lowercase hex digest)
function Get-StringHash{
  param([Parameter(Mandatory)][string]$InputString,[ValidateSet('MD5','SHA1','SHA256','SHA384','SHA512')][string]$Algorithm='MD5')
  $bytes=[Text.Encoding]::UTF8.GetBytes($InputString)
  $algo=[Security.Cryptography.HashAlgorithm]::Create($Algorithm)
  try{ -join ($algo.ComputeHash($bytes)|%{ $_.ToString('x2') }) } finally{ if($algo){$algo.Dispose()} }
}

# Return the leftmost N characters.
function Get-LeftString {
  param([Parameter(Mandatory)][string]$String,[Parameter(Mandatory)][int]$Count)
  if($Count -lt 0){ $Count=0 }
  if($Count -gt $String.Length){ $Count = $String.Length }
  $String.Substring(0,$Count)
}
#
#
# END OF Low level functions 
#=============================================================

<#
.SYNOPSIS
Returns a stable 8-character signature for a string after canonicalization.

.DESCRIPTION
Returns a short, deterministic signature derived from the provided text,
intended for message deduplication, suppression, or correlation.
Before hashing, the input text is canonicalized to reduce noise from
cosmetic differences. Two input strings that differ only in case, punctuation,
or spacing will therefore produce the same signature.
#> 
function Get-StringSignature {
  param([Parameter(Mandatory)][string]$InputString)
  $s=$InputString.ToLowerInvariant().Trim()
  $s=$s -replace "[\.,;:!\?\-_/\\\(\)\[\]\{\}']+", ' '
  $s=$s -replace '\s+',' '
  $hash=Get-StringHash -InputString $s -Algorithm MD5
  Get-LeftString -String $hash -Count 8
}

<#
.SYNOPSIS
Normalizes arbitrary input into a distinct list of 8-hex message signatures.

.DESCRIPTION
Accepts strings, arrays, or other enumerable inputs and extracts valid
hexadecimal signature tokens. Non-hex characters (except comma/whitespace)
are discarded. Brackets surrounding signatures are ignored.

Returns lowercase, unique values only.

.NOTES
Invalid tokens are silently ignored.
#>
function ConvertTo-SignatureList {
  [CmdletBinding()]
  param([AllowNull()][object]$InputObject)

  if($null -eq $InputObject){ return @() }

  $items=@()
  if($InputObject -is [string[]]){ $items=@($InputObject) }
  elseif($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])){ $items=@($InputObject) }
  else{ $items=@([string]$InputObject) }

  $flat = ($items | ForEach-Object { [string]$_ }) -join ' '
  $flat = $flat -replace '\[|\]',''
  $flat = $flat -replace '[^0-9A-Fa-f,\s]',' '
  $flat -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique
}

<#
Normalizes the provided input into valid 8-hex signatures and merges them
with the currently configured suppressed signatures. Existing entries are
preserved. Duplicate values are removed.
This affects only in-memory configuration.
#>
function Add-LogSuppressedSignatures {
  [CmdletBinding()]
  param([Parameter(Mandatory)][object]$Signatures)

  $extra = ConvertTo-SignatureList $Signatures
  if(-not $extra){ return }

  $cfg = Get-LogConfig
  $merged = @($cfg.SuppressedSignatures) + @($extra) | Sort-Object -Unique
  Set-LogConfig -SuppressedSignatures $merged
}

<#
.SYNOPSIS
Initializes logging configuration and suppression state.

.DESCRIPTION
Configures console output behavior and visibility filtering, optionally
loads suppressed signatures from a file, and optionally merges additional
suppression entries for the current run.

.PARAMETER OutputConsoleMessages
Controls whether messages are printed to the console.

.PARAMETER HideStr
Console visibility filter (letters from DIPNWFC).

.PARAMETER SuppressionFilePath
Path to a suppression configuration file to load.

.PARAMETER AdditionalSuppressedSignatures
Extra signatures to suppress for this run only.
#>
function Initialize-LogSystem {
  [CmdletBinding()]
  param(
    [bool]$OutputConsoleMessages=$true,
    [string]$HideStr="",
    [string]$SuppressionFilePath,
    [object]$AdditionalSuppressedSignatures
  )

  Set-LogConfig -OutputConsoleMessages $OutputConsoleMessages -HideStr $HideStr

  if($SuppressionFilePath){
    Initialize-SignatureSuppression -Path $SuppressionFilePath
  }

  if($PSBoundParameters.ContainsKey('AdditionalSuppressedSignatures')){
    Add-LogSuppressedSignatures $AdditionalSuppressedSignatures
  }
}

<#
Reads a suppression file containing 8-hex signatures (optionally enclosed
in brackets) with optional expiry dates in the form:
    hash
    hash until yyyy-MM-dd

Expired entries are ignored. If multiple entries exist for the same
signature, the last applicable entry determines its state.

Replaces the current in-memory suppression set.
#>
function Initialize-SignatureSuppression {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path)

  $set = New-Object 'System.Collections.Generic.HashSet[string]'
  if([string]::IsNullOrWhiteSpace($Path)){ return }

  if(-not (Test-Path -LiteralPath $Path)){ return }

  $today = (Get-Date).Date
  $lines = Get-Content -Encoding utf8 -LiteralPath $Path -ErrorAction SilentlyContinue

  foreach($line in $lines){
    if($null -eq $line){ continue }

    $line = ($line -replace '\s+#.*$','').Trim()
    if([string]::IsNullOrWhiteSpace($line)){ continue }

    if($line -match '^\[?([0-9A-Fa-f]{8})\]?(?:\s+until\s+(\d{4}-\d{2}-\d{2}))?$'){
      $hash8 = $Matches[1].ToLowerInvariant()

      if($Matches[2]){
        try{
          $expiry = [datetime]::ParseExact($Matches[2],'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture).Date
        } catch { continue }

        if($today -le $expiry){
          [void]$set.Add($hash8)
        } else {
          [void]$set.Remove($hash8)
        }
      } else {
        [void]$set.Add($hash8)
      }
    }
  }

  Set-LogConfig -SuppressedSignatures @($set)
}

<#
.SYNOPSIS
Updates one or more logging configuration values. Only parameters explicitly supplied are modified.

.PARAMETER SuppressedSignatures
Complete list of 8-hex signatures to treat as suppressed.

.PARAMETER OutputConsoleMessages
Controls whether messages are written to the console.

.PARAMETER HideStr
Console visibility filter (letters from DIPNWFC).
#>
function Set-LogConfig {
  [CmdletBinding()]
  param(
    [string[]]$SuppressedSignatures,
    [bool]$OutputConsoleMessages,
    [string]$HideStr
  )
  if($PSBoundParameters.ContainsKey('SuppressedSignatures')){ $script:cfgSuppressedSignatures=@($SuppressedSignatures) }
  if($PSBoundParameters.ContainsKey('OutputConsoleMessages')){ $script:cfgOutputConsoleMessages=$OutputConsoleMessages }
  if($PSBoundParameters.ContainsKey('HideStr')){ $script:cfgHideStr=[string]$HideStr }
}

<#
.SYNOPSIS
Provides the active in-memory logging settings.

.OUTPUTS
PSCustomObject with:
  SuppressedSignatures
  OutputConsoleMessages
  HideStr
#>
function Get-LogConfig {
  [CmdletBinding()]
  param()
  [pscustomobject]@{
    SuppressedSignatures  = @($script:cfgSuppressedSignatures)
    OutputConsoleMessages = [bool]$script:cfgOutputConsoleMessages
    HideStr               = [string]$script:cfgHideStr
  }
}

function Log-Msg {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ValidateSet('debug','pass','info','notice','warning','failure')][string]$Level,
    [Parameter(Mandatory)][string]$Msg,
    [string]$Comment = ""
  )

  [string]$SigColor = 'DarkGray'
    switch ($Level) {
    'debug' {
      $Hide       = ($script:cfgHideStr -like '*D*') 
      $LabelText  = 'DEBUG  :' 
      $LabelColor = 'DarkGray' 
      $MsgColor   = 'DarkGray'
    }
    'pass' {
      $Hide       = ($script:cfgHideStr -like '*P*') 
      $LabelText  = 'PASS   :' 
      $LabelColor = 'Green' 
      $MsgColor   = 'DarkGray'
    }
    'info' {
      $Hide       = ($script:cfgHideStr -like '*I*') 
      $LabelText  = 'INFO   :' 
      $LabelColor = 'Cyan' 
      $MsgColor   = 'DarkGray'
    }
    'notice' {
      $Hide       = ($script:cfgHideStr -like '*N*') 
      $LabelText  = 'NOTICE :' 
      $LabelColor = 'DarkYellow' 
      $MsgColor   = 'Gray'
    }
    'warning' {
      $Hide       = ($script:cfgHideStr -like '*W*') 
      $LabelText  = 'WARNING:' 
      $LabelColor = 'Yellow' 
      $MsgColor   = 'White'
    }
    'failure' {
      $Hide       = ($script:cfgHideStr -like '*F*') 
      $LabelText  = 'FAILURE:' 
      $LabelColor = 'Red' 
      $MsgColor   = 'White'
    }
  }

  if ($Level -ne 'debug') { $sig = Get-StringSignature $Msg } else { $sig = '' }

  $must_suppress_sig = $false
  if ($script:cfgSuppressedSignatures -and $sig) {
    $must_suppress_sig = $sig -in $script:cfgSuppressedSignatures
  }

  # The name of the HealthTest function that emitted this log object
  # (look up the call stack to find a function named HealthTest-* that called us)
  $logEmitter = $null
  foreach ($frame in (Get-PSCallStack | Select-Object -Skip 1 -First 5)) {
      if ($frame.FunctionName -like 'HealthTest-*') {
          $logEmitter = $frame.FunctionName
          break
      }
  }

  $out = [pscustomobject]@{
    Computer   = $env:COMPUTERNAME
    Level      = $Level
    Hash       = $sig
    Suppressed = $must_suppress_sig
    Message    = $Msg
    Comment    = $Comment
    Emitter    = $logEmitter
  }
  Write-Output $out

  if ((-not $script:cfgOutputConsoleMessages) -or $Hide) { return }

  if ($must_suppress_sig) {
    Write-Host -ForegroundColor Blue -NoNewline '  SUPPRESS :'
    Write-Host -ForegroundColor $SigColor -NoNewline (" [{0}] " -f $sig)
    Write-Host -ForegroundColor $MsgColor $Msg

    if ($Comment -and ($script:cfgHideStr -notlike '*C*')) {
      if ($Comment -match '\n') {
        ($Comment -replace '^(?:\s*\r?\n)+|(?:\s*\r?\n)+$', '') -split '\n' | %{ Write-Host -ForegroundColor DarkGray "  #       $_" }
      } else {
        Write-Host -ForegroundColor DarkGray "  #       $Comment"
      }
    }
    return
  }

  #------------------------------------------------------------------
  # Console output below -- if you edit me put nothing else here
  #
  Write-Host -ForegroundColor $LabelColor -NoNewline ('  {0}' -f $LabelText)
  Write-Host -ForegroundColor $SigColor   -NoNewline (" [{0}] " -f $sig)
  Write-Host -ForegroundColor $MsgColor    $Msg

  if ($Comment -and ($script:cfgHideStr -notlike '*C*')) {
    if ($Comment -match '\n') {
      ($Comment -replace '^(?:\s*\r?\n)+|(?:\s*\r?\n)+$', '') -split '\n' | %{ Write-Host -ForegroundColor DarkGray "  #       $_" }
    } else {
      Write-Host -ForegroundColor DarkGray "  #       $Comment"
    }
  }
}

# Convenience functions (e.g. Log-Debug "..." instead of Log-Msg "Debug" "...")
function Log-Debug   { param([Parameter(Mandatory)][string]$Msg,[string]$Comment="") Log-Msg -Level 'debug'   -Msg $Msg -Comment $Comment }
function Log-Pass    { param([Parameter(Mandatory)][string]$Msg,[string]$Comment="") Log-Msg -Level 'pass'    -Msg $Msg -Comment $Comment }
function Log-Info    { param([Parameter(Mandatory)][string]$Msg,[string]$Comment="") Log-Msg -Level 'info'    -Msg $Msg -Comment $Comment }
function Log-Notice  { param([Parameter(Mandatory)][string]$Msg,[string]$Comment="") Log-Msg -Level 'notice'  -Msg $Msg -Comment $Comment }
function Log-Warning { param([Parameter(Mandatory)][string]$Msg,[string]$Comment="") Log-Msg -Level 'warning' -Msg $Msg -Comment $Comment }
function Log-Failure { param([Parameter(Mandatory)][string]$Msg,[string]$Comment="") Log-Msg -Level 'failure' -Msg $Msg -Comment $Comment }


<#
.SYNOPSIS
 Based on boolean $Test call Log-Pass/Log-Failure and show $Title (if failed $Comment also)
.PARAMETER Title  Description of the test (e.g. "Are windows up to date?")
.PARAMETER Test   $True = PASS
.PARAMETER Comment  Optional info to be shown when Test fails.
#>
function Write-BasedOnTestResult {
  param([Parameter(Mandatory)][string]$Title,[Parameter(Mandatory)][bool]$Test,[string]$Comment="")
  if($Test){ 
    Write-Warning "[pass] $Title"
  } else{
    Write-Warning "[failure] $Title`n$Comment"
  }
}


function Export-HealthMessagesToExcel {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][array]$Data,
    [Parameter(Mandatory)][string]$FileName
  )

  Import-Module ImportExcel -ErrorAction Stop

  # export the requested columns
  $Data |
    Select-Object Computer, Suppressed, Level, Message, Comment, Hash | %{
		$safe_quotes_msg = $_.Message -replace '"',"''"
		if ($_.Suppressed) {
			$command = "" 
		} else {
			$command = "Invoke-Command $($_.Computer) {c:\it\bin\Get-ComputerHealth.ps1 -AddWhitelisting -until 2999-12-31 -sig '$($_.hash)' -ComputerName $($_.Computer) -comment ""$($_.level) - $safe_quotes_msg""}"
		}
		[pscustomobject]@{
			Computer = $_.Computer
			Suppressed = $_.Suppressed
			Level = $_.Level
			Message = $_.Message
			Comment = $_.comment
			Hash = $_.Hash
			CommandToSuppressMsg = $command
		}
	} | Export-Excel -Path $FileName -WorksheetName 'Messages' -AutoSize -BoldTopRow
}
