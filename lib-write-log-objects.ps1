<# 
Helper functions that return AND display Log Objects.
Messages are returned (write-output) as CustomPSObjects like this:
  Host       : "PC01"
  Level      : "warning"     # (debug, info, pass, notice, warning, failure)
  Message    : "Computer and user policy updates failed to complet (gpupdate)"
  Hash       : "61811b52"
  Suppressed : $true      
  Comment    : "gpupdate execution failed with error 3"

They are also optionally color-printed on screen (Write-Host).

Use it to output log messages (debug,info,pass,notice,warning & failure).
You can also export such messages to Excel.

Functions you are supposed to use:
   * Log-Msg     -Level "Info" -Msg "Something happened" -Comment <OPTIONAL>
   * Log-Debug   "Something happened under the hood" -Comment <OPTIONAL>
   * Log-Pass    "Something good happened" -Comment <OPTIONAL>
   * Log-Info    "Something happened" -Comment <OPTIONAL>
   * Log-Notice  "Something noticable happened" -Comment <OPTIONAL>
   * Log-Warning "Something bad happened" -Comment <OPTIONAL>
   * Log-Failure "Something very bad happened" -Comment <OPTIONAL>
Also (less often):
   * Write-BasedOnTestResult  -Title $TestTitle -Test $TestResultTrueFalse -Comment "Comment if test failed"
        (convenience function to avoid a lot of if($test){log-pass "..."}else{log-failure "..."}
   * Get-StringSignature "Some text" 
        (returns the signature/hash of the string you pass)
   * Export-HealthMessagesToExcel $Data $FileName 
        ($Data is an array of Log Objects. Needs module ImportExcel)

Configure behavior by setting these global variables:

  $global:WLO_SuppressedSignatures  
    An array of signatures that will not be printed in the console 
    (and will have their .suppressed property set to $true).

  $global:WLO_OutputConsoleMessages 
    True if you want these functions to also show collored messages 
    to the console (write-host).

  $global:WLO_HideStr
    A string with characters that denote which type of messages to NOT show
    on the console. e.g. "DIP" will hide Debug, Info & Pass messages.
    Valid chars: D,I,P,N,W,F.

***********
* CAUTION *
***********
You must set the $Global: variables before calling the functions.

EXAMPLE GLOBAL VARIABLES INITIALIZATION
---------------------------------------
    $global:WLO_SuppressedSignatures = @()    # Don't suppress any message.
    $global:WLO_OutputConsoleMessages = $True # Show nice colored output on the console.
    $global:WLO_HideStr = "DIP"               # Hide Debug, Info & Pass messages.
#>

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

# Get an 8-char signature for a string (MD5 prefix) 
function Get-StringSignature {
  param([Parameter(Mandatory)][string]$InputString)
  $hash = Get-StringHash -InputString $InputString -Algorithm MD5
  Get-LeftString -String $hash -Count 8
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
      $Hide       = ($global:WLO_HideStr -like '*D*') 
      $LabelText  = 'DEBUG  :' 
      $LabelColor = 'DarkGray' 
      $MsgColor   = 'DarkGray'
    }
    'pass' {
      $Hide       = ($global:WLO_HideStr -like '*P*') 
      $LabelText  = 'PASS   :' 
      $LabelColor = 'Green' 
      $MsgColor   = 'DarkGray'
    }
    'info' {
      $Hide       = ($global:WLO_HideStr -like '*I*') 
      $LabelText  = 'INFO   :' 
      $LabelColor = 'Cyan' 
      $MsgColor   = 'DarkGray'
    }
    'notice' {
      $Hide       = ($global:WLO_HideStr -like '*N*') 
      $LabelText  = 'NOTICE :' 
      $LabelColor = 'DarkYellow' 
      $MsgColor   = 'Gray'
    }
    'warning' {
      $Hide       = ($global:WLO_HideStr -like '*W*') 
      $LabelText  = 'WARNING:' 
      $LabelColor = 'Yellow' 
      $MsgColor   = 'White'
    }
    'failure' {
      $Hide       = ($global:WLO_HideStr -like '*F*') 
      $LabelText  = 'FAILURE:' 
      $LabelColor = 'Red' 
      $MsgColor   = 'White'
    }
  }

  if ($Level -ne 'debug') { $sig = Get-StringSignature $Msg } else { $sig = '' }

  $must_suppress_sig = $false
  if ($global:WLO_SuppressedSignatures -and $sig) {
    $must_suppress_sig = $sig -in $global:WLO_SuppressedSignatures
  }

  $out = [pscustomobject]@{
    Host       = $env:COMPUTERNAME
    Level      = $Level
    Hash       = $sig
    Suppressed = $must_suppress_sig
    Message    = $Msg
    Comment    = $Comment
  }
  Write-Output $out

  if ((-not $OutputConsoleMessages) -or $Hide -or $must_suppress_sig) { return }
  #------------------------------------------------------------------
  # Console output below -- if you edit me put nothing else here
  #
  Write-Host -ForegroundColor $LabelColor -NoNewline ('  {0}' -f $LabelText)
  Write-Host -ForegroundColor $SigColor   -NoNewline (" [{0}] " -f $sig)
  Write-Host -ForegroundColor $MsgColor    $Msg

  if ($Comment -and ($global:WLO_HideStr -notlike '*C*')) {
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
    Log-Pass $Title 
  } else{
    Log-failure $Title -Comment $Comment
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
    Select-Object Host, Suppressed, Level, Message, Comment, Hash | %{
		$safe_quotes_msg = $_.Message -replace '"',"''"
		if ($_.Suppressed) {
			$command = "" 
		} else {
			$command = "Invoke-Command $($_.host) {c:\it\bin\Get-ComputerHealth.ps1 -AddWhitelisting -until 2999-12-31 -sig '$($_.hash)' -ComputerName $($_.Host) -comment ""$($_.level) - $safe_quotes_msg""}"
		}
		[pscustomobject]@{
			Host = $_.Host
			Suppressed = $_.Suppressed
			Level = $_.Level
			Message = $_.Message
			Comment = $_.comment
			Hash = $_.Hash
			CommandToSuppressMsg = $command
		}
	} | Export-Excel -Path $FileName -WorksheetName 'Messages' -AutoSize -BoldTopRow
}
