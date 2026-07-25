# HostRequirement: DC

function HealthTest-NtdsLogVolumeFree{
<#
Description: Checks whether the NTDS log volume has enough free space.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Disk)
Uses: None.
#>
  [CmdletBinding()] param([int]$MinFreeGB=5)
  $p='HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
  $logPath=(Get-ItemProperty $p -Name 'Database log files path').'Database log files path'
  $drive=(Get-Item $logPath).PSDrive.Name+':'
  $d=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive'"
  $freeGB=[math]::Round($d.FreeSpace/1GB,2)
  if($freeGB -ge $MinFreeGB){
    Write-Warning "[PASS] NTDS log volume free space OK ($freeGB GB >= $MinFreeGB GB)"
  } else {
    Write-Warning (
      "[FAILURE] " +
      "NTDS log volume low free space ($freeGB GB < $MinFreeGB GB)" +
      "`n" +
      "Log path: $logPath"
    )
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-NtdsLogVolumeFree
}
