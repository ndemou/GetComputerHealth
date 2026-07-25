# HostRequirement: All

function HealthTest-FailedLoginAttemptsRecent {
<#
Description: Checks the Security log for failed login attempts within the last 24 hours.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: High(Time), High(CPU)
Uses: Get-WinEvent.
#>
    [CmdletBinding()]
    param([int]$Hours = 24)

    function Get-EventPropertyValue {
        param(
            [Parameter(Mandatory)][object]$Event,
            [Parameter(Mandatory)][int]$Index
        )

        if (($null -eq $Event.Properties) -or ($Event.Properties.Count -le $Index)) {
            return $null
        }

        return $Event.Properties[$Index].Value
    }

    function Convert-LogonTypeToText {
        param([AllowNull()]$LogonType)

        $logonTypeText = [string]$LogonType
        switch ($logonTypeText) {
            '2' { 'Interactive' ; break }
            '3' { 'Network' ; break }
            '4' { 'Batch' ; break }
            '5' { 'Service' ; break }
            '7' { 'Unlock' ; break }
            '8' { 'NetworkCleartext' ; break }
            '9' { 'NewCredentials' ; break }
            '10' { 'RemoteInteractive' ; break }
            '11' { 'CachedInteractive' ; break }
            default { if ([string]::IsNullOrWhiteSpace($logonTypeText)) { '<unknown>' } else { $logonTypeText } }
        }
    }

    function Get-FailedLogonOriginHint {
        param(
            [Parameter(Mandatory)][string]$LogonTypeText,
            [AllowNull()][string]$ProcessName,
            [AllowNull()][string]$WorkstationName,
            [AllowNull()][string]$IpAddress,
            [AllowNull()][string]$SubStatus
        )

        $normalizedProcessName = if ([string]::IsNullOrWhiteSpace($ProcessName)) {
            ''
        } else {
            try {
                [System.IO.Path]::GetFileName($ProcessName)
            }
            catch {
                $ProcessName.Trim()
            }
        }

        $hasRemoteSource = (
            (-not [string]::IsNullOrWhiteSpace($WorkstationName)) -and
            ($WorkstationName -ne '-')
        ) -or (
            (-not [string]::IsNullOrWhiteSpace($IpAddress)) -and
            ($IpAddress -notin @('-', '::1', '127.0.0.1'))
        )

        if ($normalizedProcessName -ieq 'services.exe' -or $LogonTypeText -eq 'Service') {
            return 'Likely a service using stale credentials.'
        }

        if ($normalizedProcessName -ieq 'taskeng.exe' -or $normalizedProcessName -ieq 'taskhostw.exe' -or $LogonTypeText -eq 'Batch') {
            return 'Likely a scheduled task using stale credentials.'
        }

        if ($normalizedProcessName -ieq 'explorer.exe' -and $LogonTypeText -eq 'Network') {
            return 'Possibly a mapped drive or Explorer-triggered network access using stale credentials.'
        }

        if ($LogonTypeText -eq 'Network' -and $hasRemoteSource) {
            return 'Likely another machine or remote client attempting a network logon.'
        }

        if ($LogonTypeText -eq 'RemoteInteractive' -and $hasRemoteSource) {
            return 'Likely an RDP sign-in attempt from another machine.'
        }

        if ($LogonTypeText -eq 'Unlock') {
            return 'Likely a workstation unlock attempt.'
        }

        if ($SubStatus -eq '0xC0000234') {
            return 'Account lockout status observed; some events may be retries after lockout.'
        }

        'Origin unclear from event fields alone.'
    }

    function Format-FailedLogonEventLine {
        param(
            [Parameter(Mandatory)][object]$Event,
            [Parameter(Mandatory)][string]$Principal
        )

        function Convert-StatusValueToText {
            param([AllowNull()]$Value)

            if ($null -eq $Value) {
                return '<unknown>'
            }

            if ($Value -is [string]) {
                $text = $Value.Trim()
                if ([string]::IsNullOrWhiteSpace($text)) {
                    return '<unknown>'
                }
                return $text
            }

            try {
                return ('0x{0:X8}' -f ([uint32]$Value))
            }
            catch {
                return [string]$Value
            }
        }

        $timeCreated = $Event.TimeCreated
        if ($timeCreated -is [datetime]) {
            $localTime = $timeCreated.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
        } else {
            $localTime = '<unknown time>'
        }

        $status = Convert-StatusValueToText (Get-EventPropertyValue -Event $Event -Index 7)
        $subStatus = Convert-StatusValueToText (Get-EventPropertyValue -Event $Event -Index 9)
        $logonTypeText = Convert-LogonTypeToText (Get-EventPropertyValue -Event $Event -Index 10)
        $logonProcessName = [string](Get-EventPropertyValue -Event $Event -Index 11)
        $workstationName = [string](Get-EventPropertyValue -Event $Event -Index 13)
        $processName = [string](Get-EventPropertyValue -Event $Event -Index 18)
        $ipAddress = [string](Get-EventPropertyValue -Event $Event -Index 19)
        $ipPort = [string](Get-EventPropertyValue -Event $Event -Index 20)

        if ([string]::IsNullOrWhiteSpace($logonProcessName) -or $logonProcessName -eq '-') { $logonProcessName = '<unknown>' }
        if ([string]::IsNullOrWhiteSpace($workstationName) -or $workstationName -eq '-') { $workstationName = '<unknown>' }
        if ([string]::IsNullOrWhiteSpace($processName) -or $processName -eq '-') { $processName = '<unknown>' }
        if ([string]::IsNullOrWhiteSpace($ipAddress) -or $ipAddress -eq '-') { $ipAddress = '<unknown>' }
        if ([string]::IsNullOrWhiteSpace($ipPort) -or $ipPort -eq '-') { $ipPort = '<unknown>' }

        $hint = Get-FailedLogonOriginHint `
            -LogonTypeText $logonTypeText `
            -ProcessName $processName `
            -WorkstationName $workstationName `
            -IpAddress $ipAddress `
            -SubStatus $subStatus

        return (
            "$localTime principal='$Principal' logonType=$logonTypeText " +
            "workstation='$workstationName' ip='$ipAddress' port='$ipPort' " +
            "process='$processName' logonProcess='$logonProcessName' " +
            "status=$status subStatus=$subStatus hint='$hint'"
        )
    }

    if ($Hours -lt 1) { $Hours = 1 }
    $cutoff = (Get-Date).AddHours(-$Hours)
    $queryStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Verbose "Querying Security log for failed logons (Event ID 4625) since $($cutoff.ToString('yyyy-MM-dd HH:mm:ss'))."

    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4625; StartTime = $cutoff } -ErrorAction Stop)
    } catch {
        $queryStopwatch.Stop()
        if ($_.Exception.Message -like 'No events were found that match the specified selection criteria.*') {
            Write-Verbose "Get-WinEvent returned no matching 4625 events after $($queryStopwatch.ElapsedMilliseconds) ms."
            Write-Warning "[PASS] No failed login attempts found in the last $Hours hour(s)"
            return
        }
        Write-Verbose "Get-WinEvent failed after $($queryStopwatch.ElapsedMilliseconds) ms: $($_.Exception.Message)"
        Write-Warning "[WARNING] Failed to query Security log for failed login attempts`n$($_.Exception.Message)"
        return
    }
    $queryStopwatch.Stop()
    Write-Verbose "Get-WinEvent returned $($events.Count) matching event(s) in $($queryStopwatch.ElapsedMilliseconds) ms."

    if ($events.Count -eq 0) {
        Write-Verbose "No failed login events remained after query materialization."
        Write-Warning "[PASS] No failed login attempts found in the last $Hours hour(s)"
        return
    }

    $countsByUser = @{}
    $eventsByUser = @{}
    foreach ($event in $events) {
        $user = $null
        $domain = $null

        $user = [string](Get-EventPropertyValue -Event $event -Index 5)
        $domain = [string](Get-EventPropertyValue -Event $event -Index 6)

        if ([string]::IsNullOrWhiteSpace($user) -or $user -eq '-') {
            $user = '<unknown>'
        }

        $principal = if (-not [string]::IsNullOrWhiteSpace($domain) -and $domain -ne '-') {
            "$domain\$user"
        } else {
            $user
        }

        if (-not $countsByUser.ContainsKey($principal)) {
            $countsByUser[$principal] = 0
            $eventsByUser[$principal] = New-Object 'System.Collections.Generic.List[object]'
        }
        $countsByUser[$principal]++
        [void]$eventsByUser[$principal].Add($event)
    }
    Write-Verbose "Collapsed $($events.Count) event(s) into $($countsByUser.Count) user bucket(s)."

    $sortedEntries = @($countsByUser.GetEnumerator() | Sort-Object { $_.Key })
    $sortedEntries = @($sortedEntries | Sort-Object { $_.Value } -Descending)

    $notableFindings = 0
    foreach ($entry in $sortedEntries) {
        Write-Verbose "User '$($entry.Key)' has $($entry.Value) failed login attempt(s) in the last $Hours hour(s)."
        if ($entry.Value -le 2) {
            continue
        }
        $notableFindings++
        $details="$($entry.Value) attempts in the last $Hours hour(s)"
        if ($entry.Value -le 12) {
            Write-Warning "[NOTICE] A few failed login attempts for '$($entry.Key)'`n$details"
        } elseif ($entry.Value -le 24) {
            Write-Warning "[WARNING] Several failed login attempts for '$($entry.Key)'`n$details"
        } else {
            Write-Warning "[FAILURE] Excessive failed login attempts for '$($entry.Key)'`n$details"
        }

        $suspiciousEvents = @(
            $eventsByUser[$entry.Key] |
                Sort-Object {
                    if ($_.TimeCreated -is [datetime]) {
                        $_.TimeCreated.ToUniversalTime()
                    } else {
                        [datetime]::MinValue
                    }
                }
        )
        foreach ($suspiciousEvent in $suspiciousEvents) {
            Write-Output (Format-FailedLogonEventLine -Event $suspiciousEvent -Principal $entry.Key)
        }
    }

    if ($notableFindings -eq 0) {
        Write-Warning "[PASS] No notable failed login attempts found in the last $Hours hour(s)"
    }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-FailedLoginAttemptsRecent
}
