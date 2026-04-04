$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Describe 'Resolve-ExecutablePath' {
  BeforeAll {
    . (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'health-tests\srvc-exe-resolve.ps1')
  }

  $hasNotepad = Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\notepad.exe') -PathType Leaf
  $hasNetsh = Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\netsh.exe') -PathType Leaf

  $testCases = @(
    @{
      Name = 'Quotes: Double Quotes + Env'
      CaseInput = "`"%WINDIR%\System32\notepad.exe`""
      CaseExpected = if ($hasNotepad) { (Get-Item -LiteralPath (Join-Path $env:WINDIR 'System32\notepad.exe')).FullName } else { $null }
      CaseWorkDir = { param($root) $root }
    },
    @{
      Name = 'Quotes: Single Quotes + Env'
      CaseInput = "'%WINDIR%\System32\notepad.exe'"
      CaseExpected = if ($hasNotepad) { (Get-Item -LiteralPath (Join-Path $env:WINDIR 'System32\notepad.exe')).FullName } else { $null }
      CaseWorkDir = { param($root) $root }
    },
    @{
      Name = 'Absolute: Exact Match'
      CaseInput = { param($root) (Join-Path $root 'rootTool.exe') }
      CaseExpected = { param($root) (Join-Path $root 'rootTool.exe') }
      CaseWorkDir = { param($root) $root }
    },
    @{
      Name = 'Absolute: Missing Extension (.exe probe)'
      CaseInput = { param($root) (Join-Path $root 'rootTool') }
      CaseExpected = { param($root) (Join-Path $root 'rootTool.exe') }
      CaseWorkDir = { param($root) $root }
    },
    @{
      Name = 'Absolute: Missing Extension (.bat probe)'
      CaseInput = { param($root) (Join-Path $root 'script') }
      CaseExpected = { param($root) (Join-Path $root 'script.bat') }
      CaseWorkDir = { param($root) $root }
    },
    @{
      Name = 'PATH: Command Search (rootTool)'
      CaseInput = 'rootTool'
      CaseExpected = { param($root) (Join-Path $root 'rootTool.exe') }
      CaseWorkDir = { param($root) $env:USERPROFILE }
    },
    @{
      Name = 'PATH: Command with Spaces'
      CaseInput = 'space tool'
      CaseExpected = { param($root) (Join-Path $root 'space tool.exe') }
      CaseWorkDir = { param($root) $env:USERPROFILE }
    },
    @{
      Name = 'System32/Sysnative fallback: netsh'
      CaseInput = 'netsh'
      CaseExpected = if ($hasNetsh) { (Get-Item -LiteralPath (Join-Path $env:WINDIR 'System32\netsh.exe')).FullName } else { $null }
      CaseWorkDir = { param($root) $env:USERPROFILE }
      CaseBefore = {
        $script:SavedPathForNetshTest = $env:PATH
        $env:PATH = ($env:PATH -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -notin @((Join-Path $env:WINDIR 'System32'), (Join-Path $env:WINDIR 'Sysnative')) }) -join ';'
      }
      CaseAfter = {
        $env:PATH = $script:SavedPathForNetshTest
        Remove-Variable SavedPathForNetshTest -Scope Script -ErrorAction SilentlyContinue
      }
    },
    @{
      Name = 'Wildcards literal: tool[1].exe exact absolute'
      CaseInput = { param($root) (Join-Path $root 'tool[1].exe') }
      CaseExpected = { param($root) (Join-Path $root 'tool[1].exe') }
      CaseWorkDir = { param($root) $root }
    },
    @{
      Name = 'Wildcards literal: tool[1] (absolute, missing ext -> .exe probe)'
      CaseInput = { param($root) (Join-Path $root 'tool[1]') }
      CaseExpected = { param($root) (Join-Path $root 'tool[1].exe') }
      CaseWorkDir = { param($root) $root }
    },
    @{
      Name = 'Wildcards literal: tool*.exe should NOT expand'
      CaseInput = { param($root) (Join-Path $root 'tool*.exe') }
      CaseExpected = $null
      CaseWorkDir = { param($root) $root }
    },
    @{
      Name = 'Illegal chars: rooted path returns null'
      CaseInput = 'C:\Bad|Name\tool.exe'
      CaseExpected = $null
      CaseWorkDir = { param($root) $root }
    },
    @{
      Name = 'Illegal chars: relative path returns null'
      CaseInput = '.\Bad|Name\tool.exe'
      CaseExpected = $null
      CaseWorkDir = { param($root) $root }
    },
    @{
      Name = 'Failure: Non-existent command'
      CaseInput = 'ghost_file_xyz'
      CaseExpected = $null
      CaseWorkDir = { param($root) $root }
    }
  )

  It '<Name>' -ForEach $testCases {
    param($Name, $CaseInput, $CaseExpected, $CaseWorkDir, $CaseBefore, $CaseAfter)

    $tempRoot = $null
    $originalLocation = $null
    $originalPath = $null

    if ($CaseBefore) { & $CaseBefore }
    try {
      $root = Join-Path $env:TEMP ("ResolveExeTest_" + [guid]::NewGuid().ToString())
      $dirItem = New-Item -ItemType Directory -Path $root -Force
      $tempRoot = $dirItem.FullName
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

      $workDir = if ($CaseWorkDir -is [scriptblock]) { & $CaseWorkDir $tempRoot } else { $CaseWorkDir }
      Set-Location $workDir

      $inputValue = if ($CaseInput -is [scriptblock]) { & $CaseInput $tempRoot } else { $CaseInput }
      $expectedValue = if ($CaseExpected -is [scriptblock]) { & $CaseExpected $tempRoot } else { $CaseExpected }

      $result = $null
      $threw = $false
      try {
        $result = Resolve-ExecutablePath $inputValue
      } catch {
        $threw = $true
      }

      $threw | Should -Be $false
      if ($null -eq $expectedValue) {
        $result | Should -Be $null
      } else {
        $result.ToString().ToLowerInvariant() | Should -Be $expectedValue.ToString().ToLowerInvariant()
      }
    } finally {
      try { Set-Location $originalLocation } catch {}
      if ($null -ne $originalPath) {
        $env:PATH = $originalPath
      }
      if ($tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
      }
      if ($CaseAfter) { & $CaseAfter }
    }
  }
}
