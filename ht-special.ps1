<#
Special
#>

function HealthTest-Dummy {
<#
.SYNOPSIS
Checks Dummy and flags unhealthy or non-baseline states by evaluating key signals from local/domain data sources and reporting pass/warn/fail outcomes.

.DESCRIPTION
Uses: PowerShell cmdlets used by this test.
AppliesTo: All Windows hosts.
TestScope: Computer.
Category: Primary: Audit / Compliance / Informational.
Impact: Medium.
FalsePositives: Environment-specific hardening baselines can intentionally differ.
#>
    Write-Output "Dummy debug message"
    Write-Warning "[info] Dummy info message"
    Write-Warning "[pass] Dummy pass message"
    Write-Warning "[notice] Dummy notice message"
    Write-Warning "[warning] Dummy warning message"
    Write-Warning "[failure] Dummy failure message"
}

function Start-HealthTestVeeamRecentBackupsExist{
<#
.SYNOPSIS
Tests if recent enough Veeam VM backups exist and have reasonable sizes and returns Log-objects.
Expects at least on .VBK file and a fresh .VBM and either a fresh .VIB or a fresh .VBK

.DESCRIPTION
Supports configuration via either a JSON config file (-ConfigPath) or by passing -RootPath directly.
If both are provided, values from -ConfigPath are used for credentials while -RootPath takes precedence
for the backup path.

Config file is json based. Examples:
	{
	  "RootPath": "\\\\10.1.2.3\\share\\path\\to\\Backups",
	  "Username": "foo",
	  "Password": "bar"
	}
Or:
	{
	  "RootPath": "C:\\path\\to\\Backups"
	}

.EXAMPLE

	Start-HealthTestVeeamRecentBackupsExist `
		-ConfigPath 'C:\it\config\HealthTest-RecentBackupsExist.config' `
		-MaxAgeHoursForVibVbm 23 `
		-MaxAgeHoursForVBK 480

.EXAMPLE
	Start-HealthTestVeeamRecentBackupsExist `
		-RootPath 'C:\path\to\Backups' `
		-MaxAgeHoursForVibVbm 23 `
		-MaxAgeHoursForVBK 480

#>
[CmdletBinding()]
param(
	[string]$ConfigPath,
	[string]$RootPath,
	[int]$MaxAgeHoursForVBK = 480,
	[int]$MaxAgeHoursForVibVbm=23
)

    if ([string]::IsNullOrWhiteSpace($ConfigPath) -and [string]::IsNullOrWhiteSpace($RootPath)) {
        Write-Warning "[failure] Not running HealthTest-RecentBackupsExist because neither -ConfigPath nor -RootPath was provided"
        return
    }

    $username = ""
    $password = ""

    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        if (-not (Test-Path -LiteralPath $ConfigPath)) {
            Write-Warning "[notice] Not running HealthTest-RecentBackupsExist because settings file does not exist: $ConfigPath"
            return
        }

        $settings = Read-JsonFile -Path $ConfigPath -Encoding UTF8

        if ([string]::IsNullOrWhiteSpace($RootPath)) {
            $RootPath = $settings.RootPath
        }

        try {
            $username = $settings.Username
            $password = $settings.Password
        } catch {}
    }

    if ([string]::IsNullOrWhiteSpace($RootPath)) {
        Write-Warning "[failure] Not running HealthTest-RecentBackupsExist because no RootPath could be determined"
        return
    }

    $driveName = $null
    $root      = $RootPath

    # Create a temp map drive for UNC paths
    if ($RootPath -like '\\*') {
        if ($username) {
            $securePwd = ConvertTo-SecureString -String $password -AsPlainText -Force
            $cred      = New-Object System.Management.Automation.PSCredential($username, $securePwd)

            $driveName = "UNC$(Get-Random -Minimum 1000 -Maximum 9999)"
            Write-Output "Creating temporary PSDrive $driveName for $RootPath using credentials from $secretsPath"
            New-PSDrive -Name $driveName -PSProvider FileSystem -Root $RootPath -Credential $cred -Scope Global -ErrorAction Stop | Out-Null

            $root = "$driveName`:\"
        } else {
            try {
                $null = Get-ChildItem $root
            } catch {
                $authHint = if ($ConfigPath) { " (try adding a username and password to config file $ConfigPath)" } else { "" }
                Write-Warning "[failure] Can't access $root$authHint"
                return
            }
        }
    }

    try {
        # VBM = metadata/index about the backups.
        # VIB = incremental backup (changes since last full).
        # VBK = full backup (also baseline for incremental ones).
        $fresh_vbm       = Get-RecentFilesConditional -Path $root -Pattern '*.vbm' -MinBytes (          10*1024) -MaxAgeHours $MaxAgeHoursForVibVbm
        $fresh_vib       = Get-RecentFilesConditional -Path $root -Pattern '*.vib' -MinBytes ( 1*1024*1024*1024) -MaxAgeHours $MaxAgeHoursForVibVbm
        $fresh_vbk       = Get-RecentFilesConditional -Path $root -Pattern '*.vbk' -MinBytes (10*1024*1024*1024) -MaxAgeHours $MaxAgeHoursForVibVbm
        $atleast_one_vbk = Get-RecentFilesConditional -Path $root -Pattern '*.vbk' -MinBytes (10*1024*1024*1024) -MaxAgeHours $MaxAgeHoursForVBK 

        $configHint = if ($ConfigPath) { "If you want to change the configuration edit: $ConfigPath" } else { "Used -RootPath directly (no config file)." }

        if ($fresh_vbm -and ($fresh_vib -or $fresh_vbk) -and $atleast_one_vbk) {
            Write-Warning "[pass] Found recent Veeam backups. $configHint"
        } else {
            Write-Warning "[failure] No recent Veeam backups found at: $RootPath`n" + ("$configHint`n" + `
                "fresh_vbm=$fresh_vbm, fresh_vib=$fresh_vib, fresh_vbk=$fresh_vbk, atleast_one_vbk=$atleast_one_vbk`n" + `
                "Condition for pass is: " + `
                '($fresh_vbm -and ($fresh_vib -or $fresh_vbk) -and $atleast_one_vbk)' + `
                (Get-ChildItem $root|Out-String))
        }
    }
    finally {
        if ($driveName) {
            Write-Output "Removing PSDrive $driveName"
            Remove-PSDrive -Name $driveName -ErrorAction SilentlyContinue
        }
    }
}


function Get-RecentFilesConditional {
<#
.SYNOPSIS
Tests whether a directory contains a number of recent files within given size and age bounds, and if it does returns them ordered by LastWriteTime.

.DESCRIPTION
Counts files in a directory that:
 - Match one or more DOS patterns (e.g. "*.vbk", "*.vib").
 - Are at least MinBytes in size (if specified).
 - Were created within the last MaxAgeHours hours (if specified).
It returns $true if the final count is between MinCount and MaxCount (inclusive), otherwise $false.

If the path does not exist, the function always returns $false, regardless of MinCount/MaxCount.

PARAMETERS
 -Path
    The directory to search. Must exist; otherwise the function returns $false.

 -Pattern
    One or more DOS wildcards (e.g. "*.vbk", "*.vib").
    A single string or an array of strings is allowed.
    Files matching ANY of the patterns are counted (logical OR).

 -MinBytes
    Minimum file size in bytes. Only files with Length -ge MinBytes are counted.
    If omitted, size is not checked.

 -MaxAgeHours
    Only files with CreationTime within the last MaxAgeHours hours are counted.
    If omitted, age is not checked.

 -MinCount
    Minimum number of matching files required (inclusive).
    Defaults to 1 if not specified.

 -MaxCount
    Maximum number of matching files allowed (inclusive).
    Defaults to [int]::MaxValue if not specified.

 -Recurse
    If supplied, search subfolders recursively; otherwise only the top-level folder is searched.

RETURN VALUE
    The matching files ordered by LastWriteTime, if their number is between MinCount
    and MaxCount (inclusive), otherwise $null. You can use the return value as a boolean
    because $null is falsy and 1 or more items are truthy

EXAMPLE
    # At least one .vbk in C:\Backups, >= 100 GB, created within the last 24 hours
    Get-RecentFilesConditional -Path 'C:\Backups' -Pattern '*.vbk' -MinBytes 100GB -MaxAgeHours 24

EXAMPLE
    # Any combination of .vbk or .vib files, >= 1 GB, in the last 12 hours, including subfolders
    Get-RecentFilesConditional -Path 'C:\Backups' -Pattern '*.vbk','*.vib' -MinBytes 1GB -MaxAgeHours 12 -Recurse

EXAMPLE
    # Check there are between 3 and 10 recent *.log files of any size in the last 2 hours
    Get-RecentFilesConditional -Path 'C:\Logs' -Pattern '*.log' -MaxAgeHours 2 -MinCount 3 -MaxCount 10

EXAMPLE
    # Treat "any files at all in the folder" as success (MinCount = 1 by default)
    Get-RecentFilesConditional -Path 'C:\SomeFolder'

EXAMPLE
    # Path does not exist: always returns $false, regardless of MinCount/MaxCount
    Get-RecentFilesConditional -Path 'C:\NotARealFolder' -MinCount 0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]  $Path,
    [string[]]                      $Pattern    = '*',
    [Nullable[long]]                $MinBytes,
    [Nullable[double]]              $MaxAgeHours,
    [Nullable[int]]                 $MinCount,
    [Nullable[int]]                 $MaxCount,
    [switch]                        $Recurse
)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    if ($MinCount -eq $null) { $MinCount = 1 }
    if ($MaxCount -eq $null) { $MaxCount = [int]::MaxValue }

    $items = @()
    foreach ($p in $Pattern) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $items += Get-ChildItem -LiteralPath $Path -Filter $p -File -Recurse:$Recurse -ErrorAction SilentlyContinue
    }

    if (-not $items) {
        $count = 0
        return ($count -ge $MinCount -and $count -le $MaxCount)
    }

    $items = $items | Sort-Object FullName -Unique

    if ($MinBytes -ne $null) {
        $items = $items | Where-Object { $_.Length -ge $MinBytes }
    }

    if ($MaxAgeHours -ne $null) {
        $cutoff = (Get-Date).AddHours(-$MaxAgeHours)
        $items = $items | Where-Object { $_.CreationTime -ge $cutoff }
    }

    $count = ($items | Measure-Object | Select-Object -ExpandProperty Count)

    if ($count -ge $MinCount -and $count -le $MaxCount) {
        return ($items | Sort-Object -Property LastWriteTime)
    } else {
        return $null
    }
}
