<#
Standalone file for HealthTest-UnconstrainedDelegationAccounts.
Generated during the repo-wide health-test split.
#>
# HostRequirement: DC

function HealthTest-UnconstrainedDelegationAccounts{
<#
Description: Checks for accounts that are configured for unconstrained delegation.
AppliesTo: DC
Scope: Domain
Category: Security & Stability Risks
Impact: Medium(Time)
Uses: Get-ADObject.
#>
  [CmdletBinding()] param([switch]$IncludeDomainControllers)

  $bitTrusted  = 524288    # 0x80000 TRUSTED_FOR_DELEGATION
  $bitDC       = 8192      # 0x2000  SERVER_TRUST_ACCOUNT

  if ($IncludeDomainControllers) {
    $ldap = "(&(|(objectClass=user)(objectClass=computer))(userAccountControl:1.2.840.113556.1.4.803:=$bitTrusted))"
  } else {
    $ldap = "(&(|(objectClass=user)(objectClass=computer))(userAccountControl:1.2.840.113556.1.4.803:=$bitTrusted)(!(userAccountControl:1.2.840.113556.1.4.803:=$bitDC)))"
  }

  $objs = @(
    Get-ADObject -LDAPFilter $ldap -Properties sAMAccountName,objectClass,dnsHostName |
      Select-Object sAMAccountName,objectClass,dnsHostName
  )

  if ($objs.Count -gt 0) {

    foreach($o in $objs){

      # Determine if computer object (objectClass may be array or string)
      $isComputer = $false
      if ($o.objectClass -is [array]) {
        if ($o.objectClass -contains 'computer') { $isComputer = $true }
      } elseif ($o.objectClass -eq 'computer') {
        $isComputer = $true
      }

      # Build a friendly name
      if ($isComputer) {
        $name = $o.sAMAccountName.TrimEnd('$')
        if ($o.dnsHostName) {
          $name += " ($($o.dnsHostName))"
        }
        $cls = 'computer'
      } else {
        $name = $o.sAMAccountName
        $cls  = 'user'
      }

      Write-Warning "[FAILURE] Unconstrained delegation account found`n${cls}: $name"
    }

  } else {
    Write-Warning "[PASS] No unconstrained delegation accounts"
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-UnconstrainedDelegationAccounts
}
