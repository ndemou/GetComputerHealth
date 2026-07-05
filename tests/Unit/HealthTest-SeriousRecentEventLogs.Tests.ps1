Describe 'HealthTest-SeriousRecentEventLogs' {
  BeforeAll {
    . (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'health-tests\HealthTest-SeriousRecentEventLogs.ps1')
  }

  BeforeEach {
    Mock Get-ChildItem { @() }
  }

  It 'emits only one finding when the same event record is returned twice' {
    $event = [pscustomobject]@{
      LogName = 'Application'
      ProviderName = 'Application Error'
      Id = 1000
      RecordId = 12345
      TimeCreated = [datetime]'2026-05-29T08:15:16'
      Message = "Faulting application name: RWRBE60.exe, version: 3.0.0.0, time stamp: 0x412e467d`r`nFaulting module name: example.dll"
    }

    Mock Get-WinEvent {
      param($FilterHashtable)

      if ($FilterHashtable.LogName -eq 'Application' -and $FilterHashtable.Id -eq 1000) {
        return @($event, $event)
      }

      return @()
    }

    $script:warnings = @()
    Mock Write-Warning { $script:warnings += $Message }

    HealthTest-SeriousRecentEventLogs

    $script:warnings | Should -HaveCount 1
    $script:warnings[0] | Should -Be "[notice] Detected application crash in Application log: RWRBE60.exe`nDetected 1 Application Error event for this executable on local date 2026-05-29.`nExact local times:`n- 2026-05-29 08:15:16`nFirst event: 2026-05-29 08:15:16 local time | Application | Application Error | Event ID 1000 | Record ID 12345`nFaulting application name: RWRBE60.exe, version: 3.0.0.0, time stamp: 0x412e467d"
  }

  It 'groups multiple Application Error 1000 records for the same executable on the same day' {
    $message = 'Faulting application name: RWRBE60.exe, version: 3.0.0.0, time stamp: 0x412e467d'
    $events = @(
      [pscustomobject]@{
        LogName = 'Application'
        ProviderName = 'Application Error'
        Id = 1000
        RecordId = 12345
        TimeCreated = [datetime]'2026-05-29T08:15:16'
        Message = $message
      },
      [pscustomobject]@{
        LogName = 'Application'
        ProviderName = 'Application Error'
        Id = 1000
        RecordId = 12346
        TimeCreated = [datetime]'2026-05-29T08:17:42'
        Message = $message
      }
    )

    Mock Get-WinEvent {
      param($FilterHashtable)

      if ($FilterHashtable.LogName -eq 'Application' -and $FilterHashtable.Id -eq 1000) {
        return $events
      }

      return @()
    }

    $script:warnings = @()
    Mock Write-Warning { $script:warnings += $Message }

    HealthTest-SeriousRecentEventLogs

    $script:warnings | Should -HaveCount 1
    $script:warnings[0] | Should -Be "[notice] Detected application crash in Application log: RWRBE60.exe`nDetected 2 Application Error events for this executable on local date 2026-05-29.`nExact local times:`n- 2026-05-29 08:15:16`n- 2026-05-29 08:17:42`nFirst event: 2026-05-29 08:15:16 local time | Application | Application Error | Event ID 1000 | Record ID 12345`nFaulting application name: RWRBE60.exe, version: 3.0.0.0, time stamp: 0x412e467d"
  }

  It 'keeps Application Error 1000 records on different days as separate findings' {
    $message = 'Faulting application name: RWRBE60.exe, version: 3.0.0.0, time stamp: 0x412e467d'
    $events = @(
      [pscustomobject]@{
        LogName = 'Application'
        ProviderName = 'Application Error'
        Id = 1000
        RecordId = 12345
        TimeCreated = [datetime]'2026-05-29T23:59:59'
        Message = $message
      },
      [pscustomobject]@{
        LogName = 'Application'
        ProviderName = 'Application Error'
        Id = 1000
        RecordId = 12346
        TimeCreated = [datetime]'2026-05-30T00:00:01'
        Message = $message
      }
    )

    Mock Get-WinEvent {
      param($FilterHashtable)

      if ($FilterHashtable.LogName -eq 'Application' -and $FilterHashtable.Id -eq 1000) {
        return $events
      }

      return @()
    }

    $script:warnings = @()
    Mock Write-Warning { $script:warnings += $Message }

    HealthTest-SeriousRecentEventLogs

    $script:warnings | Should -HaveCount 2
    $script:warnings[0] | Should -Match 'Detected 1 Application Error event for this executable on local date 2026-05-29\.'
    $script:warnings[0] | Should -Match '2026-05-29 23:59:59'
    $script:warnings[1] | Should -Match 'Detected 1 Application Error event for this executable on local date 2026-05-30\.'
    $script:warnings[1] | Should -Match '2026-05-30 00:00:01'
  }

  It 'reports recent minidumps when no matching crash event was found' {
    $dumpTime = (Get-Date).AddHours(-1)
    $dump = [pscustomobject]@{
      FullName = 'C:\Windows\Minidump\070526-12345-01.dmp'
      LastWriteTime = $dumpTime
    }

    Mock Get-ChildItem { @($dump) }
    Mock Get-WinEvent { @() }

    $script:warnings = @()
    Mock Write-Warning { $script:warnings += $Message }

    HealthTest-SeriousRecentEventLogs -Hours 24

    $script:warnings | Should -HaveCount 1
    $script:warnings[0] | Should -Match '^\[failure\] Recent minidump file\(s\) found without a matching shutdown or bugcheck event'
    $script:warnings[0] | Should -Match '070526-12345-01\.dmp'
  }

  It 'cross-links recent minidumps when a crash event already owns the incident' {
    $event = [pscustomobject]@{
      LogName = 'System'
      ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'
      Id = 1001
      RecordId = 20001
      TimeCreated = [datetime]'2026-07-05T08:15:16'
      Message = 'The computer has rebooted from a bugcheck.'
    }
    $dump = [pscustomobject]@{
      FullName = 'C:\Windows\Minidump\070526-12345-01.dmp'
      LastWriteTime = (Get-Date).AddHours(-1)
    }

    Mock Get-ChildItem { @($dump) }
    Mock Get-WinEvent {
      param($FilterHashtable)

      if ($FilterHashtable.ContainsKey('Id') -and $FilterHashtable.LogName -eq 'System' -and $FilterHashtable.Id -eq 1001) {
        return @($event)
      }

      return @()
    }

    $script:warnings = @()
    Mock Write-Warning { $script:warnings += $Message }

    HealthTest-SeriousRecentEventLogs -Hours 24

    $script:warnings | Should -HaveCount 2
    @($script:warnings | Where-Object { $_ -match '^\[failure\]' }).Count | Should -Be 1
    @($script:warnings | Where-Object { $_ -match '^\[info\] Recent minidump file\(s\) found' }).Count | Should -Be 1
  }
}
