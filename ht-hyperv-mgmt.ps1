<#
Hyper-V Management
#>

# Functions in this file are only going to be defined if the
# Microsoft-Hyper-V feature is enabled in this computer
if ((Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V).State -eq 'Enabled') {

function HealthTest-HyperVVMProperties {
<#
.SYNOPSIS
Checks Hyper VVM Properties

.DESCRIPTION
AppliesTo: Server
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-VM.
FalsePositives: None.
#>
    # For Hyper-V hosts put here the expected values for these VM properties
    $EXPECTED_VALUES_FOR_VM_PROPERTIES = @{
        ReplicationHealth        = 'Normal'
        Status                   = 'Operating normally'
        PrimaryOperationalStatus = 'Ok'
        Heartbeat                = 'Ok*'
        AutomaticStartAction     = 'Start*'
        AutomaticStopAction      = 'Save'
        VMIntegrationService     = 'Guest Service Interface,Heartbeat,Key-Value Pair Exchange,Shutdown,Time Synchronization,VSS'
        Generation               = '2'
        Version                  = '9.0'
    }

    $vms = Get-VM | Where-Object { $_.State -eq 'Running' }
    foreach ($vm in $vms) {
        $EXPECTED_VALUES_FOR_VM_PROPERTIES.Keys | ForEach-Object {
            $prop_name = $_
            $expected_value = $EXPECTED_VALUES_FOR_VM_PROPERTIES[$prop_name]
            # write-host "Checking if $prop_name = $expected_value"

            if ($prop_name -eq 'VMIntegrationService') {
                # for VMIntegrationService we need to canonicalize the values
                $expected_value = ($expected_value -split ',' | % { $_.Trim() } | Sort-Object -Unique)  -join ','
                $actual_value   = ($vm.VMIntegrationService.Name | Sort-Object -Unique) -join ','
            } else {
                # for all other properties we have a simple value we expect them to have
                $actual_value = $vm.$prop_name
            }
            if ($actual_value -notlike $expected_value) {
                Write-Warning "[warning] VM $($vm.Name) has $prop_name='$actual_value' instead of '$expected_value'."
            }
        }
    }
}


function HealthTest-HyperVRunningVMs {
<#
.SYNOPSIS
Checks if all VMs that are set to auto-start are running

.DESCRIPTION
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-VM.
FalsePositives: None.
#>
    $ok=$true
    $all_vm = Get-VM
    $all_vm |?{$_.state -ne 'Running' -and $_.AutomaticStartAction -eq 'Start'} | %{
        Write-Warning "[failure] VM $($_.name) should be running but is not"
        $ok=$false
    }
    if ($all_vm |?{$_.AutomaticStartAction -eq 'Start'}) {
        if ($ok) {Write-Warning "[pass] All VMs that are set to always auto-start are running"}
    } else {
        Write-Warning "[info] No VM is set to always auto-start"
    }
}

}