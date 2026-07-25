# HostRequirement: All

function HealthTest-FirewallEnabled {
<#
Description: Checks whether Windows Firewall profiles are enabled and the firewall service is available.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: High(Time)
Uses: Get-NetFirewallProfile.
#>

    Write-BasedOnTestResult "Is mpssvc (the firewall service) enabled?" -Test ((Get-Service -name mpssvc).status -eq 'Running')
    Get-NetFirewallProfile | ForEach-Object {
        Write-BasedOnTestResult "Is firewall enabled for the $($_.Name) profile?" -Test ($_.Enabled -eq 1) -comment "To enable firewall for *ALL* profiles run this:`nSet-NetFirewallProfile -Profile Domain,Private,Public -Enabled True"
    }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-FirewallEnabled
}
