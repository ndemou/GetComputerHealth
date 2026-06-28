Describe 'HealthTest-FailedLoginAttemptsRecent' {
  BeforeAll {
    . (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'health-tests\win-os-hyg.ps1')
    $script:NewFailedLogonEvent = {
      param(
        [string]$User,
        [string]$Domain,
        [datetime]$TimeCreated = [datetime]'2026-06-21T10:00:00Z',
        [string]$Status = '0xC000006D',
        [string]$SubStatus = '0xC000006A',
        [string]$LogonType = '3',
        [string]$LogonProcessName = 'NtLmSsp',
        [string]$WorkstationName = 'WS01',
        [string]$ProcessName = 'C:\Windows\System32\services.exe',
        [string]$IpAddress = '10.0.0.25',
        [string]$IpPort = '51123'
      )

      $props = for ($i = 0; $i -le 20; $i++) { [pscustomobject]@{ Value = $null } }
      $props[5] = [pscustomobject]@{ Value = $User }
      $props[6] = [pscustomobject]@{ Value = $Domain }
      $props[7] = [pscustomobject]@{ Value = $Status }
      $props[9] = [pscustomobject]@{ Value = $SubStatus }
      $props[10] = [pscustomobject]@{ Value = $LogonType }
      $props[11] = [pscustomobject]@{ Value = $LogonProcessName }
      $props[13] = [pscustomobject]@{ Value = $WorkstationName }
      $props[18] = [pscustomobject]@{ Value = $ProcessName }
      $props[19] = [pscustomobject]@{ Value = $IpAddress }
      $props[20] = [pscustomobject]@{ Value = $IpPort }

      [pscustomobject]@{
        Properties = $props
        TimeCreated = $TimeCreated
      }
    }
  }

  It 'emits PASS when no failed login attempts are found' {
    Mock Get-WinEvent { @() }
    Mock Write-Warning {}

    HealthTest-FailedLoginAttemptsRecent

    Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
      $Message -eq "[PASS] No failed login attempts found in the last 24 hour(s)"
    }
  }

  It 'treats the Get-WinEvent no-events exception as PASS' {
    Mock Get-WinEvent { throw 'No events were found that match the specified selection criteria.' }
    Mock Write-Warning {}

    HealthTest-FailedLoginAttemptsRecent

    Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
      $Message -eq "[PASS] No failed login attempts found in the last 24 hour(s)"
    }
  }

  It 'emits PASS when only one or two failed login attempts exist per user' {
    $script:events = @(
      (& $script:NewFailedLogonEvent -User 'alice' -Domain 'CONTOSO'),
      (& $script:NewFailedLogonEvent -User 'alice' -Domain 'CONTOSO')
    )
    Mock Get-WinEvent { $script:events }
    Mock Write-Warning {}

    HealthTest-FailedLoginAttemptsRecent

    Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
      $Message -eq "[PASS] No notable failed login attempts found in the last 24 hour(s)"
    }
  }

  It 'emits NOTICE when a user has between three and twelve failed login attempts' {
    $script:events = @(1..12 | ForEach-Object {
        & $script:NewFailedLogonEvent -User 'alice' -Domain 'CONTOSO'
    })
    Mock Get-WinEvent { $script:events }
    $script:warnings = @()
    Mock Write-Warning { $script:warnings += $Message }

    HealthTest-FailedLoginAttemptsRecent

    $script:warnings | Should -HaveCount 1
    $script:warnings[0] | Should -Be "[NOTICE] A few failed login attempts for 'CONTOSO\alice'`n12 attempts in the last 24 hour(s)"
  }

  It 'emits WARNING when a user has between thirteen and twenty-four failed login attempts' {
    $script:events = @(1..24 | ForEach-Object {
        & $script:NewFailedLogonEvent -User 'bob' -Domain 'CONTOSO'
    })
    Mock Get-WinEvent { $script:events }
    $script:warnings = @()
    Mock Write-Warning { $script:warnings += $Message }

    HealthTest-FailedLoginAttemptsRecent

    $script:warnings | Should -HaveCount 1
    $script:warnings[0] | Should -Be "[WARNING] Several failed login attempts for 'CONTOSO\bob'`n24 attempts in the last 24 hour(s)"
  }

  It 'emits FAILURE when a user has twenty-five or more failed login attempts' {
    $script:events = @(1..25 | ForEach-Object {
        & $script:NewFailedLogonEvent -User 'carol' -Domain 'CONTOSO'
    })
    Mock Get-WinEvent { $script:events }
    $script:warnings = @()
    Mock Write-Warning { $script:warnings += $Message }

    HealthTest-FailedLoginAttemptsRecent

    $script:warnings | Should -HaveCount 1
    $script:warnings[0] | Should -Be "[FAILURE] Excessive failed login attempts for 'CONTOSO\carol'`n25 attempts in the last 24 hour(s)"
  }

  It 'writes readable suspicious events to the output stream for notable principals' {
    $script:events = @(
      (& $script:NewFailedLogonEvent -User 'carol' -Domain 'CONTOSO' -TimeCreated ([datetime]'2026-06-21T08:15:00Z') -LogonType '5' -ProcessName 'C:\Windows\System32\services.exe' -WorkstationName '-' -IpAddress '-' -IpPort '-' -SubStatus '0xC000006A'),
      (& $script:NewFailedLogonEvent -User 'carol' -Domain 'CONTOSO' -TimeCreated ([datetime]'2026-06-21T08:16:00Z') -LogonType '3' -ProcessName 'C:\Windows\explorer.exe' -WorkstationName 'FS01' -IpAddress '10.0.0.44' -IpPort '445' -SubStatus '0xC000006A'),
      (& $script:NewFailedLogonEvent -User 'carol' -Domain 'CONTOSO' -TimeCreated ([datetime]'2026-06-21T08:17:00Z') -LogonType '10' -ProcessName 'C:\Windows\System32\winlogon.exe' -WorkstationName 'ADMINPC' -IpAddress '10.0.0.50' -IpPort '3389' -SubStatus '0xC0000234')
    ) + @(1..22 | ForEach-Object {
        & $script:NewFailedLogonEvent -User 'carol' -Domain 'CONTOSO' -TimeCreated ([datetime]'2026-06-21T08:17:00Z').AddMinutes($_)
    })
    Mock Get-WinEvent { $script:events }
    Mock Write-Warning {}

    $result = @(HealthTest-FailedLoginAttemptsRecent)
    $expectedFirstTime = ([datetime]'2026-06-21T08:15:00Z').ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
    $expectedSecondTime = ([datetime]'2026-06-21T08:16:00Z').ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
    $expectedThirdTime = ([datetime]'2026-06-21T08:17:00Z').ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')

    $result | Should -HaveCount 25
    $result[0] | Should -Match ("^{0} principal='CONTOSO\\carol' logonType=Service " -f [regex]::Escape($expectedFirstTime))
    $result[0] | Should -Match "hint='Likely a service using stale credentials\.'$"
    $result[1] | Should -Match ("^{0} principal='CONTOSO\\carol' logonType=Network " -f [regex]::Escape($expectedSecondTime))
    $result[1] | Should -Match "hint='Possibly a mapped drive or Explorer-triggered network access using stale credentials\.'$"
    $result[2] | Should -Match ("^{0} principal='CONTOSO\\carol' logonType=RemoteInteractive " -f [regex]::Escape($expectedThirdTime))
    $result[2] | Should -Match "hint='Likely an RDP sign-in attempt from another machine\.'$"
  }
}
