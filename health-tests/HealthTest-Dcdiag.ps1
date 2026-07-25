# HostRequirement: DC

if (-not (Get-Command -Name 'Compress-HealthDiagnosticOutputLines' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helpers-for-healthtests.ps1')
}


function Get-CompressedDcDiagInterestingLines {
  [CmdletBinding()]
  param(
    [AllowEmptyCollection()][string[]]$Lines = @(),
    [AllowEmptyString()][string]$BlockText = '',
    [string]$IncludePattern = 'error|fail',
    [string]$ExcludePattern = '\bno ([A-Za-z]+ )?errors?\b|\bPASS +FAIL\b|\.\.\.\.\.\..* failed test '
  )

  $candidateLines = New-Object 'System.Collections.Generic.List[string]'
  foreach ($line in @($Lines)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    [void]$candidateLines.Add([string]$line)
  }

  if (-not [string]::IsNullOrWhiteSpace($BlockText)) {
    foreach ($line in ($BlockText -split "\r?\n")) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      [void]$candidateLines.Add([string]$line)
    }
  }

  $interestingLines = New-Object 'System.Collections.Generic.List[string]'
  foreach ($line in $candidateLines) {
    $trimmedLine = ([string]$line).Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedLine)) { continue }
    if ($trimmedLine -match $ExcludePattern) { continue }
    if ($trimmedLine -notmatch $IncludePattern) { continue }
    [void]$interestingLines.Add($trimmedLine)
  }

  return (Compress-HealthDiagnosticOutputLines -Lines @($interestingLines)) -join "`n"
}

function Get-DcDiagFailures {
  [CmdletBinding()]
  param(
    [string]$File,
    [switch]$Comprehensive
  )

  if     ($File)             { $s = Get-Content -LiteralPath $File -Raw }
  elseif ($Comprehensive)    { $s = dcdiag /c /v | Out-String }
  else                       { $s = dcdiag /v   | Out-String }

  $rePhase = '^(?<p>\S.*)$'
  $reServer= '^\s{3}Testing server:\s*(?<s>.+)$'
  $reStart = '^\s{6}Starting test:\s*(?<t>.+)$'
  $reEnd   = '^\s*\.{25,}\s+(?<srv>\S+)\s+(?<st>passed|failed)\s+test\s+(?<tt>.+?)\s*$'

  $phase=$null; $server=$null; $test=$null; $buf=@(); $out=@()

  foreach($line in ($s -split "\r?\n")){

    $m = [regex]::Match($line, $rePhase)
    if($m.Success){
      $p = $m.Groups['p'].Value
      if($p -match '^Doing .* tests$'){ $phase = $p; continue }
    }

    $m = [regex]::Match($line, $reServer)
    if($m.Success){ $server = $m.Groups['s'].Value; continue }

    $m = [regex]::Match($line, $reStart)
    if($m.Success){
      $test = $m.Groups['t'].Value
      $buf  = @(); $buf += $line
      continue
    }

    if($test){
      $buf += $line
      $m = [regex]::Match($line, $reEnd)
      if($m.Success){
        $st = $m.Groups['st'].Value
        $tt = $m.Groups['tt'].Value
        if($st -eq 'failed' -and $tt -eq $test){
          $block = ($buf -join "`r`n")
          $out += [pscustomobject]@{
            Phase       = $phase
            Server      = $server
            Test        = $test
            Path        = ('{0} -> {1} -> Starting test: {2}' -f $phase,$server,$test)
            Status      = $st
            FailureLine = $line
            BlockText   = $block
          }
        }
        $test = $null; $buf = @()
      }
    }
  }
  $out
}

function HealthTest-Dcdiag {
<#
Description: Runs DCDIAG and reports failing basic and extended Active Directory diagnostics.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: dcdiag.exe.
#>

    write-progress "Runing DCDIAG /c /v"
    $AllTestResults = Get-DcDiagFailures -Comprehensive
    if($AllTestResults){
      write-progress "Runing DCDIAG /v to find out if the failure is in the basic tests"
      $BasicTestResults = Get-DcDiagFailures
      $AllTestResults | %{
          $testName = $_.failureline -replace '^[ .]*'
          $interesting_lines = Get-CompressedDcDiagInterestingLines -BlockText $_.BlockText
          if($_.Test -in $BasicTestResults.Test){
            if ($testName -like '*DFSREvent*' -or $testName -like '*SystemLog*') {
                Write-Warning "[NOTICE] 'DCDIAG /v' reports a failure in this basic test that examines the event log: $testName`nSince this test fails when warnings/errors appear in the event log, false positives are likely.`nRun DCDIAG /v, search for '$testName' and examine the detailed report above it.`nBelow are lines from that report that contain words like error/fail:`n$interesting_lines"
            } else {
                Write-Warning "[FAILURE] 'DCDIAG /v' reports a failure in this basic test: $testName`nRun DCDIAG /v, search for '$testName' and examine the detailed report above it.`nBelow are lines from that report that contain words like error/fail:`n$interesting_lines"
            }
          } else {
            Write-Warning "[WARNING] 'DCDIAG /c /v' reports a failure in this extra test: $testName`nRun DCDIAG /c /v (do include the /c to run extra tests), search for '$testName' and examine the detailed report above it.`nBelow are lines from that report that contain words like error/fail:`n$interesting_lines"
          }
      }
      return
    }
  Write-Warning "[PASS] DCDIAG /c reports no failures."
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-Dcdiag
}
