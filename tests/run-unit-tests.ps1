[CmdletBinding()]
param(
  [switch]$Quiet,
  [switch]$Detailed
)

Set-StrictMode -Version Latest

$pesterModule = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $pesterModule) {
  throw "Pester is required to run unit tests. Install it in Windows PowerShell 5.1 and retry."
}

if ($pesterModule.Version.Major -lt 5) {
  throw "Pester 5 or newer is required to run unit tests. Found version $($pesterModule.Version). Install a newer Pester module and retry."
}

Import-Module $pesterModule.Path -Force

$invokeParams = @{
  Script = (Join-Path $PSScriptRoot 'Unit')
  PassThru = $true
}

if ($Quiet) {
  $invokeParams['Quiet'] = $true
}

if ($Detailed) {
  $invokeParams['Output'] = 'Detailed'
}

$result = Invoke-Pester @invokeParams
if ($null -eq $result) {
  throw "Invoke-Pester did not return a result object."
}


if ($result.FailedCount -gt 0) {
  $failedTests = @($result.Failed)
  if ($failedTests.Count -gt 0) {
    Write-Host "Failed tests:" -ForegroundColor Red
    $failedTests | ForEach-Object {
      $name = $_.ExpandedPath
      if ([string]::IsNullOrWhiteSpace($name)) {
        $name = $_.Name
      }

      $err = ''
      if ($_.ErrorRecord -and $_.ErrorRecord.Exception) {
        $err = $_.ErrorRecord.Exception.Message
      }
      elseif ($_.FailureMessage) {
        $err = $_.FailureMessage
      }

      if ([string]::IsNullOrWhiteSpace($err)) {
        Write-Host " - $name" -ForegroundColor Red
      }
      else {
        Write-Host " - $name`n   $err" -ForegroundColor Red
      }
    }
  }

  throw "Pester unit tests failed. Passed: $($result.PassedCount). Failed: $($result.FailedCount)."
}

Write-Host "Pester unit test summary: $($result.PassedCount) passed, $($result.FailedCount) failed." -ForegroundColor Green
