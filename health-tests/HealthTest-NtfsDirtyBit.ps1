# HostRequirement: All

function HealthTest-NtfsDirtyBit {
<#
Description: Checks whether any NTFS volumes have the dirty bit set.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Disk)
Tags: Essential
Uses: Get-Volume, fsutil.exe.
#>
    $dirty = @()
    $drives = Get-Volume -FileSystem NTFS -ErrorAction SilentlyContinue
    foreach ($d in $drives) {
      $out = (& fsutil dirty query $d.DriveLetter`: 2>$null)
      if ($out -and ($out -match 'is dirty')) { $dirty += $d.DriveLetter }
    }
    if ($dirty.Count -gt 0) { Write-Warning "[WARNING] NTFS dirty bit set on: $($dirty -join ', ')"; return }
    Write-Warning "[PASS] No NTFS dirty volumes"
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-NtfsDirtyBit
}
