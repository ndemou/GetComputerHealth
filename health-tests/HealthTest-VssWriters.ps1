<#
Standalone file for HealthTest-VssWriters.
Generated during the repo-wide health-test split.
#>
# HostRequirement: All

function HealthTest-VssWriters{
<#
Description: Checks whether all VSS writers report healthy stable states.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: vssadmin.exe.
#>

  $out=& vssadmin list writers 2>&1
  $bad=($out | Select-String -Pattern 'State: \d+ \((?i:Retryable error|Waiting for completion|Failed)\)')
  if($bad){
    foreach($b in $bad){ Write-Warning "[FAILURE] VSS writer not healthy`n$($b.Line)" }
  } else {
    Write-Warning "[PASS] All VSS writers report stable states"}
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-VssWriters
}
