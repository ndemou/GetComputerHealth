<#
Standalone file for HealthTest-KerberosEncryptionTypes.
Generated during the repo-wide health-test split.
#>
# HostRequirement: DC

function HealthTest-KerberosEncryptionTypes{
<#
Description: Checks for AD accounts that still permit weak RC4 Kerberos encryption.
AppliesTo: DC
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-ADObject.
#>
  $objs=Get-ADObject -LDAPFilter '(msDS-SupportedEncryptionTypes=*)' -Properties msDS-SupportedEncryptionTypes,sAMAccountName,objectClass
  $bad_count = 0
  foreach($o in $objs){
    $v=[int]$o.'msDS-SupportedEncryptionTypes'
    if(($v -band 0x4) -ne 0){
        Write-Warning "[WARNING] RC4 permitted for $($o.objectClass): $($o.sAMAccountName)"
        $bad_count += 1
        if ($bad_count -gt 10) {
            Write-Warning "[WARNING] I will not report any more 'RC4 permitted for...' warnings"
            break
        }
    }
  }
  if($bad_count -eq 0){ Write-Warning "[PASS] No accounts permit RC4 in msDS-SupportedEncryptionTypes" }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-KerberosEncryptionTypes
}
