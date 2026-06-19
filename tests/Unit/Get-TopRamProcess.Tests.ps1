Describe 'Get-TopRamProcess' {
  BeforeAll {
    . (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'health-tests\os-perf-hw.ps1')
  }

  BeforeEach {
    $script:warnings = @()
    $script:verboseMessages = @()

    Mock Get-CimInstance {
      [pscustomobject]@{
        TotalVisibleMemorySize = 1024 * 1024
        FreePhysicalMemory = 0
      }
    } -ParameterFilter {
      $ClassName -eq 'Win32_OperatingSystem'
    }

    Mock Write-Warning {
      $script:warnings += $Message
    }

    Mock Write-Verbose {
      $script:verboseMessages += $Message
    }
  }

  It 'includes a synthetic [non-process] entry based on used RAM minus summed process working sets' {
    Mock Get-Process {
      $alpha = [pscustomobject]@{
        Id = 101
        ProcessName = 'alpha'
        WorkingSet64 = 200MB
      }
      $beta = [pscustomobject]@{
        Id = 202
        ProcessName = 'beta'
        WorkingSet64 = 100MB
      }

      $alpha | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
      $beta | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}

      @($alpha, $beta)
    }

    $result = @(Get-TopRamProcess -MinProcesses 1 -MaxProcesses 10 -TargetPercentOfUsedRam 100)

    $result | Should -HaveCount 3
    $result[0].PID | Should -Be -1
    $result[0].Name | Should -Be '[non-process]'
    $result[0].RAM_MB | Should -Be 724
    $result[0].RAM_PercentOfUsed | Should -Be 70.7
    $result[0].CumulativeUsedRAMPct | Should -Be 70.7
    $result[1].Name | Should -Be 'alpha'
    $result[2].Name | Should -Be 'beta'
    $script:warnings.Count | Should -Be 0
  }

  It 'writes a verbose message when MaxProcesses prevents reaching the target even with [non-process] included' {
    Mock Get-Process {
      $alpha = [pscustomobject]@{
        Id = 101
        ProcessName = 'alpha'
        WorkingSet64 = 600MB
      }
      $beta = [pscustomobject]@{
        Id = 202
        ProcessName = 'beta'
        WorkingSet64 = 200MB
      }
      $gamma = [pscustomobject]@{
        Id = 303
        ProcessName = 'gamma'
        WorkingSet64 = 100MB
      }

      $alpha | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
      $beta | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
      $gamma | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}

      @($alpha, $beta, $gamma)
    }

    $result = @(Get-TopRamProcess -MinProcesses 1 -MaxProcesses 2 -TargetPercentOfUsedRam 100)

    $result | Should -HaveCount 2
    $result[0].Name | Should -Be 'alpha'
    $result[1].Name | Should -Be 'beta'
    $script:warnings.Count | Should -Be 0
    $script:verboseMessages | Should -HaveCount 1
    $script:verboseMessages[0] | Should -Be 'The approximate target was not reached. Returned 2 entries, covering 78.1% of used RAM by measured RAM usage. MaxProcesses may be the cause.'
  }
}
