Describe 'DCDIAG output compression' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $repoRoot 'health-tests\helpers-for-healthtests.ps1')
    . (Join-Path $repoRoot 'health-tests\OnlyIfHostIs-DC.ps1')
  }

  It 'compresses repeated DCDIAG diagnostic sentences' {
    $line = 'Windows failed to apply the MDM Policy settings. MDM Policy settings might have its own log file. Windows failed to apply the MDM Policy settings. MDM Policy settings might have its own log file. An error event occurred. EventID: 0x80000013'

    $result = Get-CompressedDcDiagInterestingLines -Lines @($line)

    $result | Should -Be "Windows failed to apply the MDM Policy settings.`nMDM Policy settings might have its own log file.`nAn error event occurred.`nEventID: 0x80000013"
  }

  It 'uses compressed DCDIAG output in Dcdiag warnings' {
    $blockText = @'
      Starting test: SystemLog
         Windows failed to apply the MDM Policy settings. MDM Policy settings might have its own log file. Windows failed to apply the MDM Policy settings. MDM Policy settings might have its own log file. An error event occurred. EventID: 0x80000013
      ......................... DC01 failed test SystemLog
'@

    Mock Get-DcDiagFailures {
      [pscustomobject]@{
        Test = 'SystemLog'
        FailureLine = '......................... DC01 failed test SystemLog'
        BlockText = $blockText
      }
    } -ParameterFilter { $Comprehensive }

    Mock Get-DcDiagFailures {
      [pscustomobject]@{
        Test = 'SystemLog'
        FailureLine = '......................... DC01 failed test SystemLog'
        BlockText = $blockText
      }
    } -ParameterFilter { -not $Comprehensive }

    Mock Write-Warning {}

    HealthTest-Dcdiag

    Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
      $Message -match 'Windows failed to apply the MDM Policy settings\.' -and
      $Message -match 'MDM Policy settings might have its own log file\.' -and
      ($Message -split 'Windows failed to apply the MDM Policy settings\.').Count -eq 2
    }
  }

  It 'uses compressed DCDIAG output for RID Manager findings in Dcdiag warnings' {
    $blockText = @'
      Starting test: RidManager
         RID pool is low. RID pool is low. DC01 failed test RidManager
      ......................... DC01 failed test RidManager
'@

    Mock Get-DcDiagFailures {
      [pscustomobject]@{
        Test = 'RidManager'
        FailureLine = '......................... DC01 failed test RidManager'
        BlockText = $blockText
      }
    } -ParameterFilter { $Comprehensive }

    Mock Get-DcDiagFailures {
      [pscustomobject]@{
        Test = 'RidManager'
        FailureLine = '......................... DC01 failed test RidManager'
        BlockText = $blockText
      }
    } -ParameterFilter { -not $Comprehensive }

    Mock Write-Warning {}

    HealthTest-Dcdiag

    Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
      $Message -match 'RID pool is low\.' -and
      $Message -match 'DC01 failed test RidManager' -and
      ($Message -split 'RID pool is low\.').Count -eq 2
    }
  }
}
