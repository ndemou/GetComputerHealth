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

  It 'emits NOTICE when a user has three or fewer failed login attempts' {
    Mock Get-WinEvent {
      $props1 = for ($i = 0; $i -le 6; $i++) { [pscustomobject]@{ Value = $null } }
      $props1[5] = [pscustomobject]@{ Value = 'alice' }
      $props1[6] = [pscustomobject]@{ Value = 'CONTOSO' }
      $props2 = for ($i = 0; $i -le 6; $i++) { [pscustomobject]@{ Value = $null } }
      $props2[5] = [pscustomobject]@{ Value = 'alice' }
      $props2[6] = [pscustomobject]@{ Value = 'CONTOSO' }
      $props3 = for ($i = 0; $i -le 6; $i++) { [pscustomobject]@{ Value = $null } }
      $props3[5] = [pscustomobject]@{ Value = 'alice' }
      $props3[6] = [pscustomobject]@{ Value = 'CONTOSO' }

      @(
        [pscustomobject]@{ Properties = $props1 },
        [pscustomobject]@{ Properties = $props2 },
        [pscustomobject]@{ Properties = $props3 }
      )
    }
    $script:warnings = @()
    Mock Write-Warning { $script:warnings += $Message }

    HealthTest-FailedLoginAttemptsRecent

    $script:warnings | Should -HaveCount 1
    $script:warnings[0] | Should -Be "[NOTICE] <=3 failed login attempts for 'CONTOSO\alice'`n3 attempts in the last 24 hour(s)"
  }

  It 'emits WARNING when a user has up to six failed login attempts' {
    Mock Get-WinEvent {
      $events = @()
      1..6 | ForEach-Object {
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
    $script:warnings[0] | Should -Be "[WARNING] <=6 failed login attempts for 'CONTOSO\bob'`n6 attempts in the last 24 hour(s)"
  }

  It 'emits FAILURE when a user has seven or more failed login attempts' {
    Mock Get-WinEvent {
      $events = @()
      1..7 | ForEach-Object {
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
    $script:warnings[0] | Should -Be "[FAILURE] >=7 failed login attempts for 'CONTOSO\carol'`n7 attempts in the last 24 hour(s)"
  }
}
