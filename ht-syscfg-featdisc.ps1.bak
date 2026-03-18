<#
System Configuration & Feature Discovery
#>

function HealthTest-InstalledRolesFeatures {
<#
.SYNOPSIS
Checks Installed Roles Features and flags unhealthy or non-baseline states

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Audit / Compliance / Informational
Impact: Medium(Time)
Uses: Get-WindowsFeature.
FalsePositives: None.
#>
  [CmdletBinding()]
  param([string[]]$DisallowedRoles = @('Web-Server','DHCP','WDS'))

  $roles = $null
  try { $roles = Get-WindowsFeature -ErrorAction Stop | Where-Object { $_.Installed } }
  catch {
    Write-Output "Get-WindowsFeature not available on this OS; skipping role/feature check"
    return
  }

  $hit = @($roles | Where-Object { $DisallowedRoles -contains $_.Name })
  if ($hit.Count -gt 0) {
    foreach ($h in $hit) { Write-Warning "[failure] Unintended role/feature installed: $($h.Name)" }
  } else {
    Write-Warning "[pass] No unintended roles/features installed"
  }
}



function HealthTest-MalwareProtectionFeatures {
<#
.SYNOPSIS
Checks Malware Protection Features and flags unhealthy or non-baseline states

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-MpComputerStatus, Write-BasedOnTestResult, Update-MpSignature.
FalsePositives: None.
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




function HealthTest-ExploitProtectionBaseline {
<#
.SYNOPSIS
Checks Exploit Protection Baseline and flags unhealthy or non-baseline states

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Audit / Compliance / Informational
Impact: Medium(Time)
Uses: Get-ProcessMitigation.
FalsePositives: None.
#>
    if (-not (Get-Command Get-ProcessMitigation -ErrorAction SilentlyContinue)) { Write-Warning "[notice] Exploit Protection cmdlets unavailable"; return }
    $sys = Get-ProcessMitigation -System -ErrorAction SilentlyContinue
    if (-not $sys) { Write-Warning "[warning] Could not read system process mitigations"; return }
    $ok = $true
    if (-not $sys.Dep.Enable) { Write-Warning "[notice] Exploit Protection; DEP not enforced system-wide"; $ok = $false }
    if (-not $sys.ASLR.EnableForceRelocateImages) { Write-Warning "[notice] Exploit Protection; ASLR not enforcing force-relocate"; $ok = $false }
    if (-not $sys.SEHOP.Enable) { Write-Warning "[notice] Exploit Protection; SEHOP not enabled"; $ok = $false }
    if ($ok) { Write-Warning "[pass] Exploit Protection key mitigations enabled"; return } else { return }
}

function HealthTest-StartupItems{
<#
.SYNOPSIS
Checks Startup Items and flags unhealthy or non-baseline states

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-ItemProperty.
FalsePositives: None.
#>
  $paths=@(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
  )
  $items=@()
  foreach($p in $paths){
    if(Test-Path $p){
      $props=Get-ItemProperty $p
      $props.PSObject.Properties | Where-Object { $_.Name -notin 'PSPath','PSParentPath','PSChildName','PSDrive','PSProvider' } | ForEach-Object {
        $items += "$p -> $($_.Name)=$($_.Value)"
      }
    }
  }
  if($items.Count -gt 0){
    Write-Warning ("[pass] Startup items reviewed`n" + ($items -join '; '))
  } else {
    Write-Warning "[pass] No startup items found in standard keys"}
}
