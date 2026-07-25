# HostRequirement: All

function HealthTest-EventLogMaxSizes{
<#
Description: Checks whether key Windows event logs meet the configured minimum size baseline.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Tags: Essential
Uses: Get-WinEvent.
#>
  [CmdletBinding()]
  param([hashtable]$OverrideMinSizesMB)

  if ($RunWithoutElevation) {
    Write-Warning "[WARNING] this test requires elevation"
    return
  }

  $role = (Get-CimInstance Win32_ComputerSystem).DomainRole
  $MinSizesMB = switch ($role) {
    0 { @{Security=20; System=20;  Application=20} }     # Workstation, non-domain
    1 { @{Security=20; System=20;  Application=20} }     # Workstation, domain-joined
    2 { @{Security=512; System=256; Application=256} }    # Server, non-domain
    3 { @{Security=512; System=256; Application=256} }    # Server, domain-joined
    4 { @{Security=1024;System=256; Application=256} }    # DC (non-FSMO)
    5 { @{Security=1024;System=256; Application=256} }    # DC (PDC Emulator)
    Default { @{Security=512; System=256; Application=256} }
  }
  if ($OverrideMinSizesMB) {
    foreach($k in $OverrideMinSizesMB.Keys){ $MinSizesMB[$k] = [int]$OverrideMinSizesMB[$k] }
  }

  $bad=$false
  foreach($name in $MinSizesMB.Keys){
    $sz=[int64]0
    try{
      $log=Get-WinEvent -ListLog $name -ErrorAction Stop
      $sz=[int64]$log.MaximumSizeInBytes
    }catch{
      $out=& wevtutil gl $name 2>&1
      $line=($out | Select-String -Pattern 'maximum size:' -SimpleMatch | Select-Object -First 1).Line
      if($line -and ($line -match 'maximum size:\s*(\d+)')){ $sz=[int64]$Matches[1] }
    }
    if(-not $sz){ Write-Warning "[WARNING] $name log size could not be determined"; $bad=$true; continue }

    $minMB=[int]$MinSizesMB[$name]
    $minBytes=[int64]$minMB*1MB
    if($sz -lt $minBytes){
      $bad=$true
      $currentMB=[math]::Round($sz/1MB)
      $comment="Fix: Run  wevtutil sl $name /ms:$minBytes"
      Write-Warning "[FAILURE] $name log maximum size too small: ${currentMB}MB < ${minMB}MB`n$comment"
    }
  }

  if(-not $bad){ Write-Warning "[PASS] Event log maximum sizes meet or exceed baseline"}
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-EventLogMaxSizes
}
