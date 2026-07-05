[CmdletBinding()]
param(
  [ValidateSet('All', 'Unit', 'Integration')]
  [string]$Category = 'All',
  [switch]$Detailed,
  [switch]$Smoke
)

if (-not $PSScriptRoot) {
  throw "PSScriptRoot is not available."
}

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'health-tests\helper-regarding-service-and-executable-resolution.ps1')

$script:ArtifactsRoot = Join-Path $PSScriptRoot 'artifacts\last-run'

function Initialize-TestArtifacts {
  if (Test-Path -LiteralPath $script:ArtifactsRoot) {
    Remove-Item -LiteralPath $script:ArtifactsRoot -Recurse -Force -ErrorAction SilentlyContinue
  }

  New-Item -ItemType Directory -Path $script:ArtifactsRoot -Force | Out-Null
}

function Write-TestArtifact {
  param(
    [Parameter(Mandatory)]
    [string]$Name,
    [Parameter(Mandatory)]
    [string]$Content
  )

  $safeName = ($Name -replace '[^A-Za-z0-9._-]', '_')
  $artifactPath = Join-Path $script:ArtifactsRoot ($safeName + '.log')
  Set-Content -LiteralPath $artifactPath -Value $Content
  return $artifactPath
}

function New-TestGroupResult {
  param(
    [Parameter(Mandatory)]
    [string]$Name,
    [Parameter(Mandatory)]
    [string]$Category,
    [Parameter(Mandatory)]
    [bool]$Passed,
    [string]$Detail = ''
  )

  [pscustomobject]@{
    Name = $Name
    Category = $Category
    Passed = $Passed
    Detail = $Detail
  }
}

function Should-RunCategory {
  param(
    [Parameter(Mandatory)]
    [string]$RequestedCategory,
    [Parameter(Mandatory)]
    [string]$TestCategory
  )

  return $RequestedCategory -eq 'All' -or $RequestedCategory -eq $TestCategory
}

function Get-TestSelection {
  param(
    [Parameter(Mandatory)]
    [string]$Category,
    [Parameter(Mandatory)]
    [bool]$Smoke
  )

  if ($Smoke) {
    return [pscustomobject]@{
      RunRepoSyntax = $true
      RunScriptAnalysis = $false
      RunResolveServiceExecutable = $false
      RunUnitTests = $true
      RunStandaloneScripts = $true
      StandaloneScriptNames = @('test-installer.ps1')
    }
  }

  return [pscustomobject]@{
    RunRepoSyntax = (Should-RunCategory -RequestedCategory $Category -TestCategory 'Unit')
    RunScriptAnalysis = (Should-RunCategory -RequestedCategory $Category -TestCategory 'Unit')
    RunResolveServiceExecutable = (Should-RunCategory -RequestedCategory $Category -TestCategory 'Integration')
    RunUnitTests = (Should-RunCategory -RequestedCategory $Category -TestCategory 'Unit')
    RunStandaloneScripts = (Should-RunCategory -RequestedCategory $Category -TestCategory 'Integration')
    StandaloneScriptNames = @()
  }
}

function Test-RepoPowerShellSyntax {
<#
.SYNOPSIS
  Runs the repo-wide PowerShell syntax parser pass.
.OUTPUTS
  Boolean - Returns $true if parsing succeeds, otherwise $false.
#>
  [CmdletBinding()]
  param(
    [switch]$Detailed
  )

  $syntaxRunner = Join-Path $repoRoot 'scripts\syntax\Test-RepoPowerShellSyntax.ps1'
  & $syntaxRunner

  return $true
}

function Test-ScriptAnalysis {
<#
.SYNOPSIS
  Runs the repo static-analysis wrapper.
.OUTPUTS
  Boolean - Returns $true if analysis succeeds, otherwise $false.
#>
  [CmdletBinding()]
  param(
    [switch]$Detailed
  )

  $analysisRunner = Join-Path $PSScriptRoot 'script-analysis.ps1'
  & $analysisRunner

  return $true
}

function Test-ResolveServiceExecutable {
<#
.SYNOPSIS
  Runs a test suite for Resolve-ServiceExecutable
.OUTPUTS
  Boolean - Returns $true if ALL tests pass, otherwise $false.
#>
  param(
    [switch]$Detailed
  )

  if ($env:GITHUB_ACTIONS -eq 'true') {
    Write-Host "Skipping Resolve-ServiceExecutable on GitHub-hosted runners due to machine-coupled service inventory." -ForegroundColor DarkGray
    return $true
  }

  $return = $true

  echo "Testing Resolve-ServiceExecutable"
  Get-CimInstance Win32_Service | Select-Object Name,PathName,DisplayName | ForEach-Object {
    $pn = $_.PathName
    $sn = $_.Name

    if ([string]::IsNullOrWhiteSpace($pn)) {
      if ($Detailed) {
        Write-Host "Skipping service with empty PathName: $sn" -ForegroundColor DarkGray
      }
      return
    }

    try {
      $result = Resolve-ServiceExecutable $pn $sn
      if ($null -eq $result -or $null -eq $result.payloadpath -or (-not (Test-Path $result.payloadpath))) {
        echo ""
        echo "Resolve-ServiceExecutable failed to return payloadpath"
        echo "PathOrName  = ``$pn``"
        echo "ServiceName = ``$sn``"
        Resolve-ServiceExecutable $pn $sn -Verbose
        $return = $false
      }
    } catch {
      echo ""
      echo "Resolve-ServiceExecutable threw unexpectedly"
      echo "PathOrName  = ``$pn``"
      echo "ServiceName = ``$sn``"
      echo "Error       = ``$($_.Exception.Message)``"
      $return = $false
    }
  }

  return $return
}

function Test-UnitSuite {
<#
.SYNOPSIS
  Runs the Pester unit test suite.
.OUTPUTS
  Boolean - Returns $true if ALL tests pass, otherwise $false.
#>
  [CmdletBinding()]
  param(
    [switch]$Detailed
  )

  $unitRunner = Join-Path $PSScriptRoot 'run-unit-tests.ps1'
  & $unitRunner -Quiet:(-not $Detailed)

  return $true
}

function Test-StandaloneTestScripts {
<#
.SYNOPSIS
  Runs all standalone `test*.ps1` scripts in this folder and asserts they do not throw.
.OUTPUTS
  Boolean - Returns $true if all standalone test scripts complete without throwing, otherwise $false.
#>
  [CmdletBinding()]
  param(
    [switch]$Detailed,
    [string[]]$IncludeScriptNames
  )

  $thisScriptPath = [System.IO.Path]::GetFullPath($PSCommandPath)
  $testScripts = @(
    Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'test*.ps1' -File |
      Where-Object {
        [System.IO.Path]::GetFullPath($_.FullName) -ne $thisScriptPath -and
        $_.Name -ne 'test-helpers.ps1'
      } |
      Sort-Object Name
  )

  if ($IncludeScriptNames -and $IncludeScriptNames.Count -gt 0) {
    $testScripts = @($testScripts | Where-Object { $_.Name -in $IncludeScriptNames })
  }

  if ($testScripts.Count -eq 0) {
    Write-Host "No standalone test scripts found under $PSScriptRoot" -ForegroundColor DarkGray
    return $true
  }

  $passed = 0
  $failed = 0

  foreach ($testScript in $testScripts) {
    if ($Detailed) {
      Write-Host "Running standalone test script $($testScript.Name)" -ForegroundColor Cyan
    }

    try {
      & $testScript.FullName
      Write-Host "[PASS] $($testScript.Name)" -ForegroundColor Green
      $passed++
    } catch {
      $failureText = ($_ | Out-String).Trim()
      Write-Host "[FAIL] $($testScript.Name)" -ForegroundColor Red
      Write-Host $failureText -ForegroundColor Red
      $artifactPath = Write-TestArtifact -Name $testScript.BaseName -Content $failureText
      if ($Detailed) {
        Write-Host "      Log:      $artifactPath" -ForegroundColor DarkGray
      }
      $failed++
    }
  }

  if ($failed -gt 0) {
    Write-Host "Standalone test script summary: $passed Passed, $failed Failed." -ForegroundColor Red
    return $false
  }

  Write-Host "Standalone test script summary: $passed Passed, $failed Failed." -ForegroundColor Green
  return $true
}

if ($MyInvocation.InvocationName -ne '.') {
  Initialize-TestArtifacts

  $results = @()
  $selection = Get-TestSelection -Category $Category -Smoke:$Smoke

  if ($selection.RunRepoSyntax) {
    $passed = [bool](Test-RepoPowerShellSyntax -Detailed:$Detailed | Select-Object -Last 1)
    $results += New-TestGroupResult -Name 'Repo PowerShell syntax' -Category 'Unit' -Passed $passed
  }

  if ($selection.RunScriptAnalysis) {
    $passed = [bool](Test-ScriptAnalysis -Detailed:$Detailed | Select-Object -Last 1)
    $results += New-TestGroupResult -Name 'ScriptAnalyzer' -Category 'Unit' -Passed $passed
  }

  if ($selection.RunResolveServiceExecutable) {
    $passed = [bool](Test-ResolveServiceExecutable -Detailed:$Detailed | Select-Object -Last 1)
    $results += New-TestGroupResult -Name 'Resolve-ServiceExecutable' -Category 'Integration' -Passed $passed
  }

  if ($selection.RunUnitTests) {
    $passed = [bool](Test-UnitSuite -Detailed:$Detailed | Select-Object -Last 1)
    $results += New-TestGroupResult -Name 'Pester unit suite' -Category 'Unit' -Passed $passed
  }

  if ($selection.RunStandaloneScripts) {
    $previousInstallerEnv = $env:GCH_TEST_INSTALLER_INCLUDE_VERSIONLESS
    try {
      if ($Smoke) {
        Remove-Item Env:\GCH_TEST_INSTALLER_INCLUDE_VERSIONLESS -ErrorAction SilentlyContinue
      } else {
        $env:GCH_TEST_INSTALLER_INCLUDE_VERSIONLESS = '1'
      }

      $passed = [bool](Test-StandaloneTestScripts -Detailed:$Detailed -IncludeScriptNames $selection.StandaloneScriptNames | Select-Object -Last 1)
      $results += New-TestGroupResult -Name 'Standalone scripts' -Category 'Integration' -Passed $passed
    } finally {
      if ($null -eq $previousInstallerEnv) {
        Remove-Item Env:\GCH_TEST_INSTALLER_INCLUDE_VERSIONLESS -ErrorAction SilentlyContinue
      } else {
        $env:GCH_TEST_INSTALLER_INCLUDE_VERSIONLESS = $previousInstallerEnv
      }
    }
  }

  $failedResults = @($results | Where-Object { -not $_.Passed })
  $passedResults = @($results | Where-Object Passed)

  $summaryColor = if ($failedResults.Count -gt 0) { 'Red' } else { 'Green' }
  Write-Host "Test group summary: $($passedResults.Count) passed, $($failedResults.Count) failed, $($results.Count) total." -ForegroundColor $summaryColor
  if ($failedResults.Count -gt 0) {
    Write-Host "Failed groups: $($failedResults.Name -join ', ')" -ForegroundColor Red
  }
  if ($Detailed) {
    Write-Host "Artifacts: $script:ArtifactsRoot" -ForegroundColor DarkGray
  }
  if ($Smoke) {
    Write-Host "Selection: smoke mode" -ForegroundColor DarkGray
  }

  if ($failedResults.Count -gt 0) {
    throw "One or more tests failed."
  }

  $global:LASTEXITCODE = 0
}
