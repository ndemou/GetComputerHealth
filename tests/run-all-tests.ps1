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
. (Join-Path $repoRoot 'health-tests\srvc-exe-resolve.ps1')

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
      RunResolveServiceExecutable = $false
      RunResolveExecutablePath = $true
      RunStandaloneScripts = $false
    }
  }

  return [pscustomobject]@{
    RunResolveServiceExecutable = (Should-RunCategory -RequestedCategory $Category -TestCategory 'Integration')
    RunResolveExecutablePath = (Should-RunCategory -RequestedCategory $Category -TestCategory 'Unit')
    RunStandaloneScripts = (Should-RunCategory -RequestedCategory $Category -TestCategory 'Integration')
  }
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

function Test-ResolveExecutablePath {
<#
.SYNOPSIS
  Runs a test suite for Resolve-ExecutablePath.
.OUTPUTS
  Boolean - Returns $true if ALL tests pass, otherwise $false.
#>
  [CmdletBinding()]
  param(
    [switch]$Detailed
  )

  try {
    Write-Host "Starting Test Suite for Resolve-ExecutablePath..." -ForegroundColor Cyan
    Write-Host "------------------------------------------------" -ForegroundColor Gray

    $guid = [Guid]::NewGuid().ToString()
    $rawTempPath = Join-Path $env:TEMP "ResolveExeTest_$guid"
    $dirItem = New-Item -ItemType Directory -Path $rawTempPath -Force
    $tempRoot = $dirItem.FullName

    $subDir = Join-Path $tempRoot "SubFolder"
    New-Item -ItemType Directory -Path $subDir -Force | Out-Null

    $filesToCreate = @(
      "rootTool.exe",
      "script.bat",
      "space tool.exe",
      "SubFolder\deep.com",
      "tool[1].exe"
    )
    foreach ($file in $filesToCreate) {
      $fullPath = Join-Path $tempRoot $file
      New-Item -ItemType File -Path $fullPath -Force | Out-Null
    }

    $originalLocation = Get-Location
    $originalPath = $env:PATH
    $env:PATH = "$tempRoot;$env:PATH"

    $hasNotepad = Test-Path -LiteralPath (Join-Path $env:WINDIR "System32\notepad.exe") -PathType Leaf
    $hasNetsh = Test-Path -LiteralPath (Join-Path $env:WINDIR "System32\netsh.exe") -PathType Leaf

    $testCases = @(
      @{
        Name = "Quotes: Double Quotes + Env"
        Input = "`"%WINDIR%\System32\notepad.exe`""
        Expected = if ($hasNotepad) { (Get-Item -LiteralPath (Join-Path $env:WINDIR "System32\notepad.exe")).FullName } else { $null }
        WorkDir = $tempRoot
      },
      @{
        Name = "Quotes: Single Quotes + Env"
        Input = "'%WINDIR%\System32\notepad.exe'"
        Expected = if ($hasNotepad) { (Get-Item -LiteralPath (Join-Path $env:WINDIR "System32\notepad.exe")).FullName } else { $null }
        WorkDir = $tempRoot
      },
      @{
        Name = "Absolute: Exact Match"
        Input = (Join-Path $tempRoot "rootTool.exe")
        Expected = (Join-Path $tempRoot "rootTool.exe")
        WorkDir = $tempRoot
      },
      @{
        Name = "Absolute: Missing Extension (.exe probe)"
        Input = (Join-Path $tempRoot "rootTool")
        Expected = (Join-Path $tempRoot "rootTool.exe")
        WorkDir = $tempRoot
      },
      @{
        Name = "Absolute: Missing Extension (.bat probe)"
        Input = (Join-Path $tempRoot "script")
        Expected = (Join-Path $tempRoot "script.bat")
        WorkDir = $tempRoot
      },
      @{
        Name = "PATH: Command Search (rootTool)"
        Input = "rootTool"
        Expected = (Join-Path $tempRoot "rootTool.exe")
        WorkDir = $env:USERPROFILE
      },
      @{
        Name = "PATH: Command with Spaces"
        Input = "space tool"
        Expected = (Join-Path $tempRoot "space tool.exe")
        WorkDir = $env:USERPROFILE
      },
      @{
        Name = "System32/Sysnative fallback: netsh (works even if System32 removed from PATH)"
        Input = "netsh"
        Expected = if ($hasNetsh) { (Get-Item -LiteralPath (Join-Path $env:WINDIR "System32\netsh.exe")).FullName } else { $null }
        WorkDir = $env:USERPROFILE
        Before = {
          $script:SavedPathForNetshTest = $env:PATH
          $env:PATH = ($env:PATH -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -notin @((Join-Path $env:WINDIR "System32"), (Join-Path $env:WINDIR "Sysnative")) }) -join ';'
        }
        After = {
          $env:PATH = $script:SavedPathForNetshTest
          Remove-Variable SavedPathForNetshTest -Scope Script -ErrorAction SilentlyContinue
        }
      },
      @{
        Name = "Wildcards literal: tool[1].exe exact absolute"
        Input = (Join-Path $tempRoot "tool[1].exe")
        Expected = (Join-Path $tempRoot "tool[1].exe")
        WorkDir = $tempRoot
      },
      @{
        Name = "Wildcards literal: tool[1] (absolute, missing ext -> .exe probe)"
        Input = (Join-Path $tempRoot "tool[1]")
        Expected = (Join-Path $tempRoot "tool[1].exe")
        WorkDir = $tempRoot
      },
      @{
        Name = "Wildcards literal: tool*.exe should NOT expand (typically null)"
        Input = (Join-Path $tempRoot "tool*.exe")
        Expected = $null
        WorkDir = $tempRoot
      },
      @{
        Name = "Illegal chars: rooted path returns null"
        Input = "C:\Bad|Name\tool.exe"
        Expected = $null
        WorkDir = $tempRoot
      },
      @{
        Name = "Illegal chars: relative path returns null"
        Input = ".\Bad|Name\tool.exe"
        Expected = $null
        WorkDir = $tempRoot
      },
      @{
        Name = "Failure: Non-existent command"
        Input = "ghost_file_xyz"
        Expected = $null
        WorkDir = $tempRoot
      }
    )

    $passed = 0
    $failed = 0

    foreach ($t in $testCases) {
      if ($t.Before) { & $t.Before }
      try {
        Set-Location $t.WorkDir
        $result = Resolve-ExecutablePath $t.Input
      } catch {
        $result = "__THREW__ $($_.Exception.GetType().FullName): $($_.Exception.Message)"
      } finally {
        if ($t.After) { & $t.After }
      }

      $status = "FAIL"
      $color = "Red"
      $exp = $t.Expected

      $ok = $false
      if ($result -eq $exp) {
        $ok = $true
      } elseif ($result -ne $null -and $exp -ne $null) {
        try {
          if ($result.ToString().ToLowerInvariant() -eq $exp.ToString().ToLowerInvariant()) {
            $ok = $true
          }
        } catch {
        }
      }

      if ($ok) {
        $status = "PASS"
        $color = "Green"
        $passed++
      } else {
        $failed++
      }

      if ($Detailed -or $status -eq "FAIL") {
        Write-Host "[$status] $($t.Name) ``$($t.Input)``" -ForegroundColor $color
      }
      if ($status -eq "FAIL") {
        Write-Host "      Input:    $($t.Input)"
        Write-Host "      Expected: $exp"
        Write-Host "      Got:      $result"
      }
    }

    Set-Location $originalLocation
    $env:PATH = $originalPath

    try {
      Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
      Write-Warning "Could not fully delete temp dir: $tempRoot"
    }

    Write-Host "------------------------------------------------" -ForegroundColor Gray
    if ($failed -gt 0) {
      Write-Host "Summary: $passed Passed, $failed Failed." -ForegroundColor Red
      return $false
    }

    Write-Host "Summary: $passed Passed, $failed Failed." -ForegroundColor Green
  } finally {
    try { Set-Location $originalLocation } catch {}
    $env:PATH = $originalPath
    if ($tempRoot) {
      try { Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
  }

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
    [switch]$Detailed
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

  if ($selection.RunResolveServiceExecutable) {
    $passed = [bool](Test-ResolveServiceExecutable -Detailed:$Detailed | Select-Object -Last 1)
    $results += New-TestGroupResult -Name 'Resolve-ServiceExecutable' -Category 'Integration' -Passed $passed
  }

  if ($selection.RunResolveExecutablePath) {
    $passed = [bool](Test-ResolveExecutablePath -Detailed:$Detailed | Select-Object -Last 1)
    $results += New-TestGroupResult -Name 'Resolve-ExecutablePath' -Category 'Unit' -Passed $passed
  }

  if ($selection.RunStandaloneScripts) {
    $passed = [bool](Test-StandaloneTestScripts -Detailed:$Detailed | Select-Object -Last 1)
    $results += New-TestGroupResult -Name 'Standalone scripts' -Category 'Integration' -Passed $passed
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
}
