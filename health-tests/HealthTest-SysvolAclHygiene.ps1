<#
Standalone file for HealthTest-SysvolAclHygiene.
Generated during the repo-wide health-test split.
#>
# HostRequirement: DC

function HealthTest-SysvolAclHygiene{
<#
Description: Checks whether SYSVOL grants write access to overly broad principals.
AppliesTo: DC
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-Acl.
#>
  $path="C:\Windows\SYSVOL\sysvol"
  $acl=Get-Acl -Path $path
  $bad=$false
  foreach($ace in $acl.Access){
    $id=$ace.IdentityReference.Value
    $wr=($ace.FileSystemRights.ToString() -match 'Write|Modify|FullControl')
    if($wr -and ($id -match 'Everyone|Authenticated Users')){ $bad=$true; Write-Warning "[FAILURE] SYSVOL ACL too broad: $id has $($ace.FileSystemRights)" }
  }
  if(-not $bad){ Write-Warning "[PASS] SYSVOL does not grant write to broad principals (Everyone/Auth Users)" }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-SysvolAclHygiene
}
