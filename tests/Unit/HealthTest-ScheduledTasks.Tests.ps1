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
        [string]$StartBoundary = '2026-01-01T00:00:00',
        [bool]$Enabled = $true
      )

      ConvertTo-ScheduledTaskTriggerFact -Trigger ([pscustomobject]@{
          TriggerType = 'Time'
          Enabled = $Enabled
          StartBoundary = $StartBoundary
          EndBoundary = ''
          Repetition = $null
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
        LogonType = 'Password'
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
        Actions = @()
        Triggers = @()
        HasEnabledTrigger = $false
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
