function ConvertTo-TlsRegistryDisplayValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value,

        [int]$MaximumLength = 500
    )

    if ($null -eq $Value) {
        return '<null>'
    }

    if ($Value -is [byte[]]) {
        $text = [BitConverter]::ToString($Value)
    }
    elseif ($Value -is [System.Array]) {
        if ($Value.Count -eq 0) {
            return '<empty>'
        }

        $text = @($Value) -join ', '
    }
    else {
        $text = [string]$Value
        if ([string]::IsNullOrEmpty($text)) {
            return '<empty>'
        }
    }

    if ($text.Length -gt $MaximumLength) {
        return $text.Substring(0, $MaximumLength - 16) + '... (truncated)'
    }

    return $text
}

function ConvertTo-ShortTlsRegistryPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RegistryKeyName
    )

    $prefix = 'HKEY_LOCAL_MACHINE\'
    if ($RegistryKeyName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'HKLM:\' + $RegistryKeyName.Substring($prefix.Length)
    }

    return $RegistryKeyName
}

function Get-TlsRegistryValueInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $result = [pscustomobject]@{
        Path   = $Path
        Name   = $Name
        Exists = $false
        Value  = $null
        Kind   = $null
    }

    if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) {
        return $result
    }

    $key = Get-Item -LiteralPath $Path -ErrorAction Stop
    if (@($key.GetValueNames()) -notcontains $Name) {
        return $result
    }

    $result.Exists = $true
    $result.Value = $key.GetValue(
        $Name,
        $null,
        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
    )
    $result.Kind = $key.GetValueKind($Name).ToString()

    return $result
}

function Get-ExplicitTlsRegistryValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    $results = New-Object 'System.Collections.Generic.List[object]'

    if (-not (Test-Path -LiteralPath $RootPath -ErrorAction Stop)) {
        return @()
    }

    $rootKey = Get-Item -LiteralPath $RootPath -ErrorAction Stop
    $keys = New-Object 'System.Collections.Generic.List[object]'
    [void]$keys.Add($rootKey)

    foreach ($childKey in @(Get-ChildItem -LiteralPath $RootPath -Recurse -ErrorAction Stop)) {
        [void]$keys.Add($childKey)
    }

    foreach ($key in $keys) {
        foreach ($valueName in @($key.GetValueNames())) {
            if ([string]::IsNullOrEmpty($valueName)) {
                continue
            }

            [void]$results.Add([pscustomobject]@{
                Path = ConvertTo-ShortTlsRegistryPath -RegistryKeyName $key.Name
                Name = $valueName
                Value = $key.GetValue(
                    $valueName,
                    $null,
                    [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
                )
                Kind = $key.GetValueKind($valueName).ToString()
            })
        }
    }

    return $results.ToArray()
}

function Get-TlsOperatingSystemInfo {
    [CmdletBinding()]
    param()

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    if ($null -eq $os) {
        throw 'Win32_OperatingSystem returned no data.'
    }

    if ($null -eq $os.PSObject.Properties['Version']) {
        throw 'Win32_OperatingSystem did not return Version.'
    }

    if ($null -eq $os.PSObject.Properties['ProductType']) {
        throw 'Win32_OperatingSystem did not return ProductType.'
    }

    $version = [version]$os.Version
    $caption = [string]$os.Caption
    if ([string]::IsNullOrWhiteSpace($caption)) {
        $caption = 'Windows'
    }

    $servicePackMajorVersion = 0
    if ($null -ne $os.PSObject.Properties['ServicePackMajorVersion']) {
        $servicePackMajorVersion = [int]$os.ServicePackMajorVersion
    }

    return [pscustomobject]@{
        Caption = $caption
        Version = $version
        Build = $version.Build
        IsServer = ([int]$os.ProductType -ne 1)
        ServicePackMajorVersion = $servicePackMajorVersion
    }
}

function Get-TlsProtocolOsDefault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('SSL 3.0', 'TLS 1.0', 'TLS 1.1', 'TLS 1.2', 'TLS 1.3')]
        [string]$Protocol,

        [Parameter(Mandatory = $true)]
        [object]$OperatingSystem
    )

    $version = [version]$OperatingSystem.Version
    $build = [int]$OperatingSystem.Build
    $isServer = [bool]$OperatingSystem.IsServer
    $servicePackMajorVersion = [int]$OperatingSystem.ServicePackMajorVersion

    $state = 'Unsupported'
    $reason = 'This protocol is not supported by this Windows version.'

    if ($Protocol -eq 'SSL 3.0') {
        if ($version.Major -lt 6) {
            $state = 'Unknown'
            $reason = 'The SSL 3.0 default is not modeled for this Windows version.'
        }
        elseif ($version.Major -eq 6 -or ($version.Major -eq 10 -and $build -lt 14393)) {
            $state = 'Enabled'
            $reason = 'SSL 3.0 is enabled by default on this Windows generation.'
        }
        else {
            $state = 'Disabled'
            $reason = 'SSL 3.0 is disabled by default on this Windows generation.'
        }
    }
    elseif ($Protocol -eq 'TLS 1.0') {
        if ($version.Major -lt 6) {
            $state = 'Unknown'
            $reason = 'The TLS 1.0 default is not modeled for this Windows version.'
        }
        elseif ($isServer -and $version.Major -ge 10 -and $build -ge 26100) {
            $state = 'Disabled'
            $reason = 'TLS 1.0 is disabled by default on Windows Server 2025 and later.'
        }
        else {
            $state = 'Enabled'
            $reason = 'TLS 1.0 is enabled by default on this Windows generation.'
        }
    }
    elseif ($Protocol -eq 'TLS 1.1') {
        if ($version.Major -lt 6) {
            $state = 'Unsupported'
            $reason = 'TLS 1.1 is not supported by this Windows version.'
        }
        elseif ($version.Major -eq 6 -and $version.Minor -eq 0) {
            if ($servicePackMajorVersion -ge 2) {
                $state = 'Disabled'
                $reason = 'TLS 1.1 is supported but disabled by default on Windows Server 2008 SP2.'
            }
            else {
                $state = 'Unsupported'
                $reason = 'TLS 1.1 requires Windows Server 2008 SP2 or later.'
            }
        }
        elseif ($version.Major -eq 6 -and $version.Minor -eq 1) {
            $state = 'Disabled'
            $reason = 'TLS 1.1 is supported but disabled by default on this Windows generation.'
        }
        elseif ($isServer -and $version.Major -ge 10 -and $build -ge 26100) {
            $state = 'Disabled'
            $reason = 'TLS 1.1 is disabled by default on Windows Server 2025 and later.'
        }
        else {
            $state = 'Enabled'
            $reason = 'TLS 1.1 is enabled by default on this Windows generation.'
        }
    }
    elseif ($Protocol -eq 'TLS 1.2') {
        if ($version.Major -lt 6) {
            $state = 'Unsupported'
            $reason = 'TLS 1.2 is not supported by this Windows version.'
        }
        elseif ($version.Major -eq 6 -and $version.Minor -eq 0) {
            if ($servicePackMajorVersion -ge 2) {
                $state = 'Disabled'
                $reason = 'TLS 1.2 is supported but disabled by default on Windows Server 2008 SP2.'
            }
            else {
                $state = 'Unsupported'
                $reason = 'TLS 1.2 requires Windows Server 2008 SP2 or later.'
            }
        }
        elseif ($version.Major -eq 6 -and $version.Minor -eq 1) {
            $state = 'Disabled'
            $reason = 'TLS 1.2 is supported but disabled by default on this Windows generation.'
        }
        else {
            $state = 'Enabled'
            $reason = 'TLS 1.2 is enabled by default on this Windows generation.'
        }
    }
    elseif ($Protocol -eq 'TLS 1.3') {
        $isSupported = $false
        if ($version.Major -gt 10) {
            $isSupported = $true
        }
        elseif ($version.Major -eq 10) {
            if ($isServer -and $build -ge 20348) {
                $isSupported = $true
            }
            elseif (-not $isServer -and $build -ge 22000) {
                $isSupported = $true
            }
        }

        if ($isSupported) {
            $state = 'Enabled'
            $reason = 'TLS 1.3 is supported and enabled by default on this Windows generation.'
        }
        else {
            $state = 'Unsupported'
            $reason = 'TLS 1.3 is supported starting with Windows Server 2022 and Windows 11.'
        }
    }

    return [pscustomobject]@{
        Protocol = $Protocol
        State = $state
        Reason = $reason
    }
}

function Get-TlsProtocolConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('SSL 3.0', 'TLS 1.0', 'TLS 1.1', 'TLS 1.2', 'TLS 1.3')]
        [string]$Protocol,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Client', 'Server')]
        [string]$Role,

        [Parameter(Mandatory = $true)]
        [object]$OperatingSystem
    )

    $protocolRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols'
    $path = Join-Path -Path (Join-Path -Path $protocolRoot -ChildPath $Protocol) -ChildPath $Role
    $enabledInfo = Get-TlsRegistryValueInfo -Path $path -Name 'Enabled'
    $disabledByDefaultInfo = Get-TlsRegistryValueInfo -Path $path -Name 'DisabledByDefault'
    $osDefault = Get-TlsProtocolOsDefault -Protocol $Protocol -OperatingSystem $OperatingSystem

    $issues = New-Object 'System.Collections.Generic.List[string]'
    $availability = $osDefault.State
    $availabilitySource = 'OS default'
    $defaultUse = $osDefault.State
    $defaultUseSource = 'OS default'

    if ($enabledInfo.Exists) {
        if ($enabledInfo.Kind -ne 'DWord') {
            [void]$issues.Add(
                "Enabled has registry type '$($enabledInfo.Kind)' instead of DWord."
            )
            $availability = 'Indeterminate'
            $availabilitySource = 'Invalid Enabled value'
        }
        else {
            $enabledNumber = [uint32]([int64]$enabledInfo.Value -band 0xffffffffL)
            if ($enabledNumber -eq 0) {
                $availability = 'Disabled'
                $availabilitySource = 'Enabled=0'
            }
            elseif ($osDefault.State -eq 'Unsupported') {
                $availability = 'Unsupported'
                $availabilitySource = "Enabled=$enabledNumber on an unsupported OS"
                [void]$issues.Add(
                    "$Protocol is explicitly enabled even though this Windows version does not support it."
                )
            }
            else {
                $availability = 'Enabled'
                $availabilitySource = "Enabled=$enabledNumber"
            }
        }
    }

    if ($disabledByDefaultInfo.Exists) {
        if ($disabledByDefaultInfo.Kind -ne 'DWord') {
            [void]$issues.Add(
                "DisabledByDefault has registry type '$($disabledByDefaultInfo.Kind)' instead of DWord."
            )
            $defaultUse = 'Indeterminate'
            $defaultUseSource = 'Invalid DisabledByDefault value'
        }
        else {
            $disabledNumber = [uint32]([int64]$disabledByDefaultInfo.Value -band 0xffffffffL)
            if ($disabledNumber -eq 0) {
                if ($osDefault.State -eq 'Unsupported') {
                    $defaultUse = 'Unsupported'
                }
                else {
                    $defaultUse = 'Enabled'
                }
                $defaultUseSource = 'DisabledByDefault=0'
            }
            elseif ($disabledNumber -eq 1) {
                $defaultUse = 'Disabled'
                $defaultUseSource = 'DisabledByDefault=1'
            }
            else {
                $defaultUse = 'Indeterminate'
                $defaultUseSource = "Invalid DisabledByDefault=$disabledNumber"
                [void]$issues.Add(
                    "DisabledByDefault is $disabledNumber; expected 0 or 1."
                )
            }
        }
    }

    if ($availability -eq 'Indeterminate' -or $defaultUse -eq 'Indeterminate') {
        $currentState = 'Indeterminate'
    }
    elseif ($osDefault.State -eq 'Unsupported') {
        $currentState = 'Unsupported'
    }
    elseif ($availability -eq 'Disabled') {
        $currentState = 'Disabled'
    }
    elseif ($defaultUse -eq 'Disabled') {
        $currentState = 'Available but disabled by default'
    }
    else {
        $currentState = 'Enabled'
    }

    if ($Protocol -in @('SSL 3.0', 'TLS 1.0', 'TLS 1.1')) {
        $expectedState = 'Disabled'
    }
    elseif ($osDefault.State -eq 'Unsupported') {
        $expectedState = 'Unsupported'
    }
    else {
        $expectedState = 'Enabled'
    }

    $isCompliant = ($issues.Count -eq 0 -and $currentState -eq $expectedState)

    return [pscustomobject]@{
        Protocol = $Protocol
        Role = $Role
        Path = $path
        CurrentState = $currentState
        ExpectedState = $expectedState
        IsCompliant = $isCompliant
        Availability = $availability
        AvailabilitySource = $availabilitySource
        DefaultUse = $defaultUse
        DefaultUseSource = $defaultUseSource
        OsDefaultState = $osDefault.State
        OsDefaultReason = $osDefault.Reason
        EnabledInfo = $enabledInfo
        DisabledByDefaultInfo = $disabledByDefaultInfo
        Issues = @($issues)
    }
}
