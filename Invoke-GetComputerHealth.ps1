<#
.SYNOPSIS
Updates and then runs Get-ComputerHealth locally and/or via PowerShell remoting across multiple target computers, exports Excel reports, and emails a summary.

.DESCRIPTION
Wraps `C:\IT\bin\Get-ComputerHealth.ps1` to support multiple targets (including an AD-derived "all domain servers" set), then collects all returned health messages into Excel workbooks and optionally emails "notable" (non-suppressed, non-pass/info/debug/help) messages.

Per target:
- Runs `C:\IT\bin\Update-GetHealthCode.ps1` then executes `C:\IT\bin\Get-ComputerHealth.ps1` with `-OutputObjects -OutputConsoleMessages`, plus the provided filters and optional custom tests folder (`C:\IT\config\Custom-HealthTests\`).
- For remote targets, checks basic TCP reachability and if reachable, uses `New-PSSession` to run the tests.

After collection:
- Exports all messages to `${TEMP_DIR}\all-messages-<timestamp>.xlsx`
- Exports notable messages (if any) to `${TEMP_DIR}\notable-messages-<timestamp>.xlsx`
- Sends email via `C:\IT\bin\Send-Message.ps1` (with attachment when notable messages exist)

Other effects:
- Requires the PowerShell module `ImportExcel` to be already installed (typically by `Update-GetHealthCode.ps1`).
- Starts a transcript at `C:\IT\log\Invoke-GetHealthDomainComputers-<timestamp>.log`.
- Sends email and may attach the notable-messages workbook.

Dependencies & execution context:
- Requires `C:\IT\bin\lib-write-log-objects.ps1` (dot-sourced) for logging/Excel export helper(s).
- Requires these local scripts to exist and be runnable (locally and on remotes):
  - `C:\IT\bin\Update-GetHealthCode.ps1`
  - `C:\IT\bin\Get-ComputerHealth.ps1`
  - `C:\IT\bin\Send-Message.ps1` and `C:\IT\config\Send-Message.conf`
- Remote execution requires WinRM / PowerShell remoting connectivity and permissions sufficient to create sessions and run the above scripts remotely.

.PARAMETER Computers
Optional list of target hostnames. If omitted, defaults to the local computer.
Accepts whitespace/comma-separated input (e.g. `"srv1,srv2"` or `"srv1 srv2"`).
Special token `ALL_DOMAIN_SERVERS` expands to all AD computer objects with `operatingSystem=*Server*` (optionally excluding some via `-ExcludeServers`).

.PARAMETER IpsOfAllDcs
Array of IPv4 addresses for all domain controllers. Passed through to `Get-ComputerHealth.ps1` as `-IpsOfAllDcs`.

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
Skips execution of `C:\IT\bin\Update-GetHealthCode.ps1` before running `Get-ComputerHealth.ps1` on each target.

.PARAMETER PushUpdate
When targeting remote computers, copies the latest locally cached release zip from `${TEMP_DIR}` to each target and runs `Update-GetHealthCode.ps1 -UpdateFromZip <copied-zip>` before tests.

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
- Remote targets are executed via PowerShell remoting sessions; ensure WinRM is enabled and reachable (5985/5986) and that `C:\IT\bin\` and `C:\IT\config\` content exists on the remote machines as referenced.
- Output paths used:
  - Transcript: `C:\IT\log\Invoke-GetHealthDomainComputers-<timestamp>.log`
  - Excel: `${TEMP_DIR}\all-messages-<timestamp>.xlsx`, `${TEMP_DIR}\notable-messages-<timestamp>.xlsx`
#>

param(
    [string]$Hide="DIP",
    [string]$WhitelistSigs,
    [string]$OnlyTheseTests,
    [string]$ExcludeTests,
    [string[]]$ExcludeServers = @(),
    [switch]$DebugSkipSlowTests,
    [switch]$NoUpdate,
    [switch]$PushUpdate,
    [switch]$NoSendMessage,
    [string[]]$IpsOfAllDcs = @(),
    [string[]]$Computers
)

#------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------

$SCRIPT_BIN_DIR = (Resolve-Path -LiteralPath $PSScriptRoot).Path
if ((Split-Path -Leaf $SCRIPT_BIN_DIR) -ine 'bin') {
  throw "Refusing to run. Invoke-GetComputerHealth.ps1 must be located in and executed from a 'bin' folder. Current script location: '$SCRIPT_BIN_DIR'."
}
$ROOT_DIR = Split-Path -Parent $SCRIPT_BIN_DIR
$CONFIG_DIR = Join-Path $ROOT_DIR 'config'
$TEMP_DIR = Join-Path $ROOT_DIR 'temp'
$LOG_DIR = Join-Path $ROOT_DIR 'log'
$UPDATE_SCRIPT_PATH = Join-Path $SCRIPT_BIN_DIR 'Update-GetHealthCode.ps1'
$GET_HEALTH_SCRIPT_PATH = Join-Path $SCRIPT_BIN_DIR 'Get-ComputerHealth.ps1'
$SEND_MESSAGE_SCRIPT_PATH = Join-Path $SCRIPT_BIN_DIR 'Send-Message.ps1'
$LIB_LOG_OBJECTS_PATH = Join-Path $SCRIPT_BIN_DIR 'lib-write-log-objects.ps1'
$CUSTOM_TESTS_DIR = Join-Path $CONFIG_DIR 'Custom-HealthTests'

$OutputConsoleMessages = $true
$SmtpSubject = 'Notable Messages from Get-ComputerHealth of LIST_OF_COMPUTERS'
$SmtpSubjectAllGood = 'RELAX. No notable Messages from Get-ComputerHealth of LIST_OF_COMPUTERS'
$SmtpConfig = Join-Path $CONFIG_DIR 'Send-Message.conf'
#------------------------------------------------------------------------
# Functions
#------------------------------------------------------------------------

function Invoke-HealthEmail {
# Send the final report via email (except if -NoSendMessage is passed)
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Subject,
    [Parameter(Mandatory)][string]$ConfigFile,
    [Parameter(Mandatory)][string]$Body,
    [switch]$BodyAsHtml,
    [string[]]$Attachments,
    [switch]$NoSendMessage
  )

  if ($NoSendMessage) { return }

  if (-not (Test-Path $ConfigFile)) {
    Write-Host -for Yellow "Will not email results because send-message.ps1 is not configured. If you want to configure it run ``Send-Message.ps1 -GenerateConfig '$ConfigFile'``."
    return
  }
  $mailParams = @{
    Subject    = $Subject
    Body       = $Body
    ConfigFile = $ConfigFile
  }
  if ($BodyAsHtml) { $mailParams['BodyAsHtml'] = $true }
  if ($Attachments -and $Attachments.Count) { $mailParams['Attachments'] = $Attachments }
  Write-host -for gray   "Sending email... " -NoNewLine
  try {
    & $SEND_MESSAGE_SCRIPT_PATH @mailParams
    Write-host -for gray   "email sent."
  } catch {
    Write-host -for yellow "email failed."
    throw
  }
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
    } catch {
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
  } catch {
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
    $ds.ClientTimeout   = [TimeSpan]::FromSeconds(30)
    $ds.ReferralChasing = [System.DirectoryServices.ReferralChasingOption]::All
    [void]$ds.PropertiesToLoad.AddRange(@('dNSHostName','name','operatingSystem','userAccountControl','primaryGroupID'))

    $dcExclusion = if ($ExcludeDomainControllers) { '(!(primaryGroupID=516))(!(userAccountControl:1.2.840.113556.1.4.803:=8192))' } else { '' }
    $ds.Filter = "(&(objectCategory=computer)(operatingSystem=*Server*)$dcExclusion)"

    foreach ($r in $ds.FindAll()) {
      $dns  = $r.Properties['dnshostname']
      $name = $r.Properties['name']
      if ($dns -and $dns[0]) { [void]$results.Add($dns[0]) }
      elseif ($name -and $name[0]) { [void]$results.Add($name[0]) }
    }
  } catch {
    Write-Warning ("Get-DomainServers failed against {0}: {1}" -f $Server, $_.Exception.Message)
    Write-Warning "Tips: verify DNS for $Domain, connectivity to $Server, time sync, and firewall for 389/636 (LDAP/LDAPS) and 3268/3269 (GC)."
    return
  }

  $results
}

function Get-TcpPortStateFast ($hostname,$ports,$timeout=100) {
    $tcpobj = @{}; $open = @{}; $requestCallback = $state = $null;
    foreach ($port in $ports) {
        $tcpobj[$port] = New-Object System.Net.Sockets.TcpClient; $foo = $tcpobj[$port].BeginConnect($hostname,$port,$requestCallback,$state)
        }
        Start-Sleep -milli $timeOut;
        foreach ($port in $ports) {
            $open=($tcpobj[$port].Connected); $tcpobj[$port].Close(); [pscustomobject]@{port=$port;open=$open}
        }
}

function Get-LatestLocalReleaseZip {
  [CmdletBinding()]
  param(
    [string]$CacheDir = $TEMP_DIR,
    [string]$ConfigDir = $CONFIG_DIR,
    [string[]]$Patterns = @('GetComputerHealth-release-*.zip','GetComputerHealth-MANUAL-UPDATE-*.zip')
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
      } catch {
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
  } catch {
    return $null
  }
}

#------------------------------------------------------------------------
# MAIN CODE
#------------------------------------------------------------------------

$timestamp = $(get-date -Format 'yyyy-MM-dd_HH.mm')
if (-not (Test-Path -LiteralPath $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null }
Start-Transcript (Join-Path $LOG_DIR "Invoke-GetHealthDomainComputers-$timestamp.log")
. $LIB_LOG_OBJECTS_PATH

if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    throw "Required module 'ImportExcel' is missing. Run C:\IT\bin\Update-GetHealthCode.ps1 to install prerequisites."
}

if ($ExcludeServers) {
    $ExcludeServers = $ExcludeServers | %{ $_ -split '[,\s]+' } | ?{ $_ }
    write-verbose "`$ExcludeServers: $($ExcludeServers -join ';')"
}

if (-not $Computers) {
    $targets = $env:COMPUTERNAME
} else {
    $targets = $Computers | %{ $_ -split '[,\s]+' } | %{$_ -replace '\s'} | ?{ $_}
}
if ('ALL_DOMAIN_SERVERS' -in $targets) {
    write-verbose "Adding domain servers"
    $domainServers = (Get-DomainServers | %{$_ -replace '[.].*' -replace '\s'} | ?{$_ -notin $ExcludeServers})
    $targets = ($targets | ?{$_ -ne 'ALL_DOMAIN_SERVERS'}) + $domainServers
}
$targets = ($targets | sort)

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
          $DebugSkipSlowTests,
          $NoUpdate,
          $IpsOfAllDcs,
          $PushUpdate,
          $UpdateZipPath
      )

      $binDir = Join-Path $RootDir 'bin'
      $configDir = Join-Path $RootDir 'config'
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
              } else {
                  & $updateScriptPath 2>&1
              }

              foreach ($item in @($updateOutput)) {
                  if ($item -is [System.Management.Automation.ErrorRecord]) {
                      $comment = ($item | Out-String).Trim()
                      $records.Add((Log-Failure "PowerShell error while running Update-GetHealthCode.ps1" -Comment $comment)) | Out-Null
                  }
              }
          } catch {
              $records.Add((Log-Failure "Terminating error while running Update-GetHealthCode.ps1" -Comment (($_ | Out-String).Trim()))) | Out-Null
              return $records
          }
      }

      try {
          $healthOutput = & $getHealthScriptPath `
              -OutputObjects -OutputConsoleMessages `
              -Hide $Hide `
              -OnlyTheseTests $OnlyTheseTests `
              -ExcludeTests $ExcludeTests `
              -IncludeTestsFromFolder $customTestsDir `
              -SuppressSigs $WhitelistSigs `
              -DebugSkipSlowTests:$DebugSkipSlowTests `
              -IpsOfAllDcs $IpsOfAllDcs 2>&1

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
      } catch {
          $records.Add((Log-Failure "Terminating error while running Get-ComputerHealth.ps1" -Comment (($_ | Out-String).Trim()))) | Out-Null
      }

      return $records
  }

  if ($target -eq $env:COMPUTERNAME) {
      $output = & $healthCheckBlock $ROOT_DIR $Hide $OnlyTheseTests $ExcludeTests $WhitelistSigs $DebugSkipSlowTests $NoUpdate $IpsOfAllDcs $PushUpdate $localReleaseZip
  }
  else {
      if (Get-TcpPortStateFast $target @(5985, 5986, 80, 443, 88, 135, 389, 636, 445, 3268, 3269) | Where-Object { $_.Open }) {
        Write-Progress -Activity "Checking $target" -Status "Phase #2 (copying updater and running Get-ComputerHealth.ps1)"

        $session = $null
        try {
          $session = New-PSSession -ComputerName $target

          Invoke-Command -Session $session -ScriptBlock {
            param($RootDir)
            $remoteBinDir = Join-Path $RootDir 'bin'
            $remoteTempDir = Join-Path $RootDir 'temp'
            if (-not (Test-Path $remoteBinDir))  { New-Item -Path $remoteBinDir  -ItemType Directory -Force | Out-Null }
            if (-not (Test-Path $remoteTempDir)) { New-Item -Path $remoteTempDir -ItemType Directory -Force | Out-Null }
          } -ArgumentList $ROOT_DIR

          $localUpdaterPath  = $UPDATE_SCRIPT_PATH
          $remoteUpdaterPath = Join-Path (Join-Path $ROOT_DIR 'bin') 'Update-GetHealthCode.ps1'

          if (-not (Test-Path -LiteralPath $localUpdaterPath)) {
            throw "Local updater file not found: $localUpdaterPath"
          }

          Copy-Item -Path $localUpdaterPath -Destination $remoteUpdaterPath -ToSession $session -Force

          $remoteZipPath = $null
          if ($PushUpdate -and $localReleaseZip) {
            $remoteZipPath = Join-Path (Join-Path $ROOT_DIR 'temp') (Split-Path -Path $localReleaseZip -Leaf)
            Copy-Item -Path $localReleaseZip -Destination $remoteZipPath -ToSession $session -Force
          }

          $output = Invoke-Command -Session $session -ScriptBlock $healthCheckBlock -ArgumentList $ROOT_DIR, $Hide, $OnlyTheseTests, $ExcludeTests, $WhitelistSigs, $DebugSkipSlowTests, $NoUpdate, $IpsOfAllDcs, $PushUpdate, $remoteZipPath
        } catch {
          $_ = Log-failure "Failed running update/health scripts on target $target"
          $all_messages += [pscustomobject]@{
              Computer   = $target
              Level      = 'failure'
              Hash       = '00000000'
              Suppressed = $false
              Message    = "Failed running update/health scripts"
              Comment    = (($_ | Out-String).Trim())
              Emitter    = $null
          }
          continue
        }
        finally {
          if ($session) { Remove-PSSession $session }
        }
      } else {
          if ($target -in $domainServers) {
              $comment = " (either it is down or you have a stale entry in your AD)"
          } else {
              $comment = " (are you sure a computer with that name exists?)"
          }
          $_ = Log-failure "Target $target is unreachable $comment"
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

$SortOrder = @{'failure' = 1; 'warning' = 2; 'notice' = 3; 'info'=4; 'pass'=5; 'debug'=6}
$notable_msgs = @()
if ($all_messages){
  # save
  Export-HealthMessagesToExcel -Data $all_messages -FileName "${TEMP_DIR}\all-messages-$($timestamp).xlsx"
  $notable_msgs = (`
    $all_messages `
        | Where-Object { -not($_.Suppressed) -and $_.level -notin @('debug','help','pass','info') } `
        | Sort-Object -Property @{ Expression = { $SortOrder[$_.Level] } }, Computer `
  )
  if ($notable_msgs) {
      Export-HealthMessagesToExcel -Data $notable_msgs -FileName "${TEMP_DIR}\notable-messages-$($timestamp).xlsx"
  }

  $synopsis = " " +($notable_msgs | Where-Object {$_.Level} |
    Group-Object Level -NoElement |
    Sort-Object -Property @{ Expression = { $SortOrder[$_.Name] } } | %{
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
      Write-host -for gray   "Emailing notable messages"

      $body = ""
      if ($notable_msgs.count -gt 10) {
          # too many messages; add a synopsis at the top
          $body += "Synopsis of messages per level`r`n" + $synopsis + "`r`n"
      }
      $body += `
          ($notable_msgs |
              Sort-Object -Property @{ Expression = { $SortOrder[$_.Level] } }, Computer |
              ForEach-Object {
                  "$($_.Computer.PadRight(15)) $($_.Level.PadRight(8)) $($_.Message)"
              } | Out-String `
          )

      $encoded = [System.Net.WebUtility]::HtmlEncode($body)
      $html = "<pre style='font-family: Consolas, ""Courier New"", monospace; white-space:pre-wrap; margin:0; font-size:12px; line-height:1.35'>$encoded</pre>"

      Invoke-HealthEmail -Subject $SmtpSubject -Body $html -BodyAsHtml -Attachments "${TEMP_DIR}\notable-messages-$($timestamp).xlsx" -ConfigFile $SmtpConfig -NoSendMessage:$NoSendMessage
  } else {
    Write-host -for green    "GOOD, Nothing notable to record. I have saved less notable messages here:"
    Write-host -for gray     "    ${TEMP_DIR}\all-messages-$($timestamp).xlsx"
    Invoke-HealthEmail -Subject $SmtpSubjectAllGood -Body 'Relax :-)' -ConfigFile $SmtpConfig -NoSendMessage:$NoSendMessage
  }
} else {
}

Stop-Transcript
