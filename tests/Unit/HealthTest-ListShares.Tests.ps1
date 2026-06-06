Describe 'HealthTest-ListShares' {
  BeforeAll {
    . (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'health-tests\win-os-hyg.ps1')
  }

  It 'reports default shares instead of filtering them out' {
    Mock Get-CimInstance {
      [pscustomobject]@{
        DomainRole = 3
      }
    } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }

    Mock Get-CimInstance {
      @(
        [pscustomobject]@{
          Name = 'C$'
          Path = 'C:\'
        }
        [pscustomobject]@{
          Name = 'ADMIN$'
          Path = 'C:\Windows'
        }
      )
    } -ParameterFilter { $ClassName -eq 'Win32_Share' }

    Mock Get-Service {
      [pscustomobject]@{
        Status = 'Running'
        StartType = 'Automatic'
      }
    } -ParameterFilter { $Name -eq 'LanmanServer' }

    Mock Write-Warning {}
    Mock Write-Output {}

    HealthTest-ListShares

    Should -Invoke Write-Warning -Times 1 -ParameterFilter {
      $Message -eq "[WARNING] Found a share named 'C$' that shares 'C:\'"
    }
    Should -Invoke Write-Warning -Times 1 -ParameterFilter {
      $Message -eq "[WARNING] Found a share named 'ADMIN$' that shares 'C:\Windows'"
    }
  }

  It 'does not emit FAILURE when shares are found' {
    Mock Get-CimInstance {
      [pscustomobject]@{
        DomainRole = 1
      }
    } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }

    Mock Get-CimInstance {
      @(
        [pscustomobject]@{
          Name = 'Docs'
          Path = 'D:\Docs'
        }
      )
    } -ParameterFilter { $ClassName -eq 'Win32_Share' }

    Mock Get-Service {
      [pscustomobject]@{
        Status = 'Running'
        StartType = 'Automatic'
      }
    } -ParameterFilter { $Name -eq 'LanmanServer' }

    Mock Write-Warning {}
    Mock Write-Output {}

    HealthTest-ListShares

    Should -Invoke Write-Warning -Times 0 -ParameterFilter {
      $Message -like '[FAILURE]*'
    }
    Should -Invoke Write-Warning -Times 1 -ParameterFilter {
      $Message -eq "[WARNING] Found a share named 'Docs' that shares 'D:\Docs'"
    }
  }
}
