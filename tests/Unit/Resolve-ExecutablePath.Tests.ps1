$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'health-tests\srvc-exe-resolve.ps1')

function Test-CaseHasProperty {
  param(
    [Parameter(Mandatory)]
    [object]$Case,
    [Parameter(Mandatory)]
    [string]$Name
  )

  return $null -ne $Case.PSObject.Properties[$Name]
}

$script:NewResolveExecutablePathTestRoot = {
  $root = Join-Path $env:TEMP ("ResolveExeTest_" + [guid]::NewGuid().ToString())
  $dirItem = New-Item -ItemType Directory -Path $root -Force
  return $dirItem.FullName
}

$script:RemoveResolveExecutablePathTestRoot = {
  param(
    [string]$Path
  )

  if ($Path) {
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Describe 'Resolve-ExecutablePath' {
  $tempRoot = $null
  $originalLocation = $null
  $originalPath = $null

  BeforeEach {
    $tempRoot = & $script:NewResolveExecutablePathTestRoot
    $subDir = Join-Path $tempRoot 'SubFolder'
    New-Item -ItemType Directory -Path $subDir -Force | Out-Null

    @(
      'rootTool.exe',
      'script.bat',
      'space tool.exe',
      'SubFolder\deep.com',
      'tool[1].exe'
    ) | ForEach-Object {
      New-Item -ItemType File -Path (Join-Path $tempRoot $_) -Force | Out-Null
    }

    $originalLocation = Get-Location
    $originalPath = $env:PATH
    $env:PATH = "$tempRoot;$env:PATH"
  }

  AfterEach {
    try { Set-Location $originalLocation } catch {}
    $env:PATH = $originalPath
    & $script:RemoveResolveExecutablePathTestRoot -Path $tempRoot
  }

  $hasNotepad = Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\notepad.exe') -PathType Leaf
  $hasNetsh = Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\netsh.exe') -PathType Leaf

  $testCases = @(
    @{
      Name = 'Quotes: Double Quotes + Env'
      Input = "`"%WINDIR%\System32\notepad.exe`""
      Expected = if ($hasNotepad) { (Get-Item -LiteralPath (Join-Path $env:WINDIR 'System32\notepad.exe')).FullName } else { $null }
      WorkDir = { param($root) $root }
    },
    @{
      Name = 'Quotes: Single Quotes + Env'
      Input = "'%WINDIR%\System32\notepad.exe'"
      Expected = if ($hasNotepad) { (Get-Item -LiteralPath (Join-Path $env:WINDIR 'System32\notepad.exe')).FullName } else { $null }
      WorkDir = { param($root) $root }
    },
    @{
      Name = 'Absolute: Exact Match'
      Input = { param($root) (Join-Path $root 'rootTool.exe') }
      Expected = { param($root) (Join-Path $root 'rootTool.exe') }
      WorkDir = { param($root) $root }
    },
    @{
      Name = 'Absolute: Missing Extension (.exe probe)'
      Input = { param($root) (Join-Path $root 'rootTool') }
      Expected = { param($root) (Join-Path $root 'rootTool.exe') }
      WorkDir = { param($root) $root }
    },
    @{
      Name = 'Absolute: Missing Extension (.bat probe)'
      Input = { param($root) (Join-Path $root 'script') }
      Expected = { param($root) (Join-Path $root 'script.bat') }
      WorkDir = { param($root) $root }
    },
    @{
      Name = 'PATH: Command Search (rootTool)'
      Input = 'rootTool'
      Expected = { param($root) (Join-Path $root 'rootTool.exe') }
      WorkDir = { param($root) $env:USERPROFILE }
    },
    @{
      Name = 'PATH: Command with Spaces'
      Input = 'space tool'
      Expected = { param($root) (Join-Path $root 'space tool.exe') }
      WorkDir = { param($root) $env:USERPROFILE }
    },
    @{
      Name = 'System32/Sysnative fallback: netsh'
      Input = 'netsh'
      Expected = if ($hasNetsh) { (Get-Item -LiteralPath (Join-Path $env:WINDIR 'System32\netsh.exe')).FullName } else { $null }
      WorkDir = { param($root) $env:USERPROFILE }
      Before = {
        $script:SavedPathForNetshTest = $env:PATH
        $env:PATH = ($env:PATH -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -notin @((Join-Path $env:WINDIR 'System32'), (Join-Path $env:WINDIR 'Sysnative')) }) -join ';'
      }
      After = {
        $env:PATH = $script:SavedPathForNetshTest
        Remove-Variable SavedPathForNetshTest -Scope Script -ErrorAction SilentlyContinue
      }
    },
    @{
      Name = 'Wildcards literal: tool[1].exe exact absolute'
      Input = { param($root) (Join-Path $root 'tool[1].exe') }
      Expected = { param($root) (Join-Path $root 'tool[1].exe') }
      WorkDir = { param($root) $root }
    },
    @{
      Name = 'Wildcards literal: tool[1] (absolute, missing ext -> .exe probe)'
      Input = { param($root) (Join-Path $root 'tool[1]') }
      Expected = { param($root) (Join-Path $root 'tool[1].exe') }
      WorkDir = { param($root) $root }
    },
    @{
      Name = 'Wildcards literal: tool*.exe should NOT expand'
      Input = { param($root) (Join-Path $root 'tool*.exe') }
      Expected = $null
      WorkDir = { param($root) $root }
    },
    @{
      Name = 'Illegal chars: rooted path returns null'
      Input = 'C:\Bad|Name\tool.exe'
      Expected = $null
      WorkDir = { param($root) $root }
    },
    @{
      Name = 'Illegal chars: relative path returns null'
      Input = '.\Bad|Name\tool.exe'
      Expected = $null
      WorkDir = { param($root) $root }
    },
    @{
      Name = 'Failure: Non-existent command'
      Input = 'ghost_file_xyz'
      Expected = $null
      WorkDir = { param($root) $root }
    }
  )

  foreach ($t in $testCases) {
    It $t.Name {
      if (Test-CaseHasProperty -Case $t -Name 'Before') { & $t.Before }
      try {
        $workDir = if ($t.WorkDir -is [scriptblock]) { & $t.WorkDir $tempRoot } else { $t.WorkDir }
        Set-Location $workDir

        $inputValue = if ($t.Input -is [scriptblock]) { & $t.Input $tempRoot } else { $t.Input }
        $expectedValue = if ($t.Expected -is [scriptblock]) { & $t.Expected $tempRoot } else { $t.Expected }

        $result = $null
        $threw = $false
        try {
          $result = Resolve-ExecutablePath $inputValue
        } catch {
          $threw = $true
        }

        $threw | Should Be $false
        if ($null -eq $expectedValue) {
          $result | Should Be $null
        } else {
          $result.ToString().ToLowerInvariant() | Should Be $expectedValue.ToString().ToLowerInvariant()
        }
      } finally {
        if (Test-CaseHasProperty -Case $t -Name 'After') { & $t.After }
      }
    }
  }
}
