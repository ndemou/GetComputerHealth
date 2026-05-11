Describe 'Suppressed health tests' {
  BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:GetComputerHealthScript = Join-Path $script:RepoRoot 'Get-ComputerHealth.ps1'
    . (Join-Path $script:RepoRoot 'health-tests\win-os-hyg.ps1')
  }

  It 'includes the process owner in running-process inventory messages' {
    $processName = (Get-Process -Id $PID -ErrorAction Stop).ProcessName
    $expectedMessagePattern = "^\[NOTICE\] Process '$([regex]::Escape($processName))' is running as '.+'$"
    $script:warnings = @()
    Mock Write-Warning { $script:warnings += $Message }

    HealthTest-RunningProcesses

    @($script:warnings | Where-Object { $_ -match $expectedMessagePattern }).Count | Should -BeGreaterThan 0
  }

  It 'hides suppressed running-process messages from console output when S is hidden' {
    $processName = (Get-Process -Id $PID -ErrorAction Stop).ProcessName
    $expectedMessagePrefix = "Process '$processName' is running as '"

    $output = @(
      & $script:GetComputerHealthScript `
        -RunWithoutElevation `
        -OutputConsoleMessages `
        -OnlyTheseTests HealthTest-RunningProcesses `
        -Hide S `
        6>&1 | Where-Object { $_ -is [System.Management.Automation.InformationRecord] -or $_ -is [string] }
    )

    ($output | Out-String) | Should -Not -Match ([regex]::Escape($expectedMessagePrefix))
  }
}
