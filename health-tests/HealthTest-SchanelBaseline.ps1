# HostRequirement: All

if (-not (Get-Command -Name 'Get-TlsProtocolConfiguration' -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'helper-regarding-tls-registry.ps1')
}

function HealthTest-SchanelBaseline {
<#
Description: Evaluates Client and Server Schannel protocol posture using explicit settings and Windows-version defaults.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: low
Tags: Essential
Uses: Get-CimInstance, helper-regarding-tls-registry.ps1.

The finding title identifies only the protocol and role so its hash remains stable
when registry values change. Baseline deviations that match the Windows default are
concise NOTICE findings. Explicit non-default deviations and invalid configurations
are detailed WARNING findings with raw values, registry types, and recommended action.
#>
    try {
        $operatingSystem = Get-TlsOperatingSystemInfo
    }
    catch {
        Write-Warning (
            "[FAILURE] Schannel operating system detection failed`n" +
            "The test cannot interpret absent protocol values without the Windows version and product type.`n" +
            "Error: $($_.Exception.Message)"
        )
        return
    }

    $protocols = @('SSL 3.0', 'TLS 1.0', 'TLS 1.1', 'TLS 1.2', 'TLS 1.3')
    $roles = @('Client', 'Server')
    $findingCount = 0

    foreach ($protocol in $protocols) {
        foreach ($role in $roles) {
            try {
                $configuration = Get-TlsProtocolConfiguration -Protocol $protocol -Role $role -OperatingSystem $operatingSystem
            }
            catch {
                $findingCount++
                Write-Warning (
                    "[FAILURE] TLS protocol inspection failed: Protocol='$protocol'; Role='$role'`n" +
                    "Registry path: 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$protocol\$role'.`n" +
                    "Error: $($_.Exception.Message)"
                )
                continue
            }

            if ($configuration.IsCompliant) {
                continue
            }

            $findingCount++

            $isOsDefaultDeviation = (
                @($configuration.Issues).Count -eq 0 -and
                $configuration.OsDefaultState -in @('Enabled', 'Disabled') -and
                $configuration.CurrentState -eq $configuration.OsDefaultState
            )

            if ($isOsDefaultDeviation) {
                $operatingSystemName = ([string]$operatingSystem.Caption).Trim()
                if ($operatingSystemName.StartsWith('Microsoft ')) {
                    $operatingSystemName = $operatingSystemName.Substring('Microsoft '.Length)
                }

                if ($configuration.ExpectedState -eq 'Disabled') {
                    if ($role -eq 'Client') {
                        $title = "Local CLIENT applications that depend on SCHANNEL may use $protocol."
                    }
                    else {
                        $title = "Local SERVER applications that depend on SCHANNEL may accept $protocol connections."
                    }

                    $explanation = (
                        "Although this is the $operatingSystemName default, we recommend hardening it " +
                        "unless $protocol is genuinely required by a legacy application."
                    )
                }
                else {
                    if ($role -eq 'Client') {
                        $title = "Local CLIENT applications that depend on SCHANNEL may not use $protocol."
                    }
                    else {
                        $title = "Local SERVER applications that depend on SCHANNEL may not accept $protocol connections."
                    }

                    $explanation = (
                        "Although this is the $operatingSystemName default, we recommend enabling $protocol " +
                        'to meet the hardened baseline.'
                    )
                }

                Write-Warning (
                    "[NOTICE] SCHANNEL hardening: $title`n" +
                    "$explanation`n" +
                    "Related Registry path: $($configuration.Path)"
                )
                continue
            }

            $enabledValue = '<absent>'
            $enabledKind = '<absent>'
            if ($configuration.EnabledInfo.Exists) {
                $enabledValue = ConvertTo-TlsRegistryDisplayValue -Value $configuration.EnabledInfo.Value
                $enabledKind = $configuration.EnabledInfo.Kind
            }

            $disabledValue = '<absent>'
            $disabledKind = '<absent>'
            if ($configuration.DisabledByDefaultInfo.Exists) {
                $disabledValue = ConvertTo-TlsRegistryDisplayValue -Value $configuration.DisabledByDefaultInfo.Value
                $disabledKind = $configuration.DisabledByDefaultInfo.Kind
            }

            $issueLines = @()
            foreach ($issue in @($configuration.Issues)) {
                $issueLines += "Configuration issue: $issue"
            }

            if ($protocol -in @('SSL 3.0', 'TLS 1.0', 'TLS 1.1')) {
                $impact = (
                    "$protocol remains available to Schannel $role applications. " +
                    'Applications that explicitly request it may still negotiate the legacy protocol.'
                )
                $recommendedAction = (
                    "Confirm that no application still depends on $protocol, then set Enabled=0 (DWord) " +
                    "and DisabledByDefault=1 (DWord) under the registry path below."
                )
            }
            elseif ($configuration.ExpectedState -eq 'Unsupported') {
                $impact = (
                    "$protocol is not supported by this Windows version. An enabling override is ineffective " +
                    'or unsafe and can mislead administrators about the available protocol posture.'
                )
                $recommendedAction = (
                    "Remove the unsupported $protocol enabling override. Upgrade Windows if this protocol is required."
                )
            }
            else {
                $impact = (
                    "$protocol is not fully available by default to Schannel $role applications. " +
                    'Connections that require this modern protocol can fail or fall back to an older protocol.'
                )
                $recommendedAction = (
                    "Remove the blocking override or set Enabled=1 (DWord) and " +
                    'DisabledByDefault=0 (DWord) under the registry path below.'
                )
            }

            $commentLines = @(
                "Current state: $($configuration.CurrentState).",
                "Expected state: $($configuration.ExpectedState).",
                "Availability: $($configuration.Availability) ($($configuration.AvailabilitySource)).",
                "Use by default: $($configuration.DefaultUse) ($($configuration.DefaultUseSource)).",
                "Enabled: $enabledValue (registry type: $enabledKind).",
                "DisabledByDefault: $disabledValue (registry type: $disabledKind).",
                "Windows default: $($configuration.OsDefaultState). $($configuration.OsDefaultReason)",
                "Operating system: $($operatingSystem.Caption) $($operatingSystem.Version).",
                "Registry path: '$($configuration.Path)'."
            )
            $commentLines += $issueLines
            $commentLines += "Impact: $impact"
            $commentLines += "Recommended action: $recommendedAction"
            $commentLines += (
                'After changing Schannel settings, restart affected services or reboot, then test both inbound ' +
                'and outbound application connections.'
            )

            Write-Warning (
                "[WARNING] SCHANNEL hardening: protocol posture issue: Protocol='$protocol'; Role='$role'`n" +
                ($commentLines -join "`n")
            )
        }
    }

    if ($findingCount -eq 0) {
        Write-Warning (
            '[PASS] Schannel protocol posture matches the baseline for Client and Server roles ' +
            "on $($operatingSystem.Caption) $($operatingSystem.Version)"
        )
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    HealthTest-SchanelBaseline
}
