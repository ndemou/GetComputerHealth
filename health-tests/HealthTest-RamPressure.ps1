<#
Standalone file for HealthTest-RamPressure.
Generated during the repo-wide health-test split.
#>
# HostRequirement: All

function Get-TopRamProcess {
    <#
    .SYNOPSIS
    Returns the processes consuming the most resident physical memory.

    .DESCRIPTION
    Returns at least MinProcesses processes, ordered by working-set size.

    Processes continue to be included until their combined working sets reach
    TargetPercentOfUsedRam percent of currently used physical RAM, or until
    MaxProcesses processes have been included. Estimated non-process RAM is
    included in the ranking as a synthetic entry named [non-process].

    Command lines are excluded by default because retrieving them requires an
    additional CIM/WMI query. Use IncludeCommandLine when they are required.

    .PARAMETER MinProcesses
    Minimum number of processes to return.

    The default is 10.

    .PARAMETER MaxProcesses
    Maximum number of processes to return, even when the requested RAM target
    has not been reached.

    MaxProcesses cannot be less than MinProcesses.

    The default is 100.

    .PARAMETER TargetPercentOfUsedRam
    Target percentage of currently used physical RAM to cover with the
    cumulative working sets of the returned processes.

    This is a target rather than an exact limit. The final process is included
    in full, so the reported cumulative percentage normally exceeds the
    requested percentage slightly.

    The default is 25.

    .PARAMETER IncludeCommandLine
    Retrieves and returns the command line for each selected process.

    This requires an additional CIM/WMI query and therefore adds work on an
    already stressed system. Command lines may also expose passwords, tokens,
    connection strings, or other sensitive values.

    Some command lines may be unavailable because of permissions, protected
    processes, or processes terminating during collection.

    .OUTPUTS
    PSCustomObject with the following properties:

      PID
      Name
      RAM_MB
      RAM_PercentOfTotal
      RAM_PercentOfUsed
      CumulativeUsedRAMPct
      CommandLine

    CommandLine is null unless IncludeCommandLine is specified.

    .NOTES
    RAM usage is based on each process's working set. A working set represents
    physical pages currently resident for that process, but it can contain
    shared pages such as DLL code. Summing process working sets can therefore
    count the same physical pages more than once. CumulativeUsedRAMPct is an
    approximate diagnostic value and can exceed 100 percent.

    Not all used physical RAM belongs to user-visible processes. Kernel pools,
    drivers, the file cache, modified pages, memory compression, Hyper-V guest
    memory, and other operating-system allocations may consume substantial
    memory. The function estimates that gap as:

      used physical RAM minus the summed working sets of all readable
      processes

    The estimate is exposed as the synthetic [non-process] entry. When summed
    working sets exceed used RAM because of shared pages, the synthetic entry
    is reported as zero.

    Process state can change during collection. A process may terminate after
    it is enumerated, and Windows could theoretically reuse its PID before the
    optional command-line query. Such races cannot be eliminated by a snapshot
    function.

    The function creates and sorts a small object for every process before
    selecting the result set. This is normally minor, but its cost increases on
    systems running unusually large numbers of processes.

    When IncludeCommandLine is used, the additional CIM/WMI query consumes more
    CPU and memory and may involve provider activity at a time when the system
    is already under pressure.

    .EXAMPLE
    Get-TopRamProcess

    Returns at least 10 entries and continues until their combined RAM usage
    approximately covers 25 percent of currently used RAM, up to a maximum of
    100 entries. The ranking may include the synthetic [non-process] entry.

    .EXAMPLE
    Get-TopRamProcess -MinProcesses 5 -MaxProcesses 50 `
        -TargetPercentOfUsedRam 40

    Returns at least 5 and at most 50 processes, targeting approximately
    40 percent of currently used RAM.

    .EXAMPLE
    Get-TopRamProcess -IncludeCommandLine

    Includes process command lines using an additional CIM/WMI query.
    #>

    [CmdletBinding()]
    param(
        [ValidateRange(1, 10000)]
        [int]$MinProcesses = 10,

        [ValidateRange(1, 10000)]
        [int]$MaxProcesses = 100,

        [ValidateRange(0.1, 100)]
        [double]$TargetPercentOfUsedRam = 25,

        [switch]$IncludeCommandLine
    )

    if ($MaxProcesses -lt $MinProcesses) {
        throw 'MaxProcesses cannot be less than MinProcesses.'
    }

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem `
            -Property TotalVisibleMemorySize, FreePhysicalMemory `
            -ErrorAction Stop
    }
    catch {
        throw "Unable to obtain system memory information: $($_.Exception.Message)"
    }

    $totalRamBytes = [double]$os.TotalVisibleMemorySize * 1KB
    $freeRamBytes = [double]$os.FreePhysicalMemory * 1KB

    if ($totalRamBytes -le 0) {
        throw 'The operating system returned an invalid total RAM value.'
    }

    $usedRamBytes = [double]$totalRamBytes - [double]$freeRamBytes

    if ($usedRamBytes -lt 0) {
        $usedRamBytes = 0.0
    }
    elseif ($usedRamBytes -gt $totalRamBytes) {
        $usedRamBytes = $totalRamBytes
    }

    $targetRamBytes = (
        $usedRamBytes *
        ($TargetPercentOfUsedRam / 100)
    )

    $unreadableProcessCount = 0

    $processes = @(
        Get-Process -ErrorAction SilentlyContinue |
            ForEach-Object {
                $process = $_

                try {
                    [pscustomobject]@{
                        PID      = [int]$process.Id
                        Name     = [string]$process.ProcessName
                        RamBytes = [int64]$process.WorkingSet64
                    }
                }
                catch {
                    $unreadableProcessCount++
                }
                finally {
                    $process.Dispose()
                }
            } |
            Sort-Object -Property RamBytes -Descending
    )

    $summedProcessRamBytes = (
        $processes |
            Measure-Object -Property RamBytes -Sum
    ).Sum

    if ($null -eq $summedProcessRamBytes) {
        $summedProcessRamBytes = 0.0
    }

    $nonProcessRamBytes = $usedRamBytes - [double]$summedProcessRamBytes

    if ($nonProcessRamBytes -lt 0) {
        $nonProcessRamBytes = 0.0
    }

    $processes = @(
        $processes + [pscustomobject]@{
            PID      = -1
            Name     = '[non-process]'
            RamBytes = [int64][math]::Round($nonProcessRamBytes)
        } |
            Sort-Object -Property RamBytes -Descending
    )

    if ($unreadableProcessCount -gt 0) {
        Write-Verbose (
            "$unreadableProcessCount process(es) exited or could not be read."
        )
    }

    $selected = New-Object 'System.Collections.Generic.List[object]'
    $selectedRamBytes = 0.0

    foreach ($process in $processes) {
        if ($selected.Count -ge $MaxProcesses) {
            break
        }

        [void]$selected.Add($process)
        $selectedRamBytes += $process.RamBytes

        if (
            $selected.Count -ge $MinProcesses -and
            $selectedRamBytes -ge $targetRamBytes
        ) {
            break
        }
    }

    $processes = $null
    $commandLines = @{}

    if ($IncludeCommandLine -and $selected.Count -gt 0) {
        $filter = (
            $selected |
                ForEach-Object {
                    "ProcessId = $($_.PID)"
                }
        ) -join ' OR '

        try {
            Get-CimInstance -ClassName Win32_Process `
                -Filter $filter `
                -Property ProcessId, CommandLine `
                -ErrorAction Stop |
                ForEach-Object {
                    $commandLines[[int]$_.ProcessId] = $_.CommandLine
                }
        }
        catch {
            Write-Verbose (
                "Unable to retrieve command lines: $($_.Exception.Message)"
            )
        }
    }

    if ($selectedRamBytes -lt $targetRamBytes) {
        $coveredPercent = if ($usedRamBytes -gt 0) {
            $selectedRamBytes / $usedRamBytes * 100
        }
        else {
            0
        }

        Write-Verbose (
            'The approximate target was not reached. ' +
            "Returned $($selected.Count) entr$(if ($selected.Count -eq 1) { 'y' } else { 'ies' }), covering " +
            "$([math]::Round($coveredPercent, 1))% of used RAM by measured " +
            'RAM usage. MaxProcesses may be the cause.'
        )
    }

    $cumulativeRamBytes = 0.0

    foreach ($process in $selected) {
        $cumulativeRamBytes += $process.RamBytes

        [pscustomobject][ordered]@{
            PID                  = $process.PID
            Name                 = $process.Name
            RAM_MB               = [math]::Round(
                $process.RamBytes / 1MB,
                1
            )
            RAM_PercentOfTotal   = [math]::Round(
                $process.RamBytes / $totalRamBytes * 100,
                2
            )
            RAM_PercentOfUsed    = if ($usedRamBytes -gt 0) {
                [math]::Round(
                    $process.RamBytes / $usedRamBytes * 100,
                    2
                )
            }
            else {
                0
            }
            CumulativeUsedRAMPct = if ($usedRamBytes -gt 0) {
                [math]::Round(
                    $cumulativeRamBytes / $usedRamBytes * 100,
                    2
                )
            }
            else {
                0
            }
            CommandLine          = if ($IncludeCommandLine) {
                $commandLines[$process.PID]
            }
            else {
                $null
            }
        }
    }
}

function HealthTest-RamPressure {
<#
Description: Checks for sustained memory pressure using available memory and commit counters.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(RAM), Medium(CPU)
Uses: Get-Counter, Get-TopRamProcess.
#>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [ValidateRange(1,2147483647)][int]$Samples=1,
    [ValidateRange(0,3600000)][int]$SampleDelayMs=500
  )

  $os = Get-CimInstance Win32_OperatingSystem
  $totalMB = [math]::Round($os.TotalVisibleMemorySize/1024,1)
  if ($totalMB -le 0) { Write-Warning "[FAILURE] Total visible memory is 0 MB; cannot compute free %."; return }

  function Get-AvailMB {
    try {
      $c = (Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples.CookedValue
      if ($null -eq $c) { throw "No counter value." }
      [math]::Round([double]$c,1)
    } catch { return $null }
  }

  $vals = @()
  for ($i=0; $i -lt $Samples; $i++) {
    $v = Get-AvailMB
    if ($null -eq $v) { Write-Warning "[WARNING] Skipped a failed \\Memory\\Available MBytes read (sample $($i+1)/$Samples)."; continue }
    $vals += $v
    if (($i+1) -lt $Samples -and $SampleDelayMs) { Write-Verbose "waiting $SampleDelayMs ms"; Start-Sleep -Milliseconds $SampleDelayMs }
  }
  if ($vals.Count -eq 0) { Write-Warning "[FAILURE] Failed to sample available memory."; return }

  $sorted = @($vals | Sort-Object)
  $n = $sorted.Length
  $mid = [int]($n/2)
  $medianFree = if ($n % 2) { [double]$sorted[$mid] } else { ([double]$sorted[$mid-1] + [double]$sorted[$mid]) / 2 }
  $freePcnt = [math]::Round(($medianFree*100)/$totalMB,1)

  if ($Samples -eq 1 -and $freePcnt -lt 10) {
    if ($SampleDelayMs) { Start-Sleep -Milliseconds $SampleDelayMs }
    $v = Get-AvailMB
    if ($null -ne $v) {
      $medianFree = [math]::Round((([double]$medianFree + [double]$v)/2),1)
      $freePcnt = [math]::Round(($medianFree*100)/$totalMB,1)
    }
  }

  if ($freePcnt -lt 10) {
    $processes = (
      Get-TopRamProcess -TargetPercentOfUsedRam 25 |
        ForEach-Object { "$([int]$_.RAM_MB)MB $($_.Name)" }
    ) -join ', '
    $details = "These are the top processes by RAM usage: $processes"
  }

  if ($freePcnt -lt 2) { Write-Warning "[FAILURE] Free RAM under 2%`n$freePcnt% free RAM`n$details"; return }
  elseif ($freePcnt -lt 5) { Write-Warning "[WARNING] Free RAM between 2 and 5%`n$freePcnt% free RAM`n$details"; return }
  elseif ($freePcnt -lt 10) { Write-Warning "[NOTICE] Free RAM between 5 and 10%`n$freePcnt% free RAM`n$details"; return }
  Write-Warning "[PASS] Free RAM at $freePcnt%"
  return
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-RamPressure
}
