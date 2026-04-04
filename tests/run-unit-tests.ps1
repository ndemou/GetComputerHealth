[CmdletBinding()]
param(
  [switch]$Quiet
)

Set-StrictMode -Version Latest

$pesterModule = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $pesterModule) {
  throw "Pester is required to run unit tests. Install it in Windows PowerShell 5.1 and retry."
}

Import-Module $pesterModule.Path -Force

$invokeParams = @{
  Script = (Join-Path $PSScriptRoot 'Unit')
  PassThru = $true
}

if ($Quiet) {
  $invokeParams['Quiet'] = $true
}

$result = Invoke-Pester @invokeParams
if ($null -eq $result) {
  throw "Invoke-Pester did not return a result object."
}

if ($result.FailedCount -gt 0) {
  throw "Pester unit tests failed. Passed: $($result.PassedCount). Failed: $($result.FailedCount)."
}

Write-Host "Pester unit test summary: $($result.PassedCount) passed, $($result.FailedCount) failed." -ForegroundColor Green
