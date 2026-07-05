Describe 'HealthTest-ListShares' {
  BeforeAll {
    . (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'health-tests\HealthTest-ListShares.ps1')
  }

  It 'reports default shares instead of filtering them out' {
    Mock Get-CimInstance {
      @(
        [pscustomobject]@{
          Name = 'C$'
          Path = 'C:\'
          Type = 2147483648
          Description = 'Default share'
        }
        [pscustomobject]@{
          Name = 'ADMIN$'
          Path = 'C:\Windows'
          Type = 2147483648
          Description = 'Remote Admin'
        }
      )
    } -ParameterFilter { $ClassName -eq 'Win32_Share' }

    Mock Write-Warning {}

    HealthTest-ListShares

    Should -Invoke Write-Warning -Times 1 -ParameterFilter {
      $Message -match "^\[WARNING\] Found SMB share: C[$] fingerprint=[0-9a-f]{16}" -and
      $Message -match "Path: C:\\"
    }
    Should -Invoke Write-Warning -Times 1 -ParameterFilter {
      $Message -match "^\[WARNING\] Found SMB share: ADMIN[$] fingerprint=[0-9a-f]{16}" -and
      $Message -match "Path: C:\\Windows"
    }
  }

  It 'does not emit FAILURE when shares are found' {
    Mock Get-CimInstance {
      @(
        [pscustomobject]@{
          Name = 'Docs'
          Path = 'D:\Docs'
          Type = 0
          Description = 'Docs'
        }
      )
    } -ParameterFilter { $ClassName -eq 'Win32_Share' }

    Mock Write-Warning {}

    HealthTest-ListShares

    Should -Invoke Write-Warning -Times 0 -ParameterFilter {
      $Message -like '[FAILURE]*'
    }
    Should -Invoke Write-Warning -Times 1 -ParameterFilter {
      $Message -match "^\[WARNING\] Found SMB share: Docs fingerprint=[0-9a-f]{16}" -and
      $Message -match "Path: D:\\Docs"
    }
  }

  It 'keeps file and print sharing hygiene out of the list test' {
    Mock Get-CimInstance {
      @()
    } -ParameterFilter { $ClassName -eq 'Win32_Share' }

    Mock Write-Warning {}

    HealthTest-ListShares

    Should -Invoke Write-Warning -Times 1 -ParameterFilter {
      $Message -eq "[PASS] No SMB shares discovered."
    }
  }
}

Describe 'HealthTest-Shares' {
  BeforeAll {
    . (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'health-tests\HealthTest-Shares.ps1')
  }

  It 'reports hygiene warning when file and print sharing is enabled on a server with no shares' {
    Mock Get-CimInstance {
      [pscustomobject]@{
        DomainRole = 3
      }
    } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }

    Mock Get-CimInstance {
      @()
    } -ParameterFilter { $ClassName -eq 'Win32_Share' }

    Mock Get-Service {
      [pscustomobject]@{
        Status = 'Running'
        StartType = 'Automatic'
      }
    } -ParameterFilter { $Name -eq 'LanmanServer' }

    Mock Write-Warning {}

    HealthTest-Shares

    Should -Invoke Write-Warning -Times 1 -ParameterFilter {
      $Message -match '^\[WARNING\] File and print sharing is enabled but no SMB shares were discovered'
    }
  }
}
