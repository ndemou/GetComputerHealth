Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'test-helpers.ps1')

$runRoot = New-TestRunRoot -Name 'gch-main'
$paths = Get-TestPaths -RepoRoot (Split-Path -Parent $PSScriptRoot) -RunRoot $runRoot

try {
  Assert-CommandAvailable 'robocopy'
  Assert-PathExists -Path $paths.MainScriptSource -Message "Missing main script under test: $($paths.MainScriptSource)"
  Assert-DirectoryWritable -Path $paths.InstallRoot
  Assert-DirectoryWritable -Path $paths.ConfigRoot

  Set-Content -LiteralPath $paths.SuppressionsFile -Value '' -NoNewline

  Invoke-RobocopyChecked -Source $paths.RepoRoot -Destination $paths.InstallRoot -ExcludeDirectories @('.git')

  $data = & (Join-Path $paths.InstallRoot 'Get-ComputerHealth.ps1') -Hide DIPSNWFC `
    -OutputConsoleMessages -OutputObjects -RunWithoutElevation `
    -ExcludeTests ("HealthTest-LargeDirectories,HealthTest-SoftwareLicensing," + `
                   "HealthTest-ScheduledTasks,HealthTest-NonMicrosoftServices," + `
                   "HealthTest-UnsignedDrivers")

  $programErrors = $data | Where-Object { $_.message -like '*program error*' }
  $programErrorsMessage = 'Unexpected program error detection state.'
  if ($programErrors) {
    $programErrorsMessage = "Program Error(s) in tests:`n$($programErrors.message -join [Environment]::NewLine)"
  }

  Assert-True -Condition ($null -eq $programErrors) -Message $programErrorsMessage

  Assert-True -Condition (($data | Measure-Object).Count -ge 200) -Message "Expected at least 200 messages from GCH -- examine output"
} finally {
  Remove-TestRunRoot -Path $runRoot
}

