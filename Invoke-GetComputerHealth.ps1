<#
.SYNOPSIS
Runs Get-ComputerHealth locally and/or via PowerShell remoting across multiple target computers, exports Excel reports, and emails a summary.

.DESCRIPTION
Wraps `C:\IT\bin\Get-ComputerHealth.ps1` to support multiple targets (including an AD-derived "all domain servers" set), then collects all returned health messages into Excel workbooks and optionally emails "notable" (non-suppressed, non-pass/info/debug/help) messages.

Per target:
- Runs `C:\IT\bin\Update-GetHealthCode.ps1` then executes `C:\IT\bin\Get-ComputerHealth.ps1` with `-OutputObjects -OutputConsoleMessages`, plus the provided filters and optional custom tests folder (`C:\IT\config\Custom-HealthTests\`).
- For remote targets, checks basic TCP reachability and if reachable, uses `New-PSSession` to run the tests.

After collection:
- Exports all messages to `C:\IT\temp\all-messages-<timestamp>.xlsx`
- Exports notable messages (if any) to `C:\IT\temp\notable-messages-<timestamp>.xlsx`
- Sends email via `C:\IT\bin\Send-Message.ps1` (with attachment when notable messages exist)

Other effects:
- Installs the PowerShell module `ImportExcel` from PSGallery if missing (may register PSGallery and set it to Trusted; uses `Install-Module`).
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
  - Excel: `C:\IT\temp\all-messages-<timestamp>.xlsx`, `C:\IT\temp\notable-messages-<timestamp>.xlsx`
#>

param(
    [string]$Hide="DIP",
    [string]$WhitelistSigs,
    [string]$OnlyTheseTests, 
    [string]$ExcludeTests,
    [string[]]$ExcludeServers = @(),
    [switch]$DebugSkipSlowTests,
    [switch]$NoSendMessage,
    [string[]]$Computers
)

#------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------
$OutputConsoleMessages = $true
$SmtpSubject = 'Notable Messages from Get-ComputerHealth of LIST_OF_COMPUTERS'
$SmtpSubjectAllGood = 'RELAX. No notable Messages from Get-ComputerHealth of LIST_OF_COMPUTERS'
$SmtpConfig = "C:\IT\config\Send-Message.conf"
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
  & 'C:\IT\bin\Send-Message.ps1' @mailParams
  Write-host -for gray   "email sent."
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

function Ensure-ModuleInstalled {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Name,
    [string]$Scope = 'AllUsers'
  )
  if (Get-Module -ListAvailable -Name $Name) {return}
  try {
    Write-Host "Installing PS Module $Name" -ForegroundColor Yellow
    Install-Module -Name $Name -Scope $Scope -Force -ErrorAction Stop
  } catch {
    if ($_.Exception.Message -like "*No repository with the Name 'PSGallery'*") {
      Write-Host "Registering PSGallery" -ForegroundColor Yellow
      Register-PSRepository -Default -ErrorAction Stop
      Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
      Write-Host "Installing PS Module $Name (previous attempt failed)" -ForegroundColor Yellow
      Install-Module -Name $Name -Scope $Scope -Force -ErrorAction Stop
    } else {
      throw
    }
  }
}

#------------------------------------------------------------------------
# MAIN CODE
#------------------------------------------------------------------------

$timestamp = $(get-date -Format 'yyyy-MM-dd_HH.mm')
Start-Transcript "C:\IT\log\Invoke-GetHealthDomainComputers-$timestamp.log"
. "C:\IT\bin\lib-write-log-objects.ps1"

Ensure-ModuleInstalled ImportExcel

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
    write-verbose "Adding domain servers: $($domain_servers -join ';')"
    $domainServers = (Get-DomainServers | %{$_ -replace '[.].*' -replace '\s'} | ?{$_ -notin $ExcludeServers})
    $targets = ($targets | ?{$_ -ne 'ALL_DOMAIN_SERVERS'}) + $domainServers
}
$targets = ($targets | sort)

write-verbose "Targets: $($targets -join ';')"
$SmtpSubject = $SmtpSubject -replace 'LIST_OF_COMPUTERS', ($targets -join ',')
$SmtpSubjectAllGood = $SmtpSubjectAllGood -replace 'LIST_OF_COMPUTERS', ($targets -join ',')

$all_messages = @()
Write-host "`n`n`n"
foreach ($target in $targets) {
  Write-Progress -Activity "Checking $target" -Status "Phase #1 (copy Get-ComputerHealth.ps1)"
  if ($targets.count -gt 1) {
    Write-host ""
    Write-host -for darkgray "Checking " -nonew
    Write-host -for cyan "$target" -nonew
    Write-host -for darkgray " at $(get-date -Format 'yyyy-MM-dd HH:mm:ss')" 
  }

  # The code to run on the target Computer
  $healthCheckBlock = {
      param(
          $Hide,
          $OnlyTheseTests,
          $ExcludeTests,
          $WhitelistSigs,
          $DebugSkipSlowTests
      )

      if (-not (Test-Path "C:\IT\bin\Update-GetHealthCode.ps1")){
          if (-not (Test-Path "C:\IT\bin")) { New-Item -Path "C:\IT\bin" -ItemType Directory -Force }
          Invoke-WebRequest -useb "https://raw.githubusercontent.com/ndemou/GetComputerHealth/refs/heads/main/Update-GetHealthCode.ps1" -OutFile "C:\IT\bin\Update-GetHealthCode.ps1"
	  }
      & C:\IT\bin\Update-GetHealthCode.ps1
      & C:\IT\bin\Get-ComputerHealth.ps1 `
          -OutputObjects -OutputConsoleMessages `
          -Hide $Hide `
          -OnlyTheseTests $OnlyTheseTests `
          -ExcludeTests $ExcludeTests `
          -IncludeTestsFromFolder C:\IT\config\Custom-HealthTests\ `
          -SuppressSigs $WhitelistSigs `
          -DebugSkipSlowTests:$DebugSkipSlowTests | 
          Select-Object -Property Computer,Level,Hash,Suppressed,Message,Comment,Emitter
  }
  
  if ($target -eq $env:COMPUTERNAME) {
      $output = & $healthCheckBlock $Hide $OnlyTheseTests $ExcludeTests $WhitelistSigs $DebugSkipSlowTests
  } 
  else {
      if (Get-TcpPortStateFast $target @(5985, 5986, 80, 443, 88, 135, 389, 636, 445, 3268, 3269) | ?{$_.open}) {
        Write-Progress -Activity "Checking $target" -Status "Phase #2 (running Get-ComputerHealth.ps1)"
        $session = New-PSSession -ComputerName $target
        $output = Invoke-Command -Session $session -ScriptBlock $healthCheckBlock -ArgumentList $Hide, $OnlyTheseTests, $ExcludeTests, $WhitelistSigs, $DebugSkipSlowTests
        Remove-PSSession $session
      } else {
          if ($target -in $domain_servers) {
              $comment =" (either it is down or you have a stale entry in your AD)"} else {$comment ="(are you sure a computer with that name exists?)"
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
  Export-HealthMessagesToExcel -Data $all_messages -FileName "C:\IT\temp\all-messages-$($timestamp).xlsx"
  $notable_msgs = (`
    $all_messages `
        | Where-Object { -not($_.Suppressed) -and $_.level -notin @('debug','help','pass','info') } `
        | Sort-Object -Property @{ Expression = { $SortOrder[$_.Level] } }, Computer `
  )
  if ($notable_msgs) {
      Export-HealthMessagesToExcel -Data $notable_msgs -FileName "C:\IT\temp\notable-messages-$($timestamp).xlsx" 
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
      Write-host -for yellow "    C:\IT\temp\notable-messages-$($timestamp).xlsx"
      Write-host -for gray   "    C:\IT\temp\all-messages-$($timestamp).xlsx"
      Write-host -for gray   "Open them on Excel or if you prefer PowerShell load them like this:"
      Write-host -for gray   "    `$data = Import-Excel C:\IT\temp\notable-messages-$($timestamp).xlsx"
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

      Invoke-HealthEmail -Subject $SmtpSubject -Body $html -BodyAsHtml -Attachments "C:\IT\temp\notable-messages-$($timestamp).xlsx" -ConfigFile $SmtpConfig -NoSendMessage:$NoSendMessage
  } else {
    Write-host -for green    "GOOD, Nothing notable to record. I have saved less notable messages here:"
    Write-host -for gray     "    C:\IT\temp\all-messages-$($timestamp).xlsx"
    Invoke-HealthEmail -Subject $SmtpSubjectAllGood -Body 'Relax :-)' -ConfigFile $SmtpConfig -NoSendMessage:$NoSendMessage
  }
} else {
}

Stop-Transcript