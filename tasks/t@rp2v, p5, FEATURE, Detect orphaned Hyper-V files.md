<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:37:08.860Z","completions":[]} -->

```
<#
.SYNOPSIS
Detects orphaned Hyper-V files (disks, configs, state, etc.) and reports them.

.DESCRIPTION
Builds an "in-use" map from Hyper-V:
  - VM IDs via Get-VM
  - All disks attached to VMs via Get-VMHardDiskDrive
  - Walks VHDX/AVHDX parent chains via Get-VHD to include parents

Scans typical Hyper-V roots (recursively) and classifies files:
  Failures:
    - .vhdx / .avhdx not referenced by any VM chain
    - .vmcx / .vmrs / .vmgs whose GUID does not belong to any VM
    - .bin / .vsv / .svo with non-VM GUID
  Notices:
    - .rct / .mrt / .mrt.log (likely stale RCT logs if base VHDX unused)
    - .tmp, export remnants (.exp folders), replication metadata (*.hrl, *.hrx, *.xml) not referenced
    - Access denied / IO errors while scanning

Outputs Write-Failure/Write-Notice lines and returns [bool] (healthy = no failures).

.PARAMETER Roots
Folders to scan recursively. Defaults cover common Hyper-V paths on the host.

.PARAMETER ScanAllFixed
If set, also scans all fixed drives’ roots (e.g., C:\, D:\) for stray artifacts.

.EXAMPLE
HealthTest-OrphanedHyperVFiles
.EXAMPLE
HealthTest-OrphanedHyperVFiles -Roots 'D:\Hyper-V','E:\VMStore'
#>
function HealthTest-OrphanedHyperVFiles {
    [CmdletBinding()]
    param(
        [string[]]$Roots = @(
            'C:\ProgramData\Microsoft\Windows\Hyper-V',
            'C:\ProgramData\Microsoft\Windows\Hyper-V\Virtual Machines',
            'C:\Users\Public\Documents\Hyper-V',
            'C:\Hyper-V',
            'D:\Hyper-V'
        ),
        [switch]$ScanAllFixed
    )

    $hadFailure = $false
    $notices = 0

    # Helpers
    function _NormPath([string]$p){
        if ([string]::IsNullOrWhiteSpace($p)) { return $null }
        try { (Resolve-Path -LiteralPath $p -ErrorAction Stop).Path } catch { $p }
    }
    function _GuidFromName([string]$name){
        if (-not $name) { return $null }
        $m = [regex]::Match($name, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
        if ($m.Success) { return $m.Groups[1].Value.ToLowerInvariant() }
        return $null
    }

    # 1) Collect VM IDs and referenced disk paths
    $vmIds = New-Object 'System.Collections.Generic.HashSet[string]'
    $inUseDisks = New-Object 'System.Collections.Generic.HashSet[string]'
    try {
        $vms = Get-VM -ErrorAction Stop
        foreach($vm in $vms){
            if ($vm.Id) { [void]$vmIds.Add($vm.Id.Guid.ToString().ToLowerInvariant()) }
            $drives = Get-VMHardDiskDrive -VMName $vm.Name -ErrorAction SilentlyContinue
            foreach($d in $drives){
                $p = _NormPath $d.Path
                if ($p) {
                    [void]$inUseDisks.Add($p.ToLowerInvariant())
                    # Walk parent chain
                    try {
                        $cur = $p
                        while ($true) {
                            $v = Get-VHD -Path $cur -ErrorAction Stop
                            if (-not $v.ParentPath) { break }
                            $pp = _NormPath $v.ParentPath
                            if (-not $pp) { break }
                            [void]$inUseDisks.Add($pp.ToLowerInvariant())
                            $cur = $pp
                        }
                    } catch { }
                }
            }
        }
    }
    catch {
        Write-Warning ("[Failure] Failed to enumerate VMs/disks: {0}" -f $_.Exception.Message)
        return $false
    }

    # 2) Build scan roots
    $scanRoots = New-Object System.Collections.Generic.List[string]
    foreach($r in $Roots){
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        if (Test-Path -LiteralPath $r) { $scanRoots.Add((Resolve-Path -LiteralPath $r).Path) }
    }
    if ($ScanAllFixed) {
        $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -ge 0 -and $_.Root -match '^[A-Z]:\\$' }
        foreach($d in $drives){ if (-not $scanRoots.Contains($d.Root)) { $scanRoots.Add($d.Root) } }
    }
    if ($scanRoots.Count -eq 0) {
        Write-Warning "[Warning] No scan roots exist; nothing to check."
        return $true
    }

    # 3) Scan and classify
    $extFailDisk = @('.vhdx','.avhdx')
    $extCfgState = @('.vmcx','.vmrs','.vmgs','.bin','.vsv','.svo')
    $extNotice   = @('.rct','.mrt','.log','.tmp')
    $repMetaLike = @('*.hrl','*.hrx','*.xml') # replication metadata heuristics

    foreach($root in $scanRoots){
        try {
            $files = Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction Stop
        }
        catch {
            Write-Warning ("[Warning] Access denied or IO error scanning {0}: {1}" -f $root, $_.Exception.Message)
            $notices++
            continue
        }

        foreach($f in $files){
            $ext = $f.Extension.ToLowerInvariant()
            $pathL = $f.FullName.ToLowerInvariant()

            if ($extFailDisk -contains $ext) {
                if (-not $inUseDisks.Contains($pathL)) {
                    $hadFailure = $true
                    Write-Warning ("[Failure] Orphaned {0}: {1}  SizeGB={2}  Modified={3}" -f $ext.Trim('.').ToUpper(), $f.FullName, [math]::Round($f.Length/1GB,2), $f.LastWriteTime)
                }
                continue
            }

            if ($extCfgState -contains $ext) {
                $gid = _GuidFromName $f.Name
                if ($gid -and -not $vmIds.Contains($gid)) {
                    $hadFailure = $true
                    Write-Warning ("[Failure] Orphaned {0} (no matching VM ID): {1}  Modified={2}" -f $ext.Trim('.').ToUpper(), $f.FullName, $f.LastWriteTime)
                }
                continue
            }

            if ($extNotice -contains $ext) {
                # RCT/MRT: if base VHDX clearly not in use, call it out; otherwise just note
                $base = [System.IO.Path]::ChangeExtension($f.FullName, '.vhdx')
                $baseL = $base.ToLowerInvariant()
                if (Test-Path -LiteralPath $base) {
                    if (-not $inUseDisks.Contains($baseL)) {
                        Write-Warning ("[Warning] Stale {0} next to unused VHDX: {1}" -f $ext.Trim('.').ToUpper(), $f.FullName)
                    } else {
                        Write-Warning ("[Warning] RCT/MRT or temp file present: {0}" -f $f.FullName)
                    }
                } else {
                    Write-Warning ("[Warning] Unpaired {0} file: {1}" -f $ext.Trim('.').ToUpper(), $f.FullName)
                }
                $notices++
                continue
            }

            # Replication metadata heuristics (by pattern, not just extension)
            foreach($pat in $repMetaLike){
                if ([System.Management.Automation.WildcardPattern]::new($pat,'IgnoreCase').IsMatch($f.Name)) {
                    # If there is no corresponding VM folder/ID, treat as notice (not hard failure)
                    $gid = _GuidFromName $f.Name
                    if (($gid -and -not $vmIds.Contains($gid)) -or (-not $gid)) {
                        Write-Warning ("[Warning] Possible orphaned replication metadata: {0}" -f $f.FullName)
                        $notices++
                    }
                    break
                }
            }
        }
    }

    if (-not $hadFailure) {
        Write-Pass ("No orphaned disks/config/state found. Notices: {0}" -f $notices)
        return $true
    }

    return $false
}
```
