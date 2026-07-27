Describe 'Scheduled task fact helpers' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $repoRoot 'health-tests\helper-regarding-scheduled-tasks.ps1')

    function New-TestScheduledTaskFact {
      param(
        [string]$TaskPath = '\Vendor\',
        [string]$TaskName = 'Task',
        [string]$State = 'Ready',
        [bool]$Enabled = $true,
        [bool]$Hidden = $false,
        [string]$Author = 'Vendor',
        [string]$PrincipalUserId = 'CONTOSO\User',
        [string]$RunLevel = 'LeastPrivilege',
        [string]$LogonType = 'Password',
        [object]$DeleteExpiredTaskAfter = $null,
        [object[]]$Actions = @(),
        [object[]]$Triggers = @(),
        [bool]$HasEnabledTrigger = $false,
        [object]$LastRunTime = $null,
        [int]$NumberOfMissedRuns = 0,
        [object]$LastTaskResult = 0,
        [object]$LastResultCode = 0,
        [string]$LastResultHex = '0x00000000',
        [string]$LastResultSeverity = 'Success',
        [string]$LastResultDescription = 'Success (0)',
        [bool]$LastResultIsInformational = $true,
        [bool]$InfoQueryFailed = $false,
        [string]$InfoErrorKind = '',
        [string]$InfoErrorHexCode = '',
        [string]$InfoErrorMessage = '',
        [bool]$XmlQueryFailed = $false,
        [string]$XmlErrorKind = '',
        [string]$XmlErrorHexCode = '',
        [string]$XmlErrorMessage = '',
        [bool]$IsPrivileged = $false,
        [bool]$IsSystemPrincipal = $false,
        [bool]$IsMicrosoftBuiltIn = $false,
        [string]$PolicyFingerprint = ''
      )

      $fact = [pscustomobject]@{
        TaskPath = Normalize-ScheduledTaskPath -TaskPath $TaskPath
        TaskName = $TaskName
        StableKey = Get-ScheduledTaskStableKey -TaskPath $TaskPath -TaskName $TaskName
        State = $State
        Enabled = $Enabled
        Hidden = $Hidden
        Author = $Author
        Description = ''
        PrincipalUserId = $PrincipalUserId
        PrincipalDisplayName = ''
        RunLevel = $RunLevel
        LogonType = $LogonType
        DeleteExpiredTaskAfter = $DeleteExpiredTaskAfter
        Actions = @($Actions)
        Triggers = @($Triggers)
        HasEnabledTrigger = $HasEnabledTrigger
        LastRunTime = $LastRunTime
        NextRunTime = $null
        NumberOfMissedRuns = $NumberOfMissedRuns
        LastTaskResult = $LastTaskResult
        LastResultCode = $LastResultCode
        LastResultHex = $LastResultHex
        LastResultSeverity = $LastResultSeverity
        LastResultDescription = $LastResultDescription
        LastResultIsInformational = $LastResultIsInformational
        InfoQueryFailed = $InfoQueryFailed
        InfoErrorKind = $InfoErrorKind
        InfoErrorHexCode = $InfoErrorHexCode
        InfoErrorMessage = $InfoErrorMessage
        XmlQueryFailed = $XmlQueryFailed
        XmlErrorKind = $XmlErrorKind
        XmlErrorHexCode = $XmlErrorHexCode
        XmlErrorMessage = $XmlErrorMessage
        IsPrivileged = $IsPrivileged
        IsSystemPrincipal = $IsSystemPrincipal
        IsMicrosoftBuiltIn = $IsMicrosoftBuiltIn
        PolicyFingerprint = $PolicyFingerprint
      }

      if ([string]::IsNullOrWhiteSpace($fact.PolicyFingerprint)) {
        $fact.PolicyFingerprint = Get-ScheduledTaskDefinitionFingerprint -Fact $fact
      }

      return $fact
    }

    function New-TestActionFact {
      param(
        [string]$Execute = 'C:\Tools\task.exe',
        [string]$Arguments = '',
        [string]$WorkingDirectory = ''
      )

      ConvertTo-ScheduledTaskActionFact -Action ([pscustomobject]@{
          Execute = $Execute
          Arguments = $Arguments
          WorkingDirectory = $WorkingDirectory
        })
    }

    function New-TestTriggerFact {
      param(
        [string]$Type = 'Time',
        [string]$StartBoundary = '2026-01-01T00:00:00',
        [string]$EndBoundary = '',
        [string]$Interval = '',
        [string]$DaysOfWeek = '',
        [string]$DaysOfMonth = '',
        [string]$MonthsOfYear = '',
        [bool]$Enabled = $true
      )

      $repetition = $null
      if (-not [string]::IsNullOrWhiteSpace($Interval)) {
        $repetition = [pscustomobject]@{
          Interval = $Interval
          Duration = ''
          StopAtDurationEnd = $false
        }
      }

      ConvertTo-ScheduledTaskTriggerFact -Trigger ([pscustomobject]@{
          TriggerType = $Type
          Enabled = $Enabled
          StartBoundary = $StartBoundary
          EndBoundary = $EndBoundary
          Repetition = $repetition
          DaysOfWeek = $DaysOfWeek
          DaysOfMonth = $DaysOfMonth
          MonthsOfYear = $MonthsOfYear
        })
    }
  }

  It 'keeps the stable key and policy fingerprint unchanged when only last run time changes' {
    $action = New-TestActionFact
    $trigger = New-TestTriggerFact

    $old = New-TestScheduledTaskFact -Actions @($action) -Triggers @($trigger) -LastRunTime ([datetime]'2026-01-01')
    $new = New-TestScheduledTaskFact -Actions @($action) -Triggers @($trigger) -LastRunTime ([datetime]'2026-02-01')

    $new.StableKey | Should -Be $old.StableKey
    $new.PolicyFingerprint | Should -Be $old.PolicyFingerprint
  }

  It 'formats typed last and next run times in ISO year-month-day order' {
    $fact = New-TestScheduledTaskFact -LastRunTime ([datetime]'2026-01-09T08:54:23')
    $fact.NextRunTime = [datetime]'2026-02-10T09:55:24'

    $details = Format-ScheduledTaskFactDetails -Fact $fact

    $details | Should -Match '(?m)^Last run time: 2026-01-09 08:54:23$'
    $details | Should -Match '(?m)^Next run time: 2026-02-10 09:55:24$'
  }

  It 'collects DeleteExpiredTaskAfter from scheduled task settings' {
    Reset-ScheduledTaskFactsCache
    Mock Get-ScheduledTask {
      [pscustomobject]@{
        TaskPath = '\'
        TaskName = 'Transient'
        State = 'Ready'
        Author = 'CONTOSO\Administrator'
        Settings = [pscustomobject]@{
          Enabled = $true
          Hidden = $false
          DeleteExpiredTaskAfter = 'PT0S'
        }
        Principal = [pscustomobject]@{
          UserId = 'SYSTEM'
          DisplayName = ''
          RunLevel = 'Highest'
          LogonType = 'ServiceAccount'
        }
        Actions = @()
        Triggers = @()
      }
    }
    Mock Get-ScheduledTaskInfo {
      [pscustomobject]@{
        LastTaskResult = 0
        LastRunTime = $null
        NextRunTime = $null
        NumberOfMissedRuns = 0
      }
    }
    Mock Export-ScheduledTask {
      '<Task><RegistrationInfo><Description>Transient test task</Description></RegistrationInfo></Task>'
    }

    try {
      $facts = @(Get-ScheduledTaskFacts)
    }
    finally {
      Reset-ScheduledTaskFactsCache
    }

    $facts | Should -HaveCount 1
    $facts[0].DeleteExpiredTaskAfter | Should -Be 'PT0S'
  }

  It 'changes the policy fingerprint when the action changes' {
    $old = New-TestScheduledTaskFact -Actions @(New-TestActionFact -Execute 'C:\Tools\old.exe')
    $new = New-TestScheduledTaskFact -Actions @(New-TestActionFact -Execute 'C:\Tools\new.exe')

    $new.PolicyFingerprint | Should -Not -Be $old.PolicyFingerprint
  }

  It 'changes the policy fingerprint when the principal or run level changes' {
    $least = New-TestScheduledTaskFact -PrincipalUserId 'CONTOSO\User' -RunLevel 'LeastPrivilege'
    $highest = New-TestScheduledTaskFact -PrincipalUserId 'CONTOSO\User' -RunLevel 'Highest'
    $system = New-TestScheduledTaskFact -PrincipalUserId 'SYSTEM' -RunLevel 'LeastPrivilege'

    $highest.PolicyFingerprint | Should -Not -Be $least.PolicyFingerprint
    $system.PolicyFingerprint | Should -Not -Be $least.PolicyFingerprint
  }

  It 'changes the policy fingerprint when the trigger changes' {
    $old = New-TestScheduledTaskFact -Triggers @(New-TestTriggerFact -StartBoundary '2026-01-01T00:00:00')
    $new = New-TestScheduledTaskFact -Triggers @(New-TestTriggerFact -StartBoundary '2026-01-02T00:00:00')

    $new.PolicyFingerprint | Should -Not -Be $old.PolicyFingerprint
  }

  It 'classifies short one-shot tasks with immediate or sub-hour deletion as transient' {
    $trigger = New-TestTriggerFact -StartBoundary '2026-07-27T07:08:00' -EndBoundary '2026-07-27T07:13:00'

    foreach ($deleteExpiredTaskAfter in @('PT0S', '00:30:00', 'PT59M')) {
      $fact = New-TestScheduledTaskFact -Triggers @($trigger) -DeleteExpiredTaskAfter $deleteExpiredTaskAfter
      $analysis = Get-ScheduledTaskTransientAnalysis -Fact $fact

      $analysis.IsTransient | Should -BeTrue
      $analysis.HasUnrecognizedDeleteExpiredTaskAfter | Should -BeFalse
    }
  }

  It 'classifies an unrecognized deletion duration as transient but marks it for warning' {
    $trigger = New-TestTriggerFact -StartBoundary '2026-07-27T07:08:00' -EndBoundary '2026-07-27T07:08:55'
    $fact = New-TestScheduledTaskFact -Triggers @($trigger) -DeleteExpiredTaskAfter 'vendor-immediate'

    $analysis = Get-ScheduledTaskTransientAnalysis -Fact $fact

    $analysis.IsTransient | Should -BeTrue
    $analysis.HasUnrecognizedDeleteExpiredTaskAfter | Should -BeTrue
    $analysis.DeleteExpiredTaskAfterText | Should -Be 'vendor-immediate'
  }

  It 'requires every transient-task trigger and deletion criterion' {
    $validTrigger = New-TestTriggerFact -StartBoundary '2026-07-27T07:08:00' -EndBoundary '2026-07-27T07:08:55'
    $invalidFacts = @(
      [pscustomobject]@{
        Name = 'multiple triggers'
        Fact = New-TestScheduledTaskFact -Triggers @($validTrigger, $validTrigger) -DeleteExpiredTaskAfter 'PT0S'
      }
      [pscustomobject]@{
        Name = 'disabled trigger'
        Fact = New-TestScheduledTaskFact -Triggers @(New-TestTriggerFact -Enabled $false -EndBoundary '2026-07-27T07:08:55') -DeleteExpiredTaskAfter 'PT0S'
      }
      [pscustomobject]@{
        Name = 'different trigger type'
        Fact = New-TestScheduledTaskFact -Triggers @(New-TestTriggerFact -Type 'LogonTrigger' -EndBoundary '2026-07-27T07:08:55') -DeleteExpiredTaskAfter 'PT0S'
      }
      [pscustomobject]@{
        Name = 'repeating trigger'
        Fact = New-TestScheduledTaskFact -Triggers @(New-TestTriggerFact -EndBoundary '2026-07-27T07:08:55' -Interval 'PT1M') -DeleteExpiredTaskAfter 'PT0S'
      }
      [pscustomobject]@{
        Name = 'calendar schedule'
        Fact = New-TestScheduledTaskFact -Triggers @(New-TestTriggerFact -EndBoundary '2026-07-27T07:08:55' -DaysOfWeek 'Monday') -DeleteExpiredTaskAfter 'PT0S'
      }
      [pscustomobject]@{
        Name = 'missing start boundary'
        Fact = New-TestScheduledTaskFact -Triggers @(New-TestTriggerFact -StartBoundary '' -EndBoundary '2026-07-27T07:08:55') -DeleteExpiredTaskAfter 'PT0S'
      }
      [pscustomobject]@{
        Name = 'missing end boundary'
        Fact = New-TestScheduledTaskFact -Triggers @(New-TestTriggerFact -StartBoundary '2026-07-27T07:08:00') -DeleteExpiredTaskAfter 'PT0S'
      }
      [pscustomobject]@{
        Name = 'end before start'
        Fact = New-TestScheduledTaskFact -Triggers @(New-TestTriggerFact -StartBoundary '2026-07-27T07:08:00' -EndBoundary '2026-07-27T07:07:59') -DeleteExpiredTaskAfter 'PT0S'
      }
      [pscustomobject]@{
        Name = 'lifetime over five minutes'
        Fact = New-TestScheduledTaskFact -Triggers @(New-TestTriggerFact -StartBoundary '2026-07-27T07:08:00' -EndBoundary '2026-07-27T07:13:01') -DeleteExpiredTaskAfter 'PT0S'
      }
      [pscustomobject]@{
        Name = 'missing deletion setting'
        Fact = New-TestScheduledTaskFact -Triggers @($validTrigger)
      }
      [pscustomobject]@{
        Name = 'negative deletion duration'
        Fact = New-TestScheduledTaskFact -Triggers @($validTrigger) -DeleteExpiredTaskAfter '-PT1S'
      }
      [pscustomobject]@{
        Name = 'one-hour deletion duration'
        Fact = New-TestScheduledTaskFact -Triggers @($validTrigger) -DeleteExpiredTaskAfter 'PT1H'
      }
    )

    foreach ($invalidFact in $invalidFacts) {
      $analysis = Get-ScheduledTaskTransientAnalysis -Fact $invalidFact.Fact
      $analysis.IsTransient | Should -BeFalse -Because $invalidFact.Name
    }
  }

  It 'classifies SYSTEM, service principals, highest run level, and unknown principal as privileged' {
    Test-ScheduledTaskPrincipalPrivileged -PrincipalUserId 'SYSTEM' -RunLevel 'LeastPrivilege' | Should -BeTrue
    Test-ScheduledTaskPrincipalPrivileged -PrincipalUserId 'NT AUTHORITY\LOCAL SERVICE' -RunLevel 'LeastPrivilege' | Should -BeTrue
    Test-ScheduledTaskPrincipalPrivileged -PrincipalUserId 'NETWORK SERVICE' -RunLevel 'LeastPrivilege' | Should -BeTrue
    Test-ScheduledTaskPrincipalPrivileged -PrincipalUserId 'CONTOSO\User' -RunLevel 'Highest' | Should -BeTrue
    Test-ScheduledTaskPrincipalPrivileged -PrincipalUserId '' -RunLevel 'LeastPrivilege' | Should -BeTrue
    Test-ScheduledTaskPrincipalPrivileged -PrincipalUserId 'CONTOSO\User' -RunLevel 'LeastPrivilege' | Should -BeFalse
  }

  It 'treats service-already-running task result as informational' {
    $analysis = Get-ScheduledTaskLastResultAnalysis -RawValue 1056

    $analysis.Hex | Should -Be '0x00000420'
    $analysis.Description | Should -Be 'Service already running'
    $analysis.IsInformational | Should -BeTrue
  }
}

Describe 'HealthTest-ScheduledTasks' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $repoRoot 'health-tests\HealthTest-ScheduledTasks.ps1')

    function New-TestScheduledTaskFact {
      param(
        [string]$TaskPath = '\Vendor\',
        [string]$TaskName = 'Task',
        [string]$State = 'Ready',
        [bool]$Enabled = $true,
        [bool]$Hidden = $false,
        [string]$PrincipalUserId = 'CONTOSO\User',
        [string]$RunLevel = 'LeastPrivilege',
        [string]$LogonType = 'Password',
        [object]$DeleteExpiredTaskAfter = $null,
        [object[]]$Actions = @(),
        [object[]]$Triggers = @(),
        [bool]$HasEnabledTrigger = $false,
        [object]$LastRunTime = $null,
        [int]$NumberOfMissedRuns = 0,
        [object]$LastTaskResult = 0,
        [object]$LastResultCode = 0,
        [string]$LastResultHex = '0x00000000',
        [string]$LastResultSeverity = 'Success',
        [string]$LastResultDescription = 'Success (0)',
        [bool]$LastResultIsInformational = $true,
        [bool]$InfoQueryFailed = $false,
        [string]$InfoErrorKind = '',
        [string]$InfoErrorHexCode = '',
        [string]$InfoErrorMessage = '',
        [bool]$IsPrivileged = $false,
        [bool]$IsSystemPrincipal = $false,
        [bool]$IsMicrosoftBuiltIn = $false,
        [string]$PolicyFingerprint = 'fp'
      )

      [pscustomobject]@{
        TaskPath = Normalize-ScheduledTaskPath -TaskPath $TaskPath
        TaskName = $TaskName
        StableKey = Get-ScheduledTaskStableKey -TaskPath $TaskPath -TaskName $TaskName
        State = $State
        Enabled = $Enabled
        Hidden = $Hidden
        Author = 'Vendor'
        Description = ''
        PrincipalUserId = $PrincipalUserId
        PrincipalDisplayName = ''
        RunLevel = $RunLevel
        LogonType = $LogonType
        DeleteExpiredTaskAfter = $DeleteExpiredTaskAfter
        Actions = @($Actions)
        Triggers = @($Triggers)
        HasEnabledTrigger = $HasEnabledTrigger
        LastRunTime = $LastRunTime
        NextRunTime = $null
        NumberOfMissedRuns = $NumberOfMissedRuns
        LastTaskResult = $LastTaskResult
        LastResultCode = $LastResultCode
        LastResultHex = $LastResultHex
        LastResultSeverity = $LastResultSeverity
        LastResultDescription = $LastResultDescription
        LastResultIsInformational = $LastResultIsInformational
        InfoQueryFailed = $InfoQueryFailed
        InfoErrorKind = $InfoErrorKind
        InfoErrorHexCode = $InfoErrorHexCode
        InfoErrorMessage = $InfoErrorMessage
        XmlQueryFailed = $false
        XmlErrorKind = ''
        XmlErrorHexCode = ''
        XmlErrorMessage = ''
        IsPrivileged = $IsPrivileged
        IsSystemPrincipal = $IsSystemPrincipal
        IsMicrosoftBuiltIn = $IsMicrosoftBuiltIn
        PolicyFingerprint = $PolicyFingerprint
      }
    }
  }

  BeforeEach {
    $script:warnings = @()
    $script:TestScheduledTaskFacts = @()
    Mock Get-ScheduledTaskFacts { return @($script:TestScheduledTaskFacts) }
    Mock Get-ScheduledTaskLoggedOnInteractiveUsers { return @() }
    Mock Write-Warning { $script:warnings += $Message }
  }

  It 'reports a bad last result once' {
    $script:TestScheduledTaskFacts = @(
      New-TestScheduledTaskFact -LastTaskResult 2147942402 -LastResultCode 2147942402 -LastResultHex '0x80070002' -LastResultSeverity 'Error' -LastResultDescription 'File or path not found' -LastResultIsInformational $false
    )

    HealthTest-ScheduledTasks -StaleDays 0

    @($script:warnings | Where-Object { $_ -match 'LastTaskResult=0x80070002' }).Count | Should -Be 1
    @($script:warnings | Where-Object { $_ -match 'terminated with LastTaskResult' }).Count | Should -Be 1
  }

  It 'suppresses standalone Microsoft built-in bad last result by default' {
    $script:TestScheduledTaskFacts = @(
      New-TestScheduledTaskFact -TaskPath '\Microsoft\Windows\AppID\' -TaskName 'SmartScreenSpecific' -LastTaskResult 2147746132 -LastResultCode 2147746132 -LastResultHex '0x80040154' -LastResultSeverity 'Error' -LastResultDescription 'COM class not registered' -LastResultIsInformational $false -IsMicrosoftBuiltIn $true -IsPrivileged $true
    )

    HealthTest-ScheduledTasks -StaleDays 0

    @($script:warnings | Where-Object { $_ -match 'terminated with LastTaskResult' }).Count | Should -Be 0
    @($script:warnings | Where-Object { $_ -match '^\[PASS\]' }).Count | Should -Be 1
  }

  It 'reports Microsoft built-in bad last result when built-ins are explicitly included' {
    $script:TestScheduledTaskFacts = @(
      New-TestScheduledTaskFact -TaskPath '\Microsoft\Windows\AppID\' -TaskName 'SmartScreenSpecific' -LastTaskResult 2147746132 -LastResultCode 2147746132 -LastResultHex '0x80040154' -LastResultSeverity 'Error' -LastResultDescription 'COM class not registered' -LastResultIsInformational $false -IsMicrosoftBuiltIn $true -IsPrivileged $true
    )

    HealthTest-ScheduledTasks -StaleDays 0 -IncludeBuiltIn

    @($script:warnings | Where-Object { $_ -match '^\[FAILURE\] Scheduled task .*LastTaskResult=0x80040154' }).Count | Should -Be 1
  }

  It 'reports a disabled required SYSTEM task as failure' {
    $script:TestScheduledTaskFacts = @(
      New-TestScheduledTaskFact -TaskPath '\Vendor\' -TaskName 'Required' -State 'Disabled' -Enabled $false -PrincipalUserId 'SYSTEM' -IsPrivileged $true -IsSystemPrincipal $true
    )

    HealthTest-ScheduledTasks -MustBeEnabled '\Vendor\Required' -StaleDays 0

    @($script:warnings | Where-Object { $_ -match '^\[FAILURE\] Required SYSTEM scheduled task is disabled: \\Vendor\\Required' }).Count | Should -Be 1
  }

  It 'reports a disabled non-required task at lower severity' {
    $script:TestScheduledTaskFacts = @(
      New-TestScheduledTaskFact -State 'Disabled' -Enabled $false
    )

    HealthTest-ScheduledTasks -StaleDays 0

    @($script:warnings | Where-Object { $_ -match '^\[NOTICE\] Scheduled task is disabled: \\Vendor\\Task' }).Count | Should -Be 1
  }

  It 'reports missed runs and stale task as distinct findings' {
    $script:TestScheduledTaskFacts = @(
      New-TestScheduledTaskFact -HasEnabledTrigger $true -LastRunTime ((Get-Date).AddDays(-60)) -NumberOfMissedRuns 6
    )

    HealthTest-ScheduledTasks -StaleDays 30

    @($script:warnings | Where-Object { $_ -match 'Scheduled task missed 6 runs' }).Count | Should -Be 1
    @($script:warnings | Where-Object { $_ -match 'Scheduled task appears stale' }).Count | Should -Be 1
  }

  It 'reports one missed run as notice' {
    $script:TestScheduledTaskFacts = @(
      New-TestScheduledTaskFact -NumberOfMissedRuns 1
    )

    HealthTest-ScheduledTasks -StaleDays 0

    @($script:warnings | Where-Object { $_ -match '^\[NOTICE\] Scheduled task missed 1 runs: \\Vendor\\Task' }).Count | Should -Be 1
  }

  It 'does not report missed runs for logged-off Interactive and InteractiveToken users' {
    Mock Get-ScheduledTaskLoggedOnInteractiveUsers {
      return @('CONTOSO\OtherUser')
    }

    foreach ($logonType in @('Interactive', 'InteractiveToken')) {
      $script:warnings = @()
      $script:TestScheduledTaskFacts = @(
        New-TestScheduledTaskFact -LogonType $logonType -PrincipalUserId 'CONTOSO\User' -NumberOfMissedRuns 3
      )

      HealthTest-ScheduledTasks -StaleDays 0

      @($script:warnings | Where-Object { $_ -match 'Scheduled task missed' }).Count | Should -Be 0
      @($script:warnings | Where-Object { $_ -match '^\[PASS\] Scheduled tasks healthy$' }).Count | Should -Be 1
    }
  }

  It 'reports missed runs for an Interactive task when its user is logged on' {
    Mock Get-ScheduledTaskLoggedOnInteractiveUsers {
      return @('CONTOSO\User')
    }
    $script:TestScheduledTaskFacts = @(
      New-TestScheduledTaskFact -LogonType 'Interactive' -PrincipalUserId 'CONTOSO\User' -NumberOfMissedRuns 2
    )

    HealthTest-ScheduledTasks -StaleDays 0

    @($script:warnings | Where-Object { $_ -match 'Scheduled task missed 2 runs' }).Count | Should -Be 1
  }

  It 'retains missed-run findings when logged-on-user inspection fails' {
    Mock Get-ScheduledTaskLoggedOnInteractiveUsers {
      throw 'CIM unavailable'
    }
    $script:TestScheduledTaskFacts = @(
      New-TestScheduledTaskFact -LogonType 'InteractiveToken' -PrincipalUserId 'CONTOSO\User' -NumberOfMissedRuns 2
    )

    HealthTest-ScheduledTasks -StaleDays 0

    @($script:warnings | Where-Object { $_ -match 'Scheduled task missed 2 runs' }).Count | Should -Be 1
  }

  It 'still reports stale Interactive tasks when only the missed-run finding is skipped' {
    Mock Get-ScheduledTaskLoggedOnInteractiveUsers {
      return @()
    }
    $script:TestScheduledTaskFacts = @(
      New-TestScheduledTaskFact -LogonType 'Interactive' -PrincipalUserId 'CONTOSO\User' -NumberOfMissedRuns 6 -HasEnabledTrigger $true -LastRunTime ((Get-Date).AddDays(-60))
    )

    HealthTest-ScheduledTasks -StaleDays 30

    @($script:warnings | Where-Object { $_ -match 'Scheduled task missed' }).Count | Should -Be 0
    @($script:warnings | Where-Object { $_ -match 'Scheduled task appears stale' }).Count | Should -Be 1
  }

  It 'does not emit PASS when task-info collection failed' {
    $script:TestScheduledTaskFacts = @(
      New-TestScheduledTaskFact -InfoQueryFailed $true -InfoErrorKind 'QueryFailure' -InfoErrorHexCode '0x80004005' -InfoErrorMessage 'boom'
    )

    HealthTest-ScheduledTasks -StaleDays 0

    @($script:warnings | Where-Object { $_ -match '^\[FAILURE\] Task' }).Count | Should -Be 1
    @($script:warnings | Where-Object { $_ -match '^\[PASS\]' }).Count | Should -Be 0
  }
}

Describe 'HealthTest-ListScheduledTasks' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $repoRoot 'health-tests\HealthTest-ListScheduledTasks.ps1')

    function New-TestScheduledTaskFact {
      param(
        [string]$TaskPath = '\Vendor\',
        [string]$TaskName = 'Task',
        [bool]$IsPrivileged = $false,
        [object[]]$Actions = @(),
        [object[]]$Triggers = @(),
        [object]$DeleteExpiredTaskAfter = $null,
        [string]$PolicyFingerprint = 'fingerprint'
      )

      [pscustomobject]@{
        TaskPath = Normalize-ScheduledTaskPath -TaskPath $TaskPath
        TaskName = $TaskName
        StableKey = Get-ScheduledTaskStableKey -TaskPath $TaskPath -TaskName $TaskName
        State = 'Ready'
        Enabled = $true
        Hidden = $false
        Author = 'Vendor'
        Description = ''
        PrincipalUserId = 'CONTOSO\User'
        PrincipalDisplayName = ''
        RunLevel = 'LeastPrivilege'
        LogonType = 'Password'
        DeleteExpiredTaskAfter = $DeleteExpiredTaskAfter
        Actions = @($Actions)
        Triggers = @($Triggers)
        HasEnabledTrigger = (@($Triggers | Where-Object Enabled).Count -gt 0)
        LastRunTime = $null
        NextRunTime = $null
        NumberOfMissedRuns = 0
        LastTaskResult = 0
        LastResultCode = 0
        LastResultHex = '0x00000000'
        LastResultSeverity = 'Success'
        LastResultDescription = 'Success (0)'
        LastResultIsInformational = $true
        InfoQueryFailed = $false
        InfoErrorKind = ''
        InfoErrorHexCode = ''
        InfoErrorMessage = ''
        XmlQueryFailed = $false
        XmlErrorKind = ''
        XmlErrorHexCode = ''
        XmlErrorMessage = ''
        IsPrivileged = $IsPrivileged
        IsSystemPrincipal = $false
        IsMicrosoftBuiltIn = $false
        PolicyFingerprint = $PolicyFingerprint
      }
    }

    function New-TestListTransientTrigger {
      ConvertTo-ScheduledTaskTriggerFact -Trigger ([pscustomobject]@{
          TriggerType = 'TimeTrigger'
          Enabled = $true
          StartBoundary = '2026-07-27T07:08:00'
          EndBoundary = '2026-07-27T07:08:55'
          Repetition = $null
          DaysOfWeek = ''
          DaysOfMonth = ''
          MonthsOfYear = ''
        })
    }
  }

  BeforeEach {
    $script:warnings = @()
    $script:TestScheduledTaskFacts = @()
    Mock Get-ScheduledTaskFacts { return @($script:TestScheduledTaskFacts) }
    Mock Write-Warning { $script:warnings += $Message }
  }

  It 'emits NOTICE for a non-privileged task definition' {
    $script:TestScheduledTaskFacts = @(New-TestScheduledTaskFact -PolicyFingerprint 'nonpriv')

    HealthTest-ListScheduledTasks

    @($script:warnings | Where-Object { $_ -match '^\[NOTICE\] Found scheduled task: \\Vendor\\Task fingerprint=nonpriv' }).Count | Should -Be 1
  }

  It 'emits WARNING for a privileged task definition' {
    $script:TestScheduledTaskFacts = @(New-TestScheduledTaskFact -IsPrivileged $true -PolicyFingerprint 'priv')

    HealthTest-ListScheduledTasks

    @($script:warnings | Where-Object { $_ -match '^\[WARNING\] Found scheduled task: \\Vendor\\Task fingerprint=priv' }).Count | Should -Be 1
  }

  It 'emits INFO with full details and no fingerprint for a transient task' {
    $action = ConvertTo-ScheduledTaskActionFact -Action ([pscustomobject]@{
        ActionType = 'ExecAction'
        Execute = '\\domain.example\NETLOGON\Deploy.cmd'
        Arguments = '/quiet'
        WorkingDirectory = ''
      })
    $script:TestScheduledTaskFacts = @(
      New-TestScheduledTaskFact -IsPrivileged $true -Actions @($action) -Triggers @(New-TestListTransientTrigger) -DeleteExpiredTaskAfter 'PT30M' -PolicyFingerprint 'volatile-fingerprint'
    )

    HealthTest-ListScheduledTasks

    $script:warnings | Should -HaveCount 1
    $script:warnings[0] | Should -Match '^\[INFO\] Found transient scheduled task: \\Vendor\\Task'
    $script:warnings[0] | Should -Not -Match '(?i)fingerprint'
    $script:warnings[0] | Should -Match '(?m)^Delete expired task after: PT30M$'
    $script:warnings[0] | Should -Match '(?m)^Action: ExecAction Execute=\\\\domain\.example\\NETLOGON\\Deploy\.cmd Arguments=/quiet$'
    $script:warnings[0] | Should -Match '(?m)^Trigger: TimeTrigger Enabled=True Start=2026-07-27T07:08:00 End=2026-07-27T07:08:55$'
  }

  It 'adds a warning when a transient task has an unrecognized deletion duration' {
    $script:TestScheduledTaskFacts = @(
      New-TestScheduledTaskFact -Triggers @(New-TestListTransientTrigger) -DeleteExpiredTaskAfter 'vendor-immediate' -PolicyFingerprint 'volatile-fingerprint'
    )

    HealthTest-ListScheduledTasks

    $script:warnings | Should -HaveCount 2
    @($script:warnings | Where-Object { $_ -match '^\[INFO\] Found transient scheduled task:' }).Count | Should -Be 1
    @($script:warnings | Where-Object { $_ -match '^\[WARNING\] Transient scheduled task has an unrecognized DeleteExpiredTaskAfter value:' }).Count | Should -Be 1
    $script:warnings -join "`n" | Should -Match "DeleteExpiredTaskAfter: 'vendor-immediate'\."
    $script:warnings -join "`n" | Should -Not -Match '(?i)fingerprint'
  }

  It 'keeps an exact one-hour deletion duration as a normal fingerprinted finding' {
    $script:TestScheduledTaskFacts = @(
      New-TestScheduledTaskFact -IsPrivileged $true -Triggers @(New-TestListTransientTrigger) -DeleteExpiredTaskAfter 'PT1H' -PolicyFingerprint 'one-hour'
    )

    HealthTest-ListScheduledTasks

    $script:warnings | Should -HaveCount 1
    $script:warnings[0] | Should -Match '^\[WARNING\] Found scheduled task: \\Vendor\\Task fingerprint=one-hour'
  }

  It 'suppresses known noisy scheduled task definitions' {
    $script:TestScheduledTaskFacts = @(
      New-TestScheduledTaskFact -TaskPath '\' -TaskName 'OneDrive Reporting Task-S-1-5-21-1000'
      New-TestScheduledTaskFact -TaskPath '\' -TaskName 'OneDrive Startup Task-S-1-5-21-1000'
      New-TestScheduledTaskFact -TaskPath '\' -TaskName 'MicrosoftEdgeUpdateTaskMachineCore{BE4EBA8B-9338-4B05-8A78-77E79CAA88B2}'
      New-TestScheduledTaskFact -TaskPath '\' -TaskName 'MicrosoftEdgeUpdateTaskMachineUA{FB1D6D56-FF84-4FA9-A689-8A3A308ED04B}'
      New-TestScheduledTaskFact -TaskPath '\SoftLanding\S-1-5-21-1000\' -TaskName 'SoftLandingDeferralTask'
      New-TestScheduledTaskFact -TaskPath '\Microsoft\Windows\UpdateOrchestrator\' -TaskName 'Schedule Scan'
      New-TestScheduledTaskFact -TaskPath '\Microsoft\Office\' -TaskName 'Office Serviceability Manager'
    )

    HealthTest-ListScheduledTasks

    @($script:warnings | Where-Object { $_ -match 'Found scheduled task' }).Count | Should -Be 0
    @($script:warnings | Where-Object { $_ -match '^\[PASS\] No reportable scheduled tasks discovered\.$' }).Count | Should -Be 1
  }

  It 'continues to report tasks outside the suppression list' {
    $script:TestScheduledTaskFacts = @(
      New-TestScheduledTaskFact -TaskPath '\Microsoft\Other\' -TaskName 'Task'
      New-TestScheduledTaskFact -TaskPath '\Vendor\' -TaskName 'Task'
    )

    HealthTest-ListScheduledTasks

    @($script:warnings | Where-Object { $_ -match 'Found scheduled task: \\Microsoft\\Other\\Task' }).Count | Should -Be 1
    @($script:warnings | Where-Object { $_ -match 'Found scheduled task: \\Vendor\\Task' }).Count | Should -Be 1
  }

  It 'emits a different policy finding when the same task key has a changed action fingerprint' {
    $script:TestScheduledTaskFacts = @(New-TestScheduledTaskFact -PolicyFingerprint 'oldaction')
    HealthTest-ListScheduledTasks
    $oldMessage = $script:warnings[0]

    $script:warnings = @()
    $script:TestScheduledTaskFacts = @(New-TestScheduledTaskFact -PolicyFingerprint 'newaction')
    HealthTest-ListScheduledTasks
    $newMessage = $script:warnings[0]

    $oldMessage | Should -Match '\\Vendor\\Task'
    $newMessage | Should -Match '\\Vendor\\Task'
    $newMessage | Should -Not -Be $oldMessage
  }
}
