Describe 'HealthTest-WmiRepository' {
  BeforeAll {
    . "$PSScriptRoot\..\..\health-tests\HealthTest-WmiRepository.ps1"

    function winmgmt.exe {
      $global:LASTEXITCODE = $script:exitCode
      $script:stdout
    }
  }

  BeforeEach {
    $script:previousExitCode = Get-Variable LASTEXITCODE -Scope Global -ValueOnly -ErrorAction SilentlyContinue
  }

  AfterEach {
    if ($null -eq $script:previousExitCode) {
      Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    } else {
      $global:LASTEXITCODE = $script:previousExitCode
    }
  }

  It 'classifies <Case> using the process exit code' -ForEach @(
    @{ Case = 'English success'; Code = 0; Output = 'WMI repository is consistent'; Level = 'PASS' }
    @{ Case = 'localized success'; Code = 0; Output = 'Le referentiel WMI est coherent'; Level = 'PASS' }
    @{ Case = 'silent success'; Code = 0; Output = ''; Level = 'PASS' }
    @{ Case = 'Win32 corruption'; Code = 1358; Output = 'WMI repository is inconsistent'; Level = 'FAILURE' }
    @{ Case = 'HRESULT corruption'; Code = 0x8007054E; Output = 'WMI repository is not consistent'; Level = 'FAILURE' }
    @{ Case = 'access denied'; Code = 1; Output = 'Access denied'; Level = 'WARNING' }
    @{ Case = 'generic process failure on an inconsistent repository'; Code = 1; Output = 'WMI repository is INCONSISTENT'; Level = 'WARNING' }
    @{ Case = 'unrecognized status'; Code = 23; Output = 'WMI repository is consistent'; Level = 'WARNING' }
    @{ Case = 'silent error'; Code = 1; Output = ''; Level = 'WARNING' }
  ) {
    $script:exitCode = $Code
    $script:stdout = $Output

    $warnings = @(HealthTest-WmiRepository 3>&1)

    $warnings | Should -HaveCount 1
    $warnings[0].Message | Should -Match "^\[$Level\]"
    if ($Code -ne 0) {
      $warnings[0].Message | Should -Match "Exit code: $Code"
      $warnings[0].Message | Should -Match ([regex]::Escape($Output))
    }
  }

  It 'reports command-start errors without using a stale success exit code' {
    $global:LASTEXITCODE = 0
    Mock winmgmt.exe { throw [System.Management.Automation.CommandNotFoundException]::new('winmgmt.exe was not found') }

    $warnings = @(HealthTest-WmiRepository 3>&1)

    $warnings | Should -HaveCount 1
    $warnings[0].Message | Should -Be "[WARNING] Could not start WMI repository verification`nwinmgmt.exe was not found"
  }
}
