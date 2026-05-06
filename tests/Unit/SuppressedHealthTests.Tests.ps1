Describe 'Suppressed health tests' {
  BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:GetComputerHealthScript = Join-Path $script:RepoRoot 'Get-ComputerHealth.ps1'
  }

  It 'returns suppressed NOTICE log objects for the running-process inventory test' {
    $notepad = Start-Process -FilePath 'notepad.exe' -PassThru
    try {
      Start-Sleep -Milliseconds 500
      $expectedMessage = "Process '$($notepad.ProcessName)' is running"

      $records = @(& $script:GetComputerHealthScript `
          -RunWithoutElevation `
          -OutputObjects `
          -OnlyTheseTests HealthTest-RunningProcesses `
          -Hide DIPSNWFC)

      $processRecords = @($records | Where-Object { $_.Emitter -eq 'HealthTest-RunningProcesses' })
      $processRecords.Count | Should -BeGreaterThan 0
      $processRecords | Where-Object { -not $_.Suppressed } | Should -BeNullOrEmpty
      $processRecords | Where-Object { $_.Level -ne 'notice' } | Should -BeNullOrEmpty
      $processRecords.Message | Should -Contain $expectedMessage
    }
    finally {
      if ($notepad -and -not $notepad.HasExited) {
        Stop-Process -Id $notepad.Id -Force -ErrorAction SilentlyContinue
      }
    }
  }

  It 'hides suppressed running-process messages from console output when S is hidden' {
    $notepad = Start-Process -FilePath 'notepad.exe' -PassThru
    try {
      Start-Sleep -Milliseconds 500
      $expectedMessage = "Process '$($notepad.ProcessName)' is running"

      $output = @(
        & $script:GetComputerHealthScript `
          -RunWithoutElevation `
          -OutputConsoleMessages `
          -OnlyTheseTests HealthTest-RunningProcesses `
          -Hide S `
          6>&1 | Where-Object { $_ -is [System.Management.Automation.InformationRecord] -or $_ -is [string] }
      )

      ($output | Out-String) | Should -Not -Match ([regex]::Escape($expectedMessage))
    }
    finally {
      if ($notepad -and -not $notepad.HasExited) {
        Stop-Process -Id $notepad.Id -Force -ErrorAction SilentlyContinue
      }
    }
  }
}
