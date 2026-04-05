<#
Only for Hyper-V servers
#>

function HealthTest-HyperVRunningVMs {
<#
Description: Lists running Hyper-V virtual machines on the host.
AppliesTo: Server
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: Get-VM.
#>
    $ok=$true
    $all_vm = Get-VM
    $all_vm |?{$_.state -ne 'Running' -and $_.AutomaticStartAction -eq 'Start'} | %{
        Write-Warning "[FAILURE] VM $($_.name) should be running but is not"
        $ok=$false
    }
    if ($all_vm |?{$_.AutomaticStartAction -eq 'Start'}) {
        if ($ok) {Write-Warning "[PASS] All VMs that are set to always auto-start are running"}
    } else {
        Write-Warning "[info] No VM is set to always auto-start"
    }
}
