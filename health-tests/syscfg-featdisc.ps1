<#
System Configuration & Feature Discovery
#>

function HealthTest-MalwareProtectionFeatures {
<#
Description: Checks Microsoft Defender malware protection status and signature freshness.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Tags: Essential
Uses: Get-MpComputerStatus.

Checks the Microsoft Defender malware protection subsystem. It collects the
Get-MpComputerStatus state and verifies that signatures are current, the anti-malware
service is enabled and running in Normal mode, and the main protection layers are
enabled: real-time protection, on-access scanning, Network Inspection System, IOAV,
behavior monitoring, antivirus, and antispyware. It detects stale signatures and
disabled or degraded Defender features that reduce malware protection coverage.
#>
    # $MPs holds the Malware Protection status
    $MPs=(Get-MpComputerStatus)
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).DefenderSignaturesOutOfDate not true?" -Test (!$MPs.DefenderSignaturesOutOfDate) -Comment "You may run`n  Update-MpSignature`n  to update."
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).AMServiceEnabled true?"                -Test $MPs.AMServiceEnabled
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).AMRunningMode Normal?"                 -Test ($MPs.AMRunningMode -eq 'Normal')
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).RealTimeProtectionEnabled true?"       -Test $MPs.RealTimeProtectionEnabled
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).OnAccessProtectionEnabled true?"       -Test $MPs.OnAccessProtectionEnabled
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).NISEnabled true?"                      -Test $MPs.NISEnabled
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).IoavProtectionEnabled true?"           -Test $MPs.IoavProtectionEnabled
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).BehaviorMonitorEnabled true?"          -Test $MPs.BehaviorMonitorEnabled
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).AntivirusEnabled true?"                -Test $MPs.AntivirusEnabled
    Write-BasedOnTestResult "Is (Get-MpComputerStatus).AntispywareEnabled true?"              -Test $MPs.AntispywareEnabled
}

# TODO this test is repeated in HealthTest-ShareReasonableness




function Get-PolicyListShortHash {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Text)

  $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
  $algorithm = [Security.Cryptography.HashAlgorithm]::Create('SHA256')
  try {
    $hash = -join ($algorithm.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    return $hash.Substring(0, 16)
  } finally {
    if ($algorithm) { $algorithm.Dispose() }
  }
}

function Normalize-PolicyListText {
  [CmdletBinding()]
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) { return '' }
  return (([string]$Value).Trim() -replace '\s+', ' ').ToLowerInvariant()
}

function HealthTest-ListStartupItems{
<#
Description: Lists startup items found in standard registry and startup-folder locations.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Tags: Policy
Uses: None.

Policy identity: source type and location, item name, and normalized command/path text. Volatile file timestamps and runtime state are not included.
Policy baseline version: 1
#>
  $registryPaths=@(
    @{ Scope = 'Machine'; Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' },
    @{ Scope = 'Machine'; Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce' },
    @{ Scope = 'User'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' },
    @{ Scope = 'User'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' }
  )

  $seen = 0
  foreach($entry in $registryPaths){
    $p = $entry.Path
    if(Test-Path $p){
      $props=Get-ItemProperty -Path $p
      foreach ($prop in $props.PSObject.Properties) {
        if ($prop.Name -in @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider')) { continue }
        $name = [string]$prop.Name
        $command = [string]$prop.Value
        $identityText = 'type=registry|scope=' + (Normalize-PolicyListText $entry.Scope) + '|location=' + (Normalize-PolicyListText $p) + '|name=' + (Normalize-PolicyListText $name) + '|command=' + (Normalize-PolicyListText $command)
        $policyId = Get-PolicyListShortHash -Text $identityText
        $seen += 1
        Write-Warning "[NOTICE] Found startup item: $name fingerprint=$policyId`nSource: Registry $p`nCommand: $command`nIdentity: $identityText"
      }
    }
  }

  $startupFolders = @()
  try {
    $startupFolders += [pscustomobject]@{ Scope = 'Machine'; Path = [Environment]::GetFolderPath('CommonStartup') }
  } catch {}
  try {
    $startupFolders += [pscustomobject]@{ Scope = 'User'; Path = [Environment]::GetFolderPath('Startup') }
  } catch {}

  foreach ($folder in $startupFolders) {
    if ([string]::IsNullOrWhiteSpace($folder.Path)) { continue }
    if (-not (Test-Path -LiteralPath $folder.Path -PathType Container)) { continue }

    $files = @(Get-ChildItem -LiteralPath $folder.Path -File -ErrorAction SilentlyContinue)
    foreach ($file in $files) {
      $identityText = 'type=file|scope=' + (Normalize-PolicyListText $folder.Scope) + '|location=' + (Normalize-PolicyListText $folder.Path) + '|name=' + (Normalize-PolicyListText $file.Name)
      $policyId = Get-PolicyListShortHash -Text $identityText
      $seen += 1
      Write-Warning "[NOTICE] Found startup item: $($file.Name) fingerprint=$policyId`nSource: Startup folder $($folder.Path)`nPath: $($file.FullName)`nIdentity: $identityText"
    }
  }

  if($seen -eq 0){
    Write-Warning "[PASS] No startup items found in standard locations"
  }
}
