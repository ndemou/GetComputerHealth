Describe 'HealthTest-FailedLoginAttemptsRecent' {
  BeforeAll {
    . (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'health-tests\win-os-hyg.ps1')
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

  It 'emits no finding when a user has one or two failed login attempts' {
    Mock Get-WinEvent {
      $events = @()
      1..2 | ForEach-Object {
        $props = for ($i = 0; $i -le 6; $i++) { [pscustomobject]@{ Value = $null } }
        $props[5] = [pscustomobject]@{ Value = 'alice' }
        $props[6] = [pscustomobject]@{ Value = 'CONTOSO' }
        $events += [pscustomobject]@{ Properties = $props }
      }

      @($events)
    }
    Mock Write-Warning {}

    HealthTest-FailedLoginAttemptsRecent

    Should -Invoke Write-Warning -Times 0 -Exactly
  }

  It 'emits NOTICE when a user has between three and twelve failed login attempts' {
    Mock Get-WinEvent {
      $events = @()
      1..12 | ForEach-Object {
        $props = for ($i = 0; $i -le 6; $i++) { [pscustomobject]@{ Value = $null } }
        $props[5] = [pscustomobject]@{ Value = 'alice' }
        $props[6] = [pscustomobject]@{ Value = 'CONTOSO' }
        $events += [pscustomobject]@{ Properties = $props }
      }

      @($events)
    }
    $script:warnings = @()
    Mock Write-Warning { $script:warnings += $Message }

    HealthTest-FailedLoginAttemptsRecent

    $script:warnings | Should -HaveCount 1
    $script:warnings[0] | Should -Be "[NOTICE] A few failed login attempts for 'CONTOSO\alice'`n12 attempts in the last 24 hour(s)"
  }

  It 'emits WARNING when a user has between thirteen and twenty-four failed login attempts' {
    Mock Get-WinEvent {
      $events = @()
      1..24 | ForEach-Object {
        $props = for ($i = 0; $i -le 6; $i++) { [pscustomobject]@{ Value = $null } }
        $props[5] = [pscustomobject]@{ Value = 'bob' }
        $props[6] = [pscustomobject]@{ Value = 'CONTOSO' }
        $events += [pscustomobject]@{ Properties = $props }
      }

      @(
        $events
      )
    }
    $script:warnings = @()
    Mock Write-Warning { $script:warnings += $Message }

    HealthTest-FailedLoginAttemptsRecent

    $script:warnings | Should -HaveCount 1
    $script:warnings[0] | Should -Be "[WARNING] Several failed login attempts for 'CONTOSO\bob'`n24 attempts in the last 24 hour(s)"
  }

  It 'emits FAILURE when a user has twenty-five or more failed login attempts' {
    Mock Get-WinEvent {
      $events = @()
      1..25 | ForEach-Object {
        $props = for ($i = 0; $i -le 6; $i++) { [pscustomobject]@{ Value = $null } }
        $props[5] = [pscustomobject]@{ Value = 'carol' }
        $props[6] = [pscustomobject]@{ Value = 'CONTOSO' }
        $events += [pscustomobject]@{ Properties = $props }
      }

      @(
        $events
      )
    }
    $script:warnings = @()
    Mock Write-Warning { $script:warnings += $Message }

    HealthTest-FailedLoginAttemptsRecent

    $script:warnings | Should -HaveCount 1
    $script:warnings[0] | Should -Be "[FAILURE] Excessive failed login attempts for 'CONTOSO\carol'`n25 attempts in the last 24 hour(s)"
  }
}
