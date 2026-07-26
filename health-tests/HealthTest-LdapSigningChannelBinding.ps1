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
        $commentLines = @(
            "Current state: LDAPServerIntegrity=$sign; LdapEnforceChannelBinding=$cb."
        )

        if ($sign -lt 1) {
            $commentLines += (
                'Related domain policy path: Computer Configuration\Policies\Windows Settings\Security Settings\' +
                'Local Policies\Security Options\Domain controller: LDAP server signing requirements.'
            )
        }

        if ($cb -lt 1) {
            $commentLines += (
                'Related domain policy path: Computer Configuration\Policies\Windows Settings\Security Settings\' +
                'Local Policies\Security Options\Domain controller: LDAP server channel binding token requirements.'
            )
        }

        Write-Warning (
            "[NOTICE] LDAP hardening: signing and/or channel binding is not enforced`n" +
            ($commentLines -join "`n")
        )
    }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-LdapSigningChannelBinding
}
