<#
Standalone file for HealthTest-TrustsVerify.
Generated during the repo-wide health-test split.
#>
# HostRequirement: DC

function HealthTest-TrustsVerify{
<#
Description: Verifies Active Directory trusts and reports any trust validation failures.
AppliesTo: DC
Scope: Forest
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: netdom.exe, Get-ADTrust, dcdiag.exe.
#>
  $trusts=Get-ADTrust -Filter * -ErrorAction Stop
  if(-not $trusts){ Write-Warning "[PASS] No inter-domain trusts configured"; return }
  $bad=$false
  foreach($t in $trusts){
    $r=& netdom.exe trust $t.TargetName /domain:$($t.Source) /verify 2>&1
    if($LASTEXITCODE -ne 0){ $bad=$true; Write-Warning "[FAILURE] Trust verification failed`n$($t.Source) -> $($t.TargetName): $r" }
  }
  if(-not $bad){ Write-Warning "[PASS] All domain trusts verify successfully" }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-TrustsVerify
}
