# HostRequirement: All

function HealthTest-SeriousRecentEventLogs {
<#
Description: Checks recent event logs and minidumps for serious crash, disk, or application events.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: Get-WinEvent, Get-ChildItem.
#>
    [CmdletBinding()]
    param([int]$Hours = 24)


    if ($Hours -lt 1) { $Hours = 1 }
    $cutoff = (Get-Date).AddHours(-$Hours)
    $totalFindings = 0

    function Get-FirstLine([string]$Text) {
        if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
        return (($Text -split "`r?`n")[0]).Trim()
    }

    function Get-EventIdentity($EventRecord) {
        if ($null -eq $EventRecord) { return '' }

        $logName = if ($EventRecord.PSObject.Properties['LogName']) { [string]$EventRecord.LogName } else { '' }
        $providerName = if ($EventRecord.PSObject.Properties['ProviderName']) { [string]$EventRecord.ProviderName } else { '' }
        $eventId = if ($EventRecord.PSObject.Properties['Id']) { [string]$EventRecord.Id } else { '' }
        $recordId = if ($EventRecord.PSObject.Properties['RecordId']) { [string]$EventRecord.RecordId } else { '' }

        if (-not [string]::IsNullOrWhiteSpace($recordId)) {
            return ("record|{0}|{1}|{2}|{3}" -f $logName, $providerName, $eventId, $recordId).ToLowerInvariant()
        }

        $timeText = if ($EventRecord.PSObject.Properties['TimeCreated'] -and $EventRecord.TimeCreated) { ([datetime]$EventRecord.TimeCreated).ToString('o') } else { '' }
        $messageText = if ($EventRecord.PSObject.Properties['Message']) { [string]$EventRecord.Message } else { '' }
        return ("fallback|{0}|{1}|{2}|{3}|{4}" -f $logName, $providerName, $eventId, $timeText, $messageText).ToLowerInvariant()
    }

    function Test-MarkEventSeen($EventRecord, [System.Collections.Generic.HashSet[string]]$SeenEvents) {
        $eventIdentity = Get-EventIdentity -EventRecord $EventRecord
        if ([string]::IsNullOrWhiteSpace($eventIdentity)) { return $false }
        if ($SeenEvents.Contains($eventIdentity)) { return $true }
        [void]$SeenEvents.Add($eventIdentity)
        return $false
    }

    function Get-EventLocalTime($EventRecord) {
        if ($null -eq $EventRecord -or -not $EventRecord.PSObject.Properties['TimeCreated'] -or -not $EventRecord.TimeCreated) { return $null }

        $eventTime = [datetime]$EventRecord.TimeCreated
        if ($eventTime.Kind -eq [DateTimeKind]::Utc) { return $eventTime.ToLocalTime() }
        return $eventTime
    }

    function Get-EventLocalTimeText($EventRecord) {
        $eventTime = Get-EventLocalTime -EventRecord $EventRecord
        if ($null -eq $eventTime) { return 'unknown-time' }
        return $eventTime.ToString('yyyy-MM-dd HH:mm:ss')
    }

    function Get-EventLocalDateText($EventRecord) {
        $eventTime = Get-EventLocalTime -EventRecord $EventRecord
        if ($null -eq $eventTime) { return 'unknown-date' }
        return $eventTime.ToString('yyyy-MM-dd')
    }

    function Get-EventDetailLine($EventRecord) {
        $eventTimeText = Get-EventLocalTimeText -EventRecord $EventRecord
        $recordIdText = if ($EventRecord.PSObject.Properties['RecordId'] -and $null -ne $EventRecord.RecordId) { [string]$EventRecord.RecordId } else { 'unknown' }
        $logNameText = if ($EventRecord.PSObject.Properties['LogName'] -and -not [string]::IsNullOrWhiteSpace([string]$EventRecord.LogName)) { [string]$EventRecord.LogName } else { 'unknown-log' }
        return "$eventTimeText local time | $logNameText | $($EventRecord.ProviderName) | Event ID $($EventRecord.Id) | Record ID $recordIdText"
    }

    function Write-EventFinding([string]$Severity, [string]$Synopsis, $EventRecord) {
        $msg = Get-FirstLine -Text $EventRecord.Message
        Write-Warning "[$Severity] $Synopsis`n$(Get-EventDetailLine -EventRecord $EventRecord)`n$msg"
    }

    function Write-ApplicationCrashFinding([string]$Severity, [string]$Synopsis, [object[]]$EventRecords) {
        $events = @($EventRecords)
        if ($events.Count -eq 0) { return }

        $sortedEvents = @($events | Sort-Object -Property TimeCreated, RecordId)
        $firstEvent = $sortedEvents[0]
        $eventWord = if ($events.Count -eq 1) { 'event' } else { 'events' }
        $localDateText = Get-EventLocalDateText -EventRecord $firstEvent
        $msg = Get-FirstLine -Text $firstEvent.Message

        $commentLines = @(
            ("Detected {0} Application Error {1} for this executable on local date {2}." -f $events.Count, $eventWord, $localDateText),
            'Exact local times:'
        )

        foreach ($eventRecord in $sortedEvents) {
            $commentLines += ("- {0}" -f (Get-EventLocalTimeText -EventRecord $eventRecord))
        }

        $commentLines += ("First event: {0}" -f (Get-EventDetailLine -EventRecord $firstEvent))
        $commentLines += $msg
        Write-Warning "[$Severity] $Synopsis`n$($commentLines -join "`n")"
    }

    function Get-FaultingApplicationName($EventRecord) {
        if ($null -eq $EventRecord -or [string]::IsNullOrWhiteSpace($EventRecord.Message)) { return "" }

        $match = [regex]::Match($EventRecord.Message, '(?im)^\s*Faulting application name:\s*([^,\r\n]+)')
        if ($match.Success) {
            return $match.Groups[1].Value.Trim()
        }

        return ""
    }

    function Get-RecentMinidumpFiles([datetime]$AfterTime) {
        $files = @()

        if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { return $files }

        $minidumpPath = Join-Path $env:SystemRoot 'Minidump'
        $dumpItems = @(Get-ChildItem -LiteralPath $minidumpPath -Filter '*.dmp' -ErrorAction SilentlyContinue)
        foreach ($dumpItem in $dumpItems) {
            if ($dumpItem.LastWriteTime -gt $AfterTime) {
                $files += $dumpItem
            }
        }

        return $files
    }

    function Get-MinidumpDetailText([object[]]$MinidumpFiles) {
        $lines = @()
        foreach ($file in @($MinidumpFiles | Sort-Object -Property LastWriteTime, FullName)) {
            $lines += ("- {0} | LastWriteTime={1}" -f $file.FullName, ([datetime]$file.LastWriteTime).ToString('yyyy-MM-dd HH:mm:ss'))
        }

        return ($lines -join "`n")
    }

    $seenEvents = New-Object 'System.Collections.Generic.HashSet[string]'
    $recentMinidumps = @(Get-RecentMinidumpFiles -AfterTime $cutoff)
    $systemCrashEventFindings = 0

    # [FAILURE] Blue screen / bugcheck / unexpected shutdown
    $failureFilters = @(
        @{ LogName = 'System'; Id = 41;   ProviderName = 'Microsoft-Windows-Kernel-Power';          StartTime = $cutoff },
        @{ LogName = 'System'; Id = 6008; ProviderName = 'EventLog';                                 StartTime = $cutoff },
        @{ LogName = 'System'; Id = 1001; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; StartTime = $cutoff }
    )
    foreach ($filter in $failureFilters) {
        Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue | ForEach-Object {
            if (-not (Test-MarkEventSeen -EventRecord $_ -SeenEvents $seenEvents)) {
                $totalFindings++
                $systemCrashEventFindings++
                $synopsis = if ($_.Id -eq 1001) { 'Detected blue screen / bugcheck event in System log' } else { 'Detected unexpected system shutdown event in System log' }
                Write-EventFinding -Severity 'failure' -Synopsis $synopsis -EventRecord $_
            }
        }
    }

    # [WARNING] Disk errors
    $diskProviders = @('disk', 'Ntfs', 'stornvme', 'storahci', 'iaStorA', 'iaStorAVC', 'iaStorV')
    $diskEventIds = @(7, 51, 52, 55, 98, 129, 153, 157)
    Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $cutoff; Level = 2 } -ErrorAction SilentlyContinue |
        Where-Object { ($diskProviders -contains $_.ProviderName) -or ($diskEventIds -contains $_.Id) } |
        ForEach-Object {
            if (-not (Test-MarkEventSeen -EventRecord $_ -SeenEvents $seenEvents)) {
                $totalFindings++
                Write-EventFinding -Severity 'warning' -Synopsis 'Detected serious disk error in System log' -EventRecord $_
            }
        }

    # [NOTICE] Application crashes
    $applicationCrashGroups = @{}
    Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000; ProviderName = 'Application Error'; StartTime = $cutoff } -ErrorAction SilentlyContinue |
        ForEach-Object {
            if (-not (Test-MarkEventSeen -EventRecord $_ -SeenEvents $seenEvents)) {
                $appName = Get-FaultingApplicationName -EventRecord $_
                $appKey = if ($appName) { $appName.ToLowerInvariant() } else { '<unknown-application>' }
                $dateKey = Get-EventLocalDateText -EventRecord $_
                $groupKey = "$appKey|$dateKey"
                if (-not $applicationCrashGroups.ContainsKey($groupKey)) {
                    $applicationCrashGroups[$groupKey] = New-Object System.Collections.ArrayList
                }
                [void]$applicationCrashGroups[$groupKey].Add($_)
            }
        }

    foreach ($groupKey in @($applicationCrashGroups.Keys | Sort-Object)) {
        $events = @($applicationCrashGroups[$groupKey])
        if ($events.Count -eq 0) { continue }

        $firstEvent = $events | Sort-Object -Property TimeCreated, RecordId | Select-Object -First 1
        $appName = Get-FaultingApplicationName -EventRecord $firstEvent
        $synopsis = if ($appName) { "Detected application crash in Application log: $appName" } else { 'Detected application crash in Application log' }
        $totalFindings++
        Write-ApplicationCrashFinding -Severity 'notice' -Synopsis $synopsis -EventRecords $events
    }

    if ($recentMinidumps.Count -gt 0) {
        $minidumpDetails = Get-MinidumpDetailText -MinidumpFiles $recentMinidumps
        if ($systemCrashEventFindings -gt 0) {
            Write-Warning "[info] Recent minidump file(s) found in the same SeriousRecentEventLogs window`nThe crash event-log finding is the canonical failure for this incident window.`n$minidumpDetails"
        } else {
            $totalFindings++
            Write-Warning "[failure] Recent minidump file(s) found without a matching shutdown or bugcheck event in the queried window`n$minidumpDetails"
        }
    }

    if ($totalFindings -eq 0) {
        Write-Warning "[PASS] No serious shutdown, bugcheck, disk error, application crash, or minidump signals found in the last $Hours hour(s)"
    }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-SeriousRecentEventLogs
}
