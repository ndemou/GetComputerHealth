# HostRequirement: All

if (-not (Get-Command -Name 'Test-IsDomainJoinedComputer' -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'helpers-for-healthtests.ps1')
}

function HealthTest-FirewallEnabled {
<#
Description: Checks whether Windows Firewall profiles are enabled and the firewall service is available.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: High(Time)
Uses: Get-NetFirewallProfile.
#>

    $isDomainJoined = Test-IsDomainJoinedComputer
    $serviceComment = (
        "Related service: 'mpssvc'. Restore the Windows Defender Firewall service to its supported startup " +
        'configuration and start it.'
    )
    $firewallService = Get-Service -Name mpssvc
    if ($firewallService.Status -eq 'Running') {
        Write-Warning '[PASS] Windows Firewall service is running'
    } else {
        Write-Warning "[FAILURE] Windows Firewall service is not running`n$serviceComment"
    }

    Get-NetFirewallProfile | ForEach-Object {
        if ($isDomainJoined) {
            $configurationReference = (
                'Related domain policy path: Computer Configuration\Policies\Windows Settings\Security Settings\' +
                "Windows Defender Firewall with Advanced Security.`n" +
                "Open Windows Defender Firewall Properties and enable Firewall state on the $($_.Name) Profile tab."
            )
        } else {
            $configurationReference = (
                "Recommended local command: Set-NetFirewallProfile -Profile $($_.Name) -Enabled True"
            )
        }

        if ($_.Enabled -eq 1) {
            Write-Warning "[PASS] Windows Firewall is enabled for the $($_.Name) profile"
        } else {
            Write-Warning "[FAILURE] Windows Firewall is disabled for the $($_.Name) profile`n$configurationReference"
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-FirewallEnabled
}
