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

  try {
    $data = & (Join-Path $paths.InstallRoot 'Get-ComputerHealth.ps1') -Hide DIPSNWFC `
      -OutputConsoleMessages -OutputObjects -RunWithoutElevation `
      -ExcludeTests ("HealthTest-LargeDirectories,HealthTest-SoftwareLicensing," + `
                     "HealthTest-ScheduledTasks,HealthTest-ScheduledTasksLastResult,HealthTest-NonMicrosoftServices," + `
                     "HealthTest-UnsignedDrivers,HealthTest-IisBindings")
  } catch {
    $inv = $_.InvocationInfo
    $message = "Get-ComputerHealth.ps1 threw during standalone test: $($_.Exception.Message)"
    if ($inv) {
      $message += "`nFile: $($inv.ScriptName)"
      $message += "`nLine: $($inv.ScriptLineNumber)"
      if ($inv.Line) {
        $message += "`nCode: $($inv.Line.Trim())"
      }
    }
    Fail-Test $message
  }

  $programErrors = @($data | Where-Object { $_.message -like '*program error*' })
  $programErrorsMessage = 'Unexpected program error detection state.'
  if ($programErrors) {
    $formattedErrors = foreach ($err in $programErrors) {
      $parts = @([string]$err.message)
      if ($err.PSObject.Properties.Name -contains 'comment' -and $err.comment) {
        $parts += [string]$err.comment
      }
      if ($err.PSObject.Properties.Name -contains 'details' -and $err.details) {
        $parts += [string]$err.details
      }
      $parts -join [Environment]::NewLine
    }
    $programErrorsMessage = "Program Error(s) in tests:`n$($formattedErrors -join ([Environment]::NewLine + [Environment]::NewLine))"
  }

  Assert-True -Condition ($programErrors.Count -eq 0) -Message $programErrorsMessage

  Assert-True -Condition (($data | Measure-Object).Count -ge 200) -Message "Expected at least 200 messages from GCH -- examine output"
} finally {
  Remove-TestRunRoot -Path $runRoot
}

