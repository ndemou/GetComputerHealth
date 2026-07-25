# HostRequirement: All

function HealthTest-PagefileSanity{
<#
Description: Checks whether paging file configuration is present and sized sensibly.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Disk), Medium(Time)
Tags: Essential
Uses: None.
#>
  [CmdletBinding()] param([int]$MinMB=1024,[switch]$RequireOnSystemDrive)
  $cs   = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
  $auto = $cs.AutomaticManagedPagefile
  $usage = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
  $regPath='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
  $pfReg=(Get-ItemProperty -Path $regPath -Name PagingFiles -ErrorAction SilentlyContinue).PagingFiles

  $entries=@()
  if($usage){
    foreach($u in $usage){ $entries += [pscustomobject]@{Name=$u.Name;AllocMB=[int]$u.AllocatedBaseSize;CurrMB=[int]$u.CurrentUsage} }
  }
  if(-not $entries -and $pfReg){
    foreach($line in $pfReg){
      $parts=$line -split '\s+'
      if($parts.Length -ge 1){
        $name=$parts[0]; $min= if($parts.Length -ge 2){ [int]$parts[1] } else { 0 }
        $entries += [pscustomobject]@{Name=$name;AllocMB=$min;CurrMB=$null}
      }
    }
  }

  if(-not $entries){
    Write-Warning ("[FAILURE] No pagefile detected`nAutomaticManagedPagefile=" + [int]$auto)
    return
  }

  $sumAlloc=($entries | Measure-Object AllocMB -Sum).Sum
  $okSize = ($sumAlloc -ge $MinMB)
  $okSys  = $true
  if($RequireOnSystemDrive){
    $sys = $env:SystemDrive  # Typically 'C:'
    $okSys = (($entries | Where-Object {$_.Name -like "$sys\*"}).Count -gt 0)
    if(-not $okSys){ Write-Warning ("[FAILURE] No pagefile on system drive`nSystemDrive={0}; Entries={1}" -f $sys, (($entries | ForEach-Object { "$($_.Name):$($_.AllocMB)MB" }) -join ', ')) }
  }
  if(-not $okSize){ Write-Warning "[FAILURE] Total pagefile size below threshold`nTotalAllocMB=$sumAlloc; MinMB=$MinMB" }

  if($okSize -and $okSys){
    Write-Warning ("[PASS] Paging file configured sensibly`nAuto={0}; TotalAllocMB={1}; Entries={2}" -f ([int]$auto), $sumAlloc, (($entries | ForEach-Object { "$($_.Name):$($_.AllocMB)MB" }) -join ', '))
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-PagefileSanity
}
