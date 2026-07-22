<#
Standalone file for HealthTest-ListInstalledPrograms.
Generated during the repo-wide health-test split.
#>
# HostRequirement: All

function Get-InstalledSW {
    [CmdletBinding()]
    param ()

    $installedSoftware = [System.Collections.Generic.List[PSCustomObject]]::new()
    $registryTargets = @(
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry64; Scope = 'Machine'; Arch = '64-bit' },
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry32; Scope = 'Machine'; Arch = '32-bit' },
        @{ Hive = [Microsoft.Win32.RegistryHive]::CurrentUser;  View = [Microsoft.Win32.RegistryView]::Default;    Scope = 'User';    Arch = 'Native' }
    )
    $baseKeyPath = "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"

    foreach ($target in $registryTargets) {
        try {
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($target.Hive, $target.View)
            $uninstallKey = $baseKey.OpenSubKey($baseKeyPath)
            if ($uninstallKey) {
                foreach ($subKeyName in $uninstallKey.GetSubKeyNames()) {
                    $appKey = $uninstallKey.OpenSubKey($subKeyName)
                    if (-not $appKey) { continue }
                    $displayName = $appKey.GetValue("DisplayName") -as [string]
                    if ([string]::IsNullOrWhiteSpace($displayName)) { $appKey.Close(); continue }
                    $rawDate = $appKey.GetValue("InstallDate") -as [string]
                    $parsedDate = $null
                    if ($rawDate -match '^\d{8}$') {
                        try { $parsedDate = [datetime]::ParseExact($rawDate, 'yyyyMMdd', $null) } catch { }
                    }
                    $installedSoftware.Add([PSCustomObject]@{
                        Name            = $displayName.Trim()
                        Version         = $appKey.GetValue("DisplayVersion") -as [string]
                        Publisher       = $appKey.GetValue("Publisher") -as [string]
                        InstallDate     = $parsedDate
                        Source          = "Registry"
                        Scope           = $target.Scope
                        Architecture    = $target.Arch
                        RegistryKeyName = $subKeyName
                    })
                    $appKey.Close()
                }
                $uninstallKey.Close()
            }
            $baseKey.Close()
        } catch {
            Write-Verbose "Failed to read registry target $($target.Hive) ($($target.Arch)): $_"
        }
    }

    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        try {
            $appxPackages = Get-AppxPackage -ErrorAction Stop
            foreach ($app in $appxPackages) {
                $installedSoftware.Add([PSCustomObject]@{
                    Name            = $app.Name
                    Version         = $app.Version
                    Publisher       = $app.Publisher
                    InstallDate     = $null
                    Source          = "Appx"
                    Scope           = "User"
                    Architecture    = $app.Architecture.ToString()
                    RegistryKeyName = $null
                })
            }
        } catch {
            Write-Verbose "Failed to query Appx packages: $_"
        }
    }

    $installedSoftware
}

function Get-NormalizedSoftwareName {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$Name
    )
    process {
        $cleanName = $Name
        $cleanName = $cleanName -replace '(?i)\b(version|release|preview|edition)\b', ' '
        $cleanName = $cleanName -replace '(?i)\b(x64|x86|amd64|64-?bit|32-?bit)\b', ' '
        $cleanName = $cleanName -replace '\b(20\d{2}[-./]?\d{2}[-./]?\d{2}|\d{2}[-./]\d{2}[-./]20\d{2})\b', 'DATE'
        $cleanName = $cleanName -replace '(?i)\bv\d+(?:\.\d+)*(?:[a-z]\d+)?\b', 'VER'
        $cleanName = $cleanName -replace '\b\d+(?:\.\d+)+\b', 'VER'
        $cleanName = $cleanName -replace '(?i)\b(Update)\s+\d+\b', '$1 VER'
        $cleanName = $cleanName -replace '[\(\)\{\}\[\],]', ' '
        $cleanName = $cleanName -replace '\s-\s', ' '
        $cleanName = $cleanName -replace '\s+', ' '
        return $cleanName.Trim()
    }
}

function Test-IsMicrosoftInstalledSoftwareUpdate {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Name,

        [AllowNull()]
        [string]$Publisher
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }

    $publisherLooksMicrosoft = $false
    if (-not [string]::IsNullOrWhiteSpace($Publisher)) {
        $publisherLooksMicrosoft = $Publisher -match '(?i)\bmicrosoft(?:\s+corporation)?\b'
    }

    $nameLooksLikeMicrosoftUpdate = $Name -match '(?ix)
        \bKB\d{6,8}\b
        |
        \bSecurity\ Update\b
        |
        \bHotfix\b
        |
        \bCumulative\ Update\b
        |
        \bUpdate\ for\ Microsoft\b
        |
        \bGDR\s+\d+\s+for\s+SQL\s+Server\b
        |
        \bCU\d+\s+for\s+SQL\s+Server\b
    '

    if (-not $nameLooksLikeMicrosoftUpdate) { return $false }

    if ($publisherLooksMicrosoft) { return $true }

    return $Name -match '(?i)\b(SQL\s+Server|Microsoft)\b'
}

function Get-InstalledSoftwareFindingLevel {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Name,

        [AllowNull()]
        [string]$Publisher
    )

    if (Test-IsMicrosoftInstalledSoftwareUpdate -Name $Name -Publisher $Publisher) {
        return 'info'
    }

    $publisherLooksMicrosoft = $false
    if (-not [string]::IsNullOrWhiteSpace($Publisher)) {
        $publisherLooksMicrosoft = $Publisher -match '(?i)\bmicrosoft(?:\s+corporation)?\b'
    }

    if ($publisherLooksMicrosoft) {
        return 'notice'
    }

    return 'warning'
}

function Format-InstalledSoftwareInstallDate {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return '(not reported)'
    }

    if ($Value -is [datetime]) {
        return ([datetime]$Value).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    }

    return [string]$Value
}

function HealthTest-ListInstalledPrograms {
<#
Description: Reports installed software not present in the baseline inventory.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Tags: Policy
Uses: Get-InstalledSW, Get-NormalizedSoftwareName, Get-InstalledSoftwareFindingLevel.

Policy identity: normalized installed software name. Install date and discovery source are reported as detail but are not part of the finding headline.
Policy baseline version: 1
#>
    $seen = 0
    foreach ($sw in (Get-InstalledSW)) {
        $seen += 1
        $normalizedName = Get-NormalizedSoftwareName -Name $sw.Name
		if ($sw.Publisher -match 'CN=.*, ') {
    	    # Remove unneeded details from Publisher description. E.g.:
	        # "Microsoft Windows" instead of "CN=Microsoft Windows, O=Microsoft Corporation, L=..., S=..."
		    $publisher = $sw.Publisher -replace '^.*CN=([^,]+).*','$1'
		} else {
		    $publisher = $sw.Publisher
		}
        $installDateText = Format-InstalledSoftwareInstallDate -Value $sw.InstallDate
        $details = "Full program name: $($sw.Name); Publisher: $publisher; Install Date: $installDateText; Source: $($sw.Source); Scope: $($sw.Scope)"
        $level = Get-InstalledSoftwareFindingLevel -Name $sw.Name -Publisher $sw.Publisher
        Write-Warning "[$level] New installed software: $normalizedName`n$details"
    }

    if ($seen -eq 0) {
        Write-Warning "[PASS] No installed software entries discovered."
    }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-ListInstalledPrograms
}
