# HostRequirement: All

if (-not (Get-Command -Name 'Get-BaseServiceName' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helper-regarding-service-and-executable-resolution.ps1')
}

if (-not (Get-Command -Name 'Get-ServiceCodeIdentityText' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helper-regarding-service-and-executable-resolution.ps1')
}

if (-not (Get-Command -Name 'Get-ServiceExecutableFromRegistry' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helper-regarding-service-and-executable-resolution.ps1')
}

if (-not (Get-Command -Name 'Get-ServicePolicyFingerprint' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helper-regarding-service-and-executable-resolution.ps1')
}

if (-not (Get-Command -Name 'Get-ServiceVendors' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helper-regarding-service-and-executable-resolution.ps1')
}

if (-not (Get-Command -Name 'Normalize-ServicePolicyName' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helper-regarding-service-and-executable-resolution.ps1')
}

if (-not (Get-Command -Name 'Test-ServiceTypeLooksLikePerUserInstance' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helper-regarding-service-and-executable-resolution.ps1')
}

function HealthTest-ListServices {
<#
Description: Lists service definitions with payload publisher/hash context for policy review.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Tags: Policy
Uses: Get-ServiceVendors.

Policy identity: normalized service name, normalized resolved payload path, and code identity. Signed payloads use vendor identity; unsigned or invalid-signature payloads use payload hash when available. Runtime state, exit code, and service start result are not included.
Policy baseline version: 2
#>

    $ok = $true
    $CORE_MICROSOFT_VENDORS = @('Microsoft Windows','Microsoft Windows Publisher','Microsoft Corporation','Microsoft Windows Hardware Compatibility Publisher')
    $COMMON_VENDORS_FOR_WORKSTATIONS = @('Adobe Inc.', 'Cisco Systems, Inc.', 'Google LLC', 'Lenovo', 'Mozilla Corporation')
    $domainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole
    $isHostServer = ($domainRole  -in 3,4,5)
    $reportedServiceKeys = @{}
    $services = @(Get-ServiceVendors)
    $servicesByName = @{}
    $perUserMicrosoftGroupFlags = @{}
    $perUserMicrosoftGroupExampleNames = @{}
    foreach ($service in $services) {
        $servicesByName[$service.ServiceName] = $service
    }
    foreach ($service in $services) {
        $serviceType = $null
        if ($service.PSObject.Properties['ServiceType']) {
            $serviceType = $service.ServiceType
        }
        $baseServiceName = Get-BaseServiceName -ServiceName $service.ServiceName
        $baseService = $null
        if ($servicesByName.ContainsKey($baseServiceName)) {
            $baseService = $servicesByName[$baseServiceName]
        }
        $baseServiceExePath = $null
        if ($null -ne $baseService) {
            $baseServiceExePath = $baseService.ExePath
        } else {
            $baseServiceExePath = Get-ServiceExecutableFromRegistry -ServiceName $baseServiceName
        }
        $baseHasSameExecutablePath = $false
        if (($null -ne $baseServiceExePath) -and
            (-not [string]::IsNullOrWhiteSpace($service.ExePath)) -and
            (-not [string]::IsNullOrWhiteSpace($baseServiceExePath)) -and
            ($service.ExePath -ieq $baseServiceExePath)) {
            $baseHasSameExecutablePath = $true
        }
        $serviceTypeLooksPerUser = Test-ServiceTypeLooksLikePerUserInstance -ServiceType $serviceType
        $isPerUserServiceInstance = ($baseServiceName -ne $service.ServiceName) -and (($baseHasSameExecutablePath) -or (($null -ne $baseService) -and $serviceTypeLooksPerUser))
        $normalizedServiceName = $service.ServiceName
        if ($isPerUserServiceInstance) {
            $normalizedServiceName = $baseServiceName
        }
        $normalizedServiceName = $normalizedServiceName -replace '[0-9]+[.][0-9][0-9.]*$','[VERSION]'
        if ($service.Vendor -in $CORE_MICROSOFT_VENDORS) {
            $groupKey = "ms|$($service.Vendor)|$normalizedServiceName|$($service.ExePath)"
            if ($isPerUserServiceInstance) {
                $perUserMicrosoftGroupFlags[$groupKey] = $true
                if (-not $perUserMicrosoftGroupExampleNames.ContainsKey($groupKey)) {
                    $perUserMicrosoftGroupExampleNames[$groupKey] = $service.ServiceName
                }
            } elseif (-not $perUserMicrosoftGroupFlags.ContainsKey($groupKey)) {
                $perUserMicrosoftGroupFlags[$groupKey] = $false
            }
        }
    }
    $services | ForEach-Object {
        if ($_.ExeSHA256) {$extra_msg = " (SHA256 of '$($_.ExePath)' is $($_.ExeSHA256))"} else {$extra_msg=""}
        $serviceType = $null
        if ($_.PSObject.Properties['ServiceType']) {
            $serviceType = $_.ServiceType
        }
        $baseServiceName = Get-BaseServiceName -ServiceName $_.ServiceName
        $baseService = $null
        if ($servicesByName.ContainsKey($baseServiceName)) {
            $baseService = $servicesByName[$baseServiceName]
        }
        $baseServiceExePath = $null
        if ($null -ne $baseService) {
            $baseServiceExePath = $baseService.ExePath
        } else {
            $baseServiceExePath = Get-ServiceExecutableFromRegistry -ServiceName $baseServiceName
        }
        $baseHasSameExecutablePath = $false
        if (($null -ne $baseServiceExePath) -and
            (-not [string]::IsNullOrWhiteSpace($_.ExePath)) -and
            (-not [string]::IsNullOrWhiteSpace($baseServiceExePath)) -and
            ($_.ExePath -ieq $baseServiceExePath)) {
            $baseHasSameExecutablePath = $true
        }
        $serviceTypeLooksPerUser = Test-ServiceTypeLooksLikePerUserInstance -ServiceType $serviceType
        $isPerUserServiceInstance = ($baseServiceName -ne $_.ServiceName) -and (($baseHasSameExecutablePath) -or (($null -ne $baseService) -and $serviceTypeLooksPerUser))
        if ($isPerUserServiceInstance) {
            $trimmedServiceName = $baseServiceName
        } else {
            $trimmedServiceName = $_.ServiceName
        }
        $trimmedServiceName = $trimmedServiceName -replace '[0-9]+[.][0-9][0-9.]*$','[VERSION]'
        $policyServiceName = Normalize-ServicePolicyName -ServiceName $_.ServiceName -IsPerUserServiceInstance $isPerUserServiceInstance
        $codeIdentityText = Get-ServiceCodeIdentityText -Service $_
        $serviceFingerprint = Get-ServicePolicyFingerprint -NormalizedServiceName $policyServiceName -PayloadPath $_.ExePath -CodeIdentityText $codeIdentityText
        $ok = $false
        $comment = "Admin must verify if service is legit and needed. Service Description: '$($_.DisplayName)'`nExecutable: '$($_.ExePath)'.`nPolicy identity: $codeIdentityText."
        if ($_.PSObject.Properties['PayloadType'] -and (-not [string]::IsNullOrWhiteSpace($_.PayloadType))) {
            $comment = $comment + "`nPayload type: $($_.PayloadType)."
        }
        if ($isPerUserServiceInstance) {
            $comment = $comment + "`nFull service name: '$($_.ServiceName)'."
        }
        $displayServiceName = $trimmedServiceName
        $perUserNote = ""
        if ($_.Vendor -in $CORE_MICROSOFT_VENDORS) {
            $dedupeKey = "ms|$($_.Vendor)|$trimmedServiceName|$($_.ExePath)"
            if (-not $reportedServiceKeys.ContainsKey($dedupeKey)) {
                $reportedServiceKeys[$dedupeKey] = $true
                if ($perUserMicrosoftGroupFlags[$dedupeKey]) {
                    $displayServiceName = "$trimmedServiceName" + "_*"
                    $perUserNote = " (Per-user service of base service '$trimmedServiceName')"
                    if (-not $isPerUserServiceInstance) {
                        $fullPerUserServiceName = $perUserMicrosoftGroupExampleNames[$dedupeKey]
                        if ($fullPerUserServiceName) {
                            $comment = $comment + "`nFull service name: '$fullPerUserServiceName'."
                        }
                    }
                } else {
                    $displayServiceName = $trimmedServiceName
                    $perUserNote = ""
                }
                Write-Warning "[NOTICE] Found service: Vendor='$($_.Vendor)' Name='$displayServiceName'$perUserNote fingerprint=$serviceFingerprint$extra_msg`n$comment"
            }
        } elseif ((-not $isHostServer) -and ($_.Vendor -in $COMMON_VENDORS_FOR_WORKSTATIONS)) {
            if ($isPerUserServiceInstance) {
                $displayServiceName = "$trimmedServiceName" + "_*"
                $perUserNote = " (Per-user service of base service '$trimmedServiceName')"
            }
            Write-Warning "[NOTICE] Found service: Vendor='$($_.Vendor)' Name='$displayServiceName'$perUserNote fingerprint=$serviceFingerprint$extra_msg`n$comment"
        } else {
            if ($isPerUserServiceInstance) {
                $displayServiceName = "$trimmedServiceName" + "_*"
                $perUserNote = " (Per-user service of base service '$trimmedServiceName')"
            }
            Write-Warning "[WARNING] Found service: Vendor='$($_.Vendor)' Name='$displayServiceName'$perUserNote fingerprint=$serviceFingerprint$extra_msg`n$comment"
        }
    }
    if ($ok) {Write-Warning "[PASS] Found no services"}
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-ListServices
}
