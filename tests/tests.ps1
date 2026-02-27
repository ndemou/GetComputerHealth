function Test-ResolveServiceExecutable {
<#
.SYNOPSIS
  Runs a test suite for Resolve-ServiceExecutable
.OUTPUTS
  Boolean - Returns $true if ALL tests pass, otherwise $false.
#>
  $return = $true
 
  echo "Testing Resolve-ServiceExecutable"
  Get-CimInstance Win32_Service | Select-Object Name,PathName,DisplayName | %{ 
	$pn=$_.PathName
	$sn=$_.name
	$result=Resolve-ServiceExecutable $pn $sn; 
	if ($null -eq $result -or $null -eq $result.payloadpath -or (-not (test-path $result.payloadpath))) {
		echo ""
		echo "Resolve-ServiceExecutable failed to return payloadpath"
		echo "PathOrName  = ``$pn``"
		echo "ServiceName = ``$sn``"
		Resolve-ServiceExecutable $pn $sn -Verbose
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
  param()

try{
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
	  $hasNetsh   = Test-Path -LiteralPath (Join-Path $env:WINDIR "System32\netsh.exe")   -PathType Leaf

	  $testCases = @(
		# --- Quote handling (both types) ---
		@{
		  Name="Quotes: Double Quotes + Env"
		  Input="`"%WINDIR%\System32\notepad.exe`""
		  Expected= if($hasNotepad){ (Get-Item -LiteralPath (Join-Path $env:WINDIR "System32\notepad.exe")).FullName } else { $null }
		  WorkDir=$tempRoot
		},
		@{
		  Name="Quotes: Single Quotes + Env"
		  Input="'%WINDIR%\System32\notepad.exe'"
		  Expected= if($hasNotepad){ (Get-Item -LiteralPath (Join-Path $env:WINDIR "System32\notepad.exe")).FullName } else { $null }
		  WorkDir=$tempRoot
		},

		# --- Absolute path, exact match ---
		@{
		  Name="Absolute: Exact Match"
		  Input=(Join-Path $tempRoot "rootTool.exe")
		  Expected=(Join-Path $tempRoot "rootTool.exe")
		  WorkDir=$tempRoot
		},

		# --- Absolute path missing extension: probes PATHEXT (+ ensures .exe) ---
		@{
		  Name="Absolute: Missing Extension (.exe probe)"
		  Input=(Join-Path $tempRoot "rootTool")
		  Expected=(Join-Path $tempRoot "rootTool.exe")
		  WorkDir=$tempRoot
		},
		@{
		  Name="Absolute: Missing Extension (.bat probe)"
		  Input=(Join-Path $tempRoot "script")
		  Expected=(Join-Path $tempRoot "script.bat")
		  WorkDir=$tempRoot
		},

		# --- Bare command name via PATH (Application only) ---
		@{
		  Name="PATH: Command Search (rootTool)"
		  Input="rootTool"
		  Expected=(Join-Path $tempRoot "rootTool.exe")
		  WorkDir=$env:USERPROFILE
		},
		@{
		  Name="PATH: Command with Spaces"
		  Input="space tool"
		  Expected=(Join-Path $tempRoot "space tool.exe")
		  WorkDir=$env:USERPROFILE
		},

		# --- System32/Sysnative fallback (can succeed even if System32 is NOT in PATH) ---
		@{
		  Name="System32/Sysnative fallback: netsh (works even if System32 removed from PATH)"
		  Input="netsh"
		  Expected= if($hasNetsh){ (Get-Item -LiteralPath (Join-Path $env:WINDIR "System32\netsh.exe")).FullName } else { $null }
		  WorkDir=$env:USERPROFILE
		  Before={
			$script:SavedPathForNetshTest = $env:PATH
			$env:PATH = ($env:PATH -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -notin @((Join-Path $env:WINDIR "System32"), (Join-Path $env:WINDIR "Sysnative")) }) -join ';'
		  }
		  After={
			$env:PATH = $script:SavedPathForNetshTest
			Remove-Variable SavedPathForNetshTest -Scope Script -ErrorAction SilentlyContinue
		  }
		},

		# --- Wildcards are LITERAL (no expansion); should resolve literal filename tool[1].exe ---
		@{
		  Name="Wildcards literal: tool[1].exe exact absolute"
		  Input=(Join-Path $tempRoot "tool[1].exe")
		  Expected=(Join-Path $tempRoot "tool[1].exe")
		  WorkDir=$tempRoot
		},
		@{
		  Name="Wildcards literal: tool[1] (absolute, missing ext -> .exe probe)"
		  Input=(Join-Path $tempRoot "tool[1]")
		  Expected=(Join-Path $tempRoot "tool[1].exe")
		  WorkDir=$tempRoot
		},
		@{
		  Name="Wildcards literal: tool*.exe should NOT expand (typically null)"
		  Input=(Join-Path $tempRoot "tool*.exe")
		  Expected=$null
		  WorkDir=$tempRoot
		},

		# --- Illegal path characters in path-like inputs => $null (no throw) ---
		@{
		  Name="Illegal chars: rooted path returns null"
		  Input="C:\Bad|Name\tool.exe"
		  Expected=$null
		  WorkDir=$tempRoot
		},
		@{
		  Name="Illegal chars: relative path returns null"
		  Input=".\Bad|Name\tool.exe"
		  Expected=$null
		  WorkDir=$tempRoot
		},

		# --- Failure ---
		@{
		  Name="Failure: Non-existent command"
		  Input="ghost_file_xyz"
		  Expected=$null
		  WorkDir=$tempRoot
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

		$status="FAIL"; $color="Red"
		$exp = $t.Expected

		$ok = $false
		if ($result -eq $exp) { $ok = $true }
		elseif ($result -ne $null -and $exp -ne $null) {
		  try { if ($result.ToString().ToLowerInvariant() -eq $exp.ToString().ToLowerInvariant()) { $ok = $true } } catch {}
		}

		if ($ok) { $status="PASS"; $color="Green"; $passed++ } else { $failed++ }

		Write-Host "[$status] $($t.Name) ``$($t.Input)``" -ForegroundColor $color
		if ($status -eq "FAIL") {
		  Write-Host "      Input:    $($t.Input)"
		  Write-Host "      Expected: $exp"
		  Write-Host "      Got:      $result"
		}
	  }

	  Set-Location $originalLocation
	  $env:PATH = $originalPath

	  try { Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { Write-Warning "Could not fully delete temp dir: $tempRoot" }

	  Write-Host "------------------------------------------------" -ForegroundColor Gray
	  if ($failed -gt 0) { Write-Host "Summary: $passed Passed, $failed Failed." -ForegroundColor Red; return $false }
	  Write-Host "Summary: $passed Passed, $failed Failed." -ForegroundColor Green
  } finally{
    try{ Set-Location $originalLocation } catch {}
    $env:PATH=$originalPath
    if($tempRoot){ try{ Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
  }  
  return $true
}
