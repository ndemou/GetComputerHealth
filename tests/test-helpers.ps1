Set-StrictMode -Version Latest

function Fail-Test {
  param(
    [Parameter(Mandatory)]
    [string]$Message
  )

  throw $Message
}

function Assert-True {
  param(
    [Parameter(Mandatory)]
    [bool]$Condition,
    [Parameter(Mandatory)]
    [string]$Message
  )

  if (-not $Condition) {
    Fail-Test $Message
  }
}

function Assert-PathExists {
  param(
    [Parameter(Mandatory)]
    [string]$Path,
    [string]$Message
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    if (-not $Message) {
      $Message = "Expected path to exist: $Path"
    }

    Fail-Test $Message
  }
}

function Assert-CommandAvailable {
  param(
    [Parameter(Mandatory)]
    [string]$CommandName
  )

  $command = Get-Command -Name $CommandName -ErrorAction SilentlyContinue
  if ($null -eq $command) {
    Fail-Test "Required command is not available: $CommandName"
  }
}

function Assert-DirectoryWritable {
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  New-Item -ItemType Directory -Path $Path -Force | Out-Null
  $probePath = Join-Path $Path (".write-test-" + [guid]::NewGuid().ToString() + ".tmp")
  try {
    Set-Content -LiteralPath $probePath -Value "ok" -NoNewline -ErrorAction Stop
  } catch {
    Fail-Test "Directory is not writable: $Path. $($_.Exception.Message)"
  } finally {
    Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
  }
}

function Get-EmbeddedScriptVersion {
  param(
    [Parameter(Mandatory)]
    [string]$ScriptPath
  )

  Assert-PathExists -Path $ScriptPath -Message "Expected script with embedded version to exist: $ScriptPath"

  $content = Get-Content -LiteralPath $ScriptPath -Raw -ErrorAction Stop
  $match = [regex]::Match($content, '(?im)^\s*\$VERSION\s*=\s*["''](?<version>\d+\.\d+\.\d+)["'']')
  if (-not $match.Success) {
    Fail-Test "Could not find embedded semantic version in script: $ScriptPath"
  }

  return $match.Groups['version'].Value
}

function Get-TestPaths {
  param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,
    [string]$RunRoot = 'C:\it\temp-gch'
  )

  $mainScriptSource = Join-Path $RepoRoot 'Get-ComputerHealth.ps1'
  $repoVersion = Get-EmbeddedScriptVersion -ScriptPath $mainScriptSource

  [pscustomobject]@{
    RepoRoot = $RepoRoot
    RepoVersion = $repoVersion
    TestRoot = $RunRoot
    TestsRoot = (Join-Path $RepoRoot 'tests')
    InstallRoot = (Join-Path $RunRoot 'bin')
    ConfigRoot = (Join-Path $RunRoot 'config')
    SuppressionsFile = (Join-Path $RunRoot 'config\Get-ComputerHealth.sigs-to-suppress.txt')
    ReleaseRoot = (Join-Path $RunRoot 'release')
    ReleaseZipPath = (Join-Path $RunRoot ("GetComputerHealth-under-test-v{0}.zip" -f $repoVersion))
    ReleaseZipPathVersionless = (Join-Path $RunRoot 'GetComputerHealth-under-test.zip')
    UpdateScriptSource = (Join-Path $RepoRoot 'Update-GetHealthCode.ps1')
    MainScriptSource = $mainScriptSource
    HelperScript = (Join-Path $RepoRoot 'tests\helpers-files.ps1')
  }
}

function New-TestRunRoot {
  param(
    [string]$Name = 'gch-tests'
  )

  $root = Join-Path $env:TEMP ($Name + '-' + [guid]::NewGuid().ToString())
  New-Item -ItemType Directory -Path $root -Force | Out-Null
  return $root
}

function Remove-TestRunRoot {
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  $tempRoot = [System.IO.Path]::GetFullPath($env:TEMP)
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  if (-not $fullPath.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    Fail-Test "Refusing to remove non-temp test path: $Path"
  }

  Remove-Item -LiteralPath $fullPath -Recurse -Force -ErrorAction SilentlyContinue
}

function Invoke-RobocopyChecked {
  param(
    [Parameter(Mandatory)]
    [string]$Source,
    [Parameter(Mandatory)]
    [string]$Destination,
    [string[]]$ExcludeDirectories = @()
  )

  $arguments = @(
    $Source
    $Destination
  )

  if ($ExcludeDirectories.Count -gt 0) {
    $arguments += '/xd'
    $arguments += $ExcludeDirectories
  }

  $arguments += @('/mir', '/nfl', '/ndl', '/nc', '/ns')

  & robocopy @arguments | Out-Null
  $robocopyExitCode = $LASTEXITCODE
  if ($robocopyExitCode -ge 8) {
    Fail-Test "Robocopy failed with exit code $robocopyExitCode"
  }

  $global:LASTEXITCODE = 0
}
