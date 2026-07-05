<#
Standalone file for HealthTest-LdapSigningChannelBinding.
Generated during the repo-wide health-test split.
#>
# HostRequirement: DC

function HealthTest-LdapSigningChannelBinding {
<#
Description: Checks whether DC LDAP signing and channel binding enforcement are enabled.
AppliesTo: DC
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Tags: Essential
Uses: None.
#>
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'

    # Read all registry values in one shot (avoids repeated calls)
    $props = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue

    # LDAPServerIntegrity
    $signProp = $props.PSObject.Properties['LDAPServerIntegrity']
    $sign     = if ($signProp) { $signProp.Value } else { $null }

    # LdapEnforceChannelBinding
    $cbProp = $props.PSObject.Properties['LdapEnforceChannelBinding']
    $cb     = if ($cbProp) { $cbProp.Value } else { $null }

    # Bonus tip: normalize null -> 0 (disabled)
    $sign = [int]($sign + 0)
    $cb   = [int]($cb   + 0)

    if (($sign -ge 1) -and ($cb -ge 1)) {
        Write-Warning "[PASS] LDAP signing & channel binding enforced"
    } else {
        Write-Warning "[NOTICE] LDAP signing and/or channel binding not enforced`nLDAPServerIntegrity=$sign; LdapEnforceChannelBinding=$cb"
    }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-LdapSigningChannelBinding
}
