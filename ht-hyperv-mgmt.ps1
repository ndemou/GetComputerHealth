<#
Hyper-V Management
#>

function HealthTest-HyperVVMProperties {
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
                Log-Warning "VM $($vm.Name) has $prop_name='$actual_value' instead of '$expected_value'."
            }
        }
    }
}


function HealthTest-HyperVRunningVMs {
    $ok=$true
    $all_vm = get-vm
    $all_vm |?{$_.state -ne 'Running' -and $_.AutomaticStartAction -eq 'Start'} | %{
        Log-failure "VM $($_.name) should be running but is not"
        $ok=$false
    }
    if ($all_vm |?{$_.AutomaticStartAction -eq 'Start'}) {
        if ($ok) {Log-Pass 'All VMs that are set to always auto-start are running'}
    } else {
        Log-info 'No VM is set to always auto-start'
    }
}
