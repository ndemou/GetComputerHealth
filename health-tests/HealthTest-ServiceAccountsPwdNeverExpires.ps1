<#
Standalone file for HealthTest-ServiceAccountsPwdNeverExpires.
Generated during the repo-wide health-test split.
#>
# HostRequirement: DC

function HealthTest-ServiceAccountsPwdNeverExpires{
<#
Description: Checks for service accounts whose passwords are set to never expire.
AppliesTo: DC
Scope: Domain
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-ADUser.
#>
  $filter='(servicePrincipalName=*)'
  $objs=Get-ADUser -LDAPFilter $filter -Properties PasswordNeverExpires,PasswordLastSet
  $bad=@($objs | Where-Object {$_.PasswordNeverExpires -eq $true})
  if($bad.Count -gt 0){
    foreach($u in $bad){ Write-Warning "[FAILURE] Service account password set to never expire`n$($u.SamAccountName)" }
  } else {
    Write-Warning "[PASS] Service accounts have expiring passwords"
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-ServiceAccountsPwdNeverExpires
}
