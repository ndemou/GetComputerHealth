# HostRequirement: All

if (-not (Get-Command -Name 'Get-PolicyListShortHash' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helpers-for-healthtests.ps1')
}

if (-not (Get-Command -Name 'Normalize-PolicyListText' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helpers-for-healthtests.ps1')
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
Policy baseline version: 2
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

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-ListStartupItems
}
