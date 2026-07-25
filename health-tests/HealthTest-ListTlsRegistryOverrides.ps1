# HostRequirement: All

if (-not (Get-Command -Name 'Get-ExplicitTlsRegistryValues' -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'helper-regarding-tls-registry.ps1')
}

function HealthTest-ListTlsRegistryOverrides {
<#
Description: Lists explicit Schannel and Windows cryptography registry settings for policy review.
AppliesTo: All
Scope: Computer
Category: Audit/Compliance/Informational
Impact: low
Tags: Policy
Uses: helper-regarding-tls-registry.ps1.

Policy identity: registry path and value name. The mutable registry type and value
are shown in comments but excluded from the finding title so its hash remains stable.
The presence of an override is normally a NOTICE, not evidence that it is insecure.
Invalid types or values and registry inspection failures are WARNING findings.
Policy baseline version: 1
#>
    $findings = New-Object 'System.Collections.Generic.List[string]'

    function Add-TlsOverrideFinding {
        param(
            [Parameter(Mandatory = $true)]
            [object]$Info,

            [Parameter(Mandatory = $true)]
            [string]$Category,

            [Parameter(Mandatory = $true)]
            [string]$Effect,

            [Parameter(Mandatory = $true)]
            [string]$Review,

            [AllowEmptyString()]
            [string]$ValidationIssue = ''
        )

        $level = 'NOTICE'
        if (-not [string]::IsNullOrWhiteSpace($ValidationIssue)) {
            $level = 'WARNING'
        }

        $displayValue = ConvertTo-TlsRegistryDisplayValue -Value $Info.Value
        $commentLines = @(
            "Category: $Category.",
            "Registry type: $($Info.Kind).",
            "Configured value: $displayValue.",
            "Effect: $Effect"
        )

        if (-not [string]::IsNullOrWhiteSpace($ValidationIssue)) {
            $commentLines += "Configuration issue: $ValidationIssue"
        }

        $commentLines += "Review: $Review"
        $commentLines += (
            'Schannel registry changes can require affected services to restart or the computer to reboot ' +
            'before every application uses the new configuration.'
        )

        [void]$findings.Add(
            "[$level] TLS registry override: Path='$($Info.Path)'; Name='$($Info.Name)'`n" +
            ($commentLines -join "`n")
        )
    }

    function Add-TlsInspectionFailure {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Identity,

            [Parameter(Mandatory = $true)]
            [string]$ErrorMessage
        )

        [void]$findings.Add(
            "[WARNING] TLS registry inspection failed: $Identity`n" +
            "The test could not determine whether an explicit setting exists at this location.`n" +
            "Error: $ErrorMessage"
        )
    }

    $sslPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Cryptography\Configuration\SSL\00010002'
    $policyValues = @(
        [pscustomobject]@{
            Name = 'Functions'
            Category = 'Schannel cipher-suite policy'
            Effect = 'A custom cipher-suite priority overrides the Windows default order.'
            Review = 'Confirm that the complete list is supported by this Windows version and contains only organization-approved cipher suites.'
        },
        [pscustomobject]@{
            Name = 'EccCurves'
            Category = 'Schannel ECC-curve policy'
            Effect = 'A custom elliptic-curve priority overrides the Windows default order.'
            Review = 'Confirm that the complete curve list is supported by this Windows version and matches the organization baseline.'
        }
    )

    foreach ($policyValue in $policyValues) {
        try {
            $info = Get-TlsRegistryValueInfo -Path $sslPolicyPath -Name $policyValue.Name
            if (-not $info.Exists) {
                continue
            }

            $validationIssue = ''
            if ($info.Kind -notin @('String', 'MultiString')) {
                $validationIssue = (
                    "The policy value uses registry type '$($info.Kind)'; expected String or MultiString."
                )
            }

            Add-TlsOverrideFinding -Info $info -Category $policyValue.Category -Effect $policyValue.Effect -Review $policyValue.Review -ValidationIssue $validationIssue
        }
        catch {
            Add-TlsInspectionFailure -Identity "Path='$sslPolicyPath'; Name='$($policyValue.Name)'" -ErrorMessage $_.Exception.Message
        }
    }

    $protocolRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols'
    $protocols = @('SSL 2.0', 'SSL 3.0', 'TLS 1.0', 'TLS 1.1', 'TLS 1.2', 'TLS 1.3')
    foreach ($protocol in $protocols) {
        foreach ($role in @('Client', 'Server')) {
            $path = Join-Path -Path (Join-Path -Path $protocolRoot -ChildPath $protocol) -ChildPath $role
            foreach ($valueName in @('Enabled', 'DisabledByDefault')) {
                try {
                    $info = Get-TlsRegistryValueInfo -Path $path -Name $valueName
                    if (-not $info.Exists) {
                        continue
                    }

                    $validationIssue = ''
                    $effect = "An explicit $protocol $role $valueName setting overrides part of the Windows default protocol behavior."
                    if ($info.Kind -ne 'DWord') {
                        $validationIssue = (
                            "The protocol value uses registry type '$($info.Kind)'; expected DWord."
                        )
                    }
                    else {
                        $number = [uint32]([int64]$info.Value -band 0xffffffffL)
                        if ($valueName -eq 'Enabled') {
                            if ($number -eq 0) {
                                $effect = "$protocol is explicitly unavailable to Schannel $role applications."
                            }
                            else {
                                $effect = "$protocol is explicitly available to Schannel $role applications."
                            }
                        }
                        elseif ($number -eq 0) {
                            $effect = "$protocol is explicitly available by default to Schannel $role applications."
                        }
                        elseif ($number -eq 1) {
                            $effect = "$protocol is explicitly excluded from default use by Schannel $role applications."
                        }
                        else {
                            $validationIssue = "DisabledByDefault is $number; expected 0 or 1."
                        }
                    }

                    $review = (
                        'HealthTest-SchanelBaseline evaluates whether this setting produces the intended secure posture. ' +
                        'Confirm that the override is still required by current applications and policy.'
                    )
                    Add-TlsOverrideFinding -Info $info -Category 'Schannel protocol policy' -Effect $effect -Review $review -ValidationIssue $validationIssue
                }
                catch {
                    Add-TlsInspectionFailure -Identity "Path='$path'; Name='$valueName'" -ErrorMessage $_.Exception.Message
                }
            }
        }
    }

    $schannelRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL'
    $algorithmRoots = @(
        (Join-Path -Path $schannelRoot -ChildPath 'Ciphers'),
        (Join-Path -Path $schannelRoot -ChildPath 'Hashes'),
        (Join-Path -Path $schannelRoot -ChildPath 'KeyExchangeAlgorithms')
    )

    foreach ($algorithmRoot in $algorithmRoots) {
        try {
            foreach ($info in @(Get-ExplicitTlsRegistryValues -RootPath $algorithmRoot)) {
                $effect = (
                    'An explicit cipher, hash, or key-exchange setting supplements or overrides Windows Schannel defaults.'
                )
                $review = (
                    'Confirm the setting is documented for this Windows version and remains necessary. ' +
                    'Prefer supported cipher-suite and ECC-curve policy mechanisms for modern Schannel configuration.'
                )
                Add-TlsOverrideFinding -Info $info -Category 'Schannel algorithm policy' -Effect $effect -Review $review
            }
        }
        catch {
            Add-TlsInspectionFailure -Identity "Root='$algorithmRoot'" -ErrorMessage $_.Exception.Message
        }
    }

    $fipsPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\FipsAlgorithmPolicy'
    try {
        $info = Get-TlsRegistryValueInfo -Path $fipsPath -Name 'Enabled'
        if ($info.Exists) {
            $validationIssue = ''
            $effect = 'Windows FIPS mode is explicitly configured.'

            if ($info.Kind -ne 'DWord') {
                $validationIssue = "The FIPS value uses registry type '$($info.Kind)'; expected DWord."
            }
            else {
                $number = [uint32]([int64]$info.Value -band 0xffffffffL)
                if ($number -eq 0) {
                    $info = $null
                }
                elseif ($number -eq 1) {
                    $effect = (
                        'Windows FIPS mode is enabled. This can be an intentional compliance requirement and can also affect application compatibility.'
                    )
                }
                else {
                    $validationIssue = "FIPS Enabled is $number; expected 0 or 1."
                }
            }

            if ($null -ne $info) {
                $review = (
                    'Confirm that the value is controlled by the intended local or domain policy. ' +
                    'Do not disable an intentional compliance setting solely because this notice exists.'
                )
                Add-TlsOverrideFinding -Info $info -Category 'Windows cryptography policy' -Effect $effect -Review $review -ValidationIssue $validationIssue
            }
        }
    }
    catch {
        Add-TlsInspectionFailure -Identity "Path='$fipsPath'; Name='Enabled'" -ErrorMessage $_.Exception.Message
    }

    if ($findings.Count -eq 0) {
        Write-Warning '[PASS] No explicit Schannel or Windows cryptography registry overrides were found'
        return
    }

    foreach ($finding in $findings) {
        Write-Warning $finding
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    HealthTest-ListTlsRegistryOverrides
}
