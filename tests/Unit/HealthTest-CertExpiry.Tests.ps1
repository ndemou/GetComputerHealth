Describe 'HealthTest-CertExpiry' {
  BeforeAll {
    . (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'health-tests\HealthTest-CertExpiry.ps1')
  }

  BeforeEach {
    $script:warnings = @()
    Mock Write-Warning { $script:warnings += $Message }
  }

  It 'reports expiring certificates at their intended levels instead of passing' {
    Mock Get-ChildItem {
      @(
        [pscustomobject]@{ Subject = 'CN=Expired'; NotAfter = (Get-Date).AddDays(-10) },
        [pscustomobject]@{ Subject = 'CN=Expiring'; NotAfter = (Get-Date).AddDays(45) }
      )
    }

    HealthTest-CertExpiry

    @($script:warnings | Where-Object { $_ -match '(?s)^\[FAILURE\].*CN=Expired' }).Count | Should -Be 1
    @($script:warnings | Where-Object { $_ -match '(?s)^\[WARNING\].*CN=Expiring' }).Count | Should -Be 1
    @($script:warnings | Where-Object { $_ -match '^\[PASS\]' }).Count | Should -Be 0
  }

  It 'passes when all certificates are outside the warning window' {
    Mock Get-ChildItem {
      @([pscustomobject]@{ Subject = 'CN=Healthy'; NotAfter = (Get-Date).AddDays(90) })
    }

    HealthTest-CertExpiry

    $script:warnings | Should -HaveCount 1
    $script:warnings[0] | Should -Match '^\[PASS\]'
  }
}
