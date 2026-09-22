<#
Helper functions for Custom Health Tests
#>


function Read-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter()]
        [string]$Encoding = 'UTF8'
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding $Encoding

    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

    $raw | ConvertFrom-Json
}


function Start-HealthTestVeeamRecentBackupsExist {
<#
.SYNOPSIS
Reports if recent enough Veeam VM backups exist and have reasonable sizes.
Expects at least one .VBK file and a fresh .VBM and either a fresh .VIB
or a fresh .VBK.

.DESCRIPTION
Supports configuration via either a JSON config file (-ConfigPath) or by
passing -RootPath directly.

If both are provided, values from -ConfigPath are used for credentials,
while -RootPath takes precedence for the backup path.

If the UNC path is already accessible through an existing SMB connection,
that connection is reused. A temporary PSDrive is created only when the
UNC path is not already accessible.

Config file examples:

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
        -ConfigPath 'C:\Get-ComputerHealth\config\HealthTest-RecentBackupsExist.config' `
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
        [int]$MaxAgeHoursForVibVbm = 23
    )

    if (
        [string]::IsNullOrWhiteSpace($ConfigPath) -and
        [string]::IsNullOrWhiteSpace($RootPath)
    ) {
        Write-Warning (
            "[FAILURE] Not running HealthTest-RecentBackupsExist because " +
            "neither -ConfigPath nor -RootPath was provided"
        )
        return
    }

    $username = ''
    $password = ''

    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
            Write-Warning (
                "[NOTICE] Not running HealthTest-RecentBackupsExist because " +
                "settings file does not exist: $ConfigPath"
            )
            return
        }

        try {
            $settings = Read-JsonFile -Path $ConfigPath -Encoding UTF8
        }
        catch {
            Write-Warning (
                "[FAILURE] Could not read configuration file $ConfigPath. " +
                "Error: $($_.Exception.Message)"
            )
            return
        }

        if ($null -eq $settings) {
            Write-Warning (
                "[FAILURE] Configuration file is empty or invalid: $ConfigPath"
            )
            return
        }

        if ([string]::IsNullOrWhiteSpace($RootPath)) {
            $RootPath = $settings.RootPath
        }

        try {
            $username = [string]$settings.Username
            $password = [string]$settings.Password
        }
        catch {
            $username = ''
            $password = ''
        }
    }

    if ([string]::IsNullOrWhiteSpace($RootPath)) {
        Write-Warning (
            "[FAILURE] Not running HealthTest-RecentBackupsExist because " +
            "no RootPath could be determined"
        )
        return
    }

    $driveName = $null
    $root = $RootPath

    try {
        # For UNC paths, first check whether the path is already accessible.
        # This allows an existing SMB connection to be reused and avoids:
        #
        # "Multiple connections to a server or shared resource by the same
        # user, using more than one user name, are not allowed."
        if ($RootPath -like '\\*') {
            $existingConnectionUsable = $false

            try {
                Get-ChildItem `
                    -LiteralPath $RootPath `
                    -Force `
                    -ErrorAction Stop |
                    Select-Object -First 1 |
                    Out-Null

                $existingConnectionUsable = $true
            }
            catch {
                $existingConnectionUsable = $false
            }

            if ($existingConnectionUsable) {
                Write-Output "Using existing SMB connection for $RootPath"
                $root = $RootPath
            }
            elseif (-not [string]::IsNullOrWhiteSpace($username)) {
                if ([string]::IsNullOrWhiteSpace($password)) {
                    Write-Warning (
                        "[FAILURE] A username was provided in $ConfigPath, " +
                        "but the password is empty"
                    )
                    return
                }

                $securePwd = ConvertTo-SecureString `
                    -String $password `
                    -AsPlainText `
                    -Force

                $cred = New-Object `
                    System.Management.Automation.PSCredential(
                        $username,
                        $securePwd
                    )

                $candidateDriveName = "UNC$(Get-Random -Minimum 1000 -Maximum 9999)"

                Write-Output (
                    "Creating temporary PSDrive $candidateDriveName for " +
                    "$RootPath using credentials from $ConfigPath"
                )

                try {
                    New-PSDrive `
                        -Name $candidateDriveName `
                        -PSProvider FileSystem `
                        -Root $RootPath `
                        -Credential $cred `
                        -Scope Global `
                        -ErrorAction Stop |
                        Out-Null

                    # Only assign driveName after successful creation.
                    # This prevents the finally block from attempting to
                    # remove a drive that was never created.
                    $driveName = $candidateDriveName
                    $root = "$driveName`:\"
                }
                catch {
                    $errorMessage = $_.Exception.Message

                    if ($errorMessage -match 'Multiple connections') {
                        Write-Warning (
                            "[FAILURE] An SMB connection to the server hosting " +
                            "$RootPath already exists under different credentials, " +
                            "but that connection cannot access the requested path. " +
                            "Disconnect the conflicting SMB connection or use the " +
                            "same credentials. Error: $errorMessage"
                        )
                    }
                    else {
                        Write-Warning (
                            "[FAILURE] Could not create a temporary PSDrive for " +
                            "$RootPath. Error: $errorMessage"
                        )
                    }

                    return
                }
            }
            else {
                $authHint = if ($ConfigPath) {
                    " Try adding a username and password to $ConfigPath."
                }
                else {
                    ''
                }

                Write-Warning (
                    "[FAILURE] Can't access $RootPath.$authHint"
                )
                return
            }
        }

        # VBM = metadata/index describing the backup chain.
        # VIB = incremental backup containing changes since the last backup.
        # VBK = full backup and baseline for incremental backups.
        $fresh_vbm = Get-RecentFilesConditional `
            -Path $root `
            -Pattern '*.vbm' `
            -MinBytes (10 * 1024) `
            -MaxAgeHours $MaxAgeHoursForVibVbm

        $fresh_vib = Get-RecentFilesConditional `
            -Path $root `
            -Pattern '*.vib' `
            -MinBytes (1 * 1024 * 1024 * 1024) `
            -MaxAgeHours $MaxAgeHoursForVibVbm

        $fresh_vbk = Get-RecentFilesConditional `
            -Path $root `
            -Pattern '*.vbk' `
            -MinBytes (10 * 1024 * 1024 * 1024) `
            -MaxAgeHours $MaxAgeHoursForVibVbm

        $atleast_one_vbk = Get-RecentFilesConditional `
            -Path $root `
            -Pattern '*.vbk' `
            -MinBytes (10 * 1024 * 1024 * 1024) `
            -MaxAgeHours $MaxAgeHoursForVBK

        $configHint = if ($ConfigPath) {
            "If you want to change the configuration edit: $ConfigPath"
        }
        else {
            ''
        }

        if (
            $fresh_vbm -and
            ($fresh_vib -or $fresh_vbk) -and
            $atleast_one_vbk
        ) {
            Write-Warning "[PASS] Found recent Veeam backups at $RootPath"
        }
        else {
            $directoryListing = try {
                Get-ChildItem `
                    -LiteralPath $root `
                    -ErrorAction Stop |
                    Out-String
            }
            catch {
                "Could not list directory contents: $($_.Exception.Message)"
            }

            Write-Warning (
                "[FAILURE] No recent Veeam backups found at: $RootPath" +
                "`n$configHint" +
                "`nfresh_vbm=$([bool]$fresh_vbm)" +
                ", fresh_vib=$([bool]$fresh_vib)" +
                ", fresh_vbk=$([bool]$fresh_vbk)" +
                ", atleast_one_vbk=$([bool]$atleast_one_vbk)" +
                "`nCondition for pass is: " +
                '($fresh_vbm -and ($fresh_vib -or $fresh_vbk) -and $atleast_one_vbk)' +
                "`n$directoryListing"
            )
        }
    }
    catch {
        Write-Warning (
            "[FAILURE] Unexpected error while checking Veeam backups at " +
            "$RootPath. Error: $($_.Exception.Message)"
        )
    }
    finally {
        if ($driveName) {
            Write-Output "Removing PSDrive $driveName"

            Remove-PSDrive `
                -Name $driveName `
                -Scope Global `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}


function Start-HealthTestVeeamRecentConfigBackupsExist {
<#
.SYNOPSIS
Reports if recent enough Veeam Configuration backups (.BCO) exist and have reasonable sizes.
#>
    [CmdletBinding()]
    param(
        [string]$RootPath,
        [int]$MaxAgeHours = 24
    )

    if (Get-RecentFilesConditional -Path $RootPath -Pattern '*.BCO' -MinBytes 25000 -MaxAgeHours $MaxAgeHours) {
        Write-Warning "[PASS] Found recent Configuration Backup in $RootPath"
    }
    else {
        Write-Warning "[FAILURE] No recent Configuration Backup in $RootPath"
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

.PARAMETER Path
One or more directories to search.

Example:
 -Path 'C:\Backups'
 -Path 'C:\Backups1','D:\Backups2'
 
.PARAMETER Pattern
    One or more DOS wildcards (e.g. "*.vbk", "*.vib").
    A single string or an array of strings is allowed.
    Files matching ANY of the patterns are counted (logical OR).

.PARAMETER MinBytes
    Minimum file size in bytes. Only files with Length -ge MinBytes are counted.
    If omitted, size is not checked.

.PARAMETER MaxAgeHours
    Only files with CreationTime within the last MaxAgeHours hours are counted.
    If omitted, age is not checked.

.PARAMETER MinCount
    Minimum number of matching files required (inclusive).
    Defaults to 1 if not specified.

.PARAMETER MaxCount
    Maximum number of matching files allowed (inclusive).
    Defaults to [int]::MaxValue if not specified.

.PARAMETER Recurse
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
    [Parameter(Mandatory)]
    [string[]] $Path,

    [string[]] $Pattern = '*',
    [Nullable[long]] $MinBytes,
    [Nullable[double]] $MaxAgeHours,
    [Nullable[int]] $MinCount,
    [Nullable[int]] $MaxCount,
    [switch] $Recurse
)

    if ($MinCount -eq $null) { $MinCount = 1 }
    if ($MaxCount -eq $null) { $MaxCount = [int]::MaxValue }

    $items = @()

    foreach ($onePath in $Path) {
        if ([string]::IsNullOrWhiteSpace($onePath)) { continue }
        if (-not (Test-Path -LiteralPath $onePath -PathType Container)) { continue }

        foreach ($p in $Pattern) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }

            $items += Get-ChildItem `
                -LiteralPath $onePath `
                -Filter $p `
                -File `
                -Recurse:$Recurse `
                -ErrorAction SilentlyContinue
        }
    }

    if ($items) {
        $items = $items | Sort-Object FullName -Unique

        if ($MinBytes -ne $null) {
            $items = $items | Where-Object { $_.Length -ge $MinBytes }
        }

        if ($MaxAgeHours -ne $null) {
            $cutoff = (Get-Date).AddHours(-$MaxAgeHours)
            $items = $items | Where-Object { $_.LastWriteTime -ge $cutoff }
        }
    }

    $count = ($items | Measure-Object).Count

    if ($count -ge $MinCount -and $count -le $MaxCount) {
        return ($items | Sort-Object -Property LastWriteTime)
    }

    return $null
}


function Get-HttpsCertificateStatus {
<#
.SYNOPSIS
Checks the TLS certificate presented by an HTTPS URL.

.EXAMPLE
Get-HttpsCertificateStatus 'https://google.com/'


Url           : https://google.com/
Status        : Valid
IsValid       : True
ExpiresAt     : 2026-11-27 10:04:48 +02:00
DaysRemaining : 70
NotBefore     : 2026-09-04 11:04:49 +03:00
Subject       : CN=*.google.com
Issuer        : CN=WE2, O=Google Trust Services, C=US
Thumbprint    : 6D8EE38ADF44FA74ED5B854060065A63B6085A8D
Protocol      : Tls13
StatusDetails : {}
Error         :

#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [string] $Url,

        [ValidateRange(1, 300)]
        [int] $TimeoutSeconds = 10
    )

    process {
        [uri] $uri = $null

        if (-not [uri]::TryCreate(
                $Url,
                [UriKind]::Absolute,
                [ref] $uri
            ) -or $uri.Scheme -ne 'https') {

            return [pscustomobject]@{
                Url           = $Url
                Status        = 'InvalidUrl'
                IsValid       = $false
                ExpiresAt     = $null
                DaysRemaining = $null
                Error         = 'Supply an absolute HTTPS URL.'
            }
        }

        $tcp = $null
        $tls = $null
        $certificate = $null

        $state = [pscustomobject]@{
            Certificate = $null
            PolicyErrors = [Net.Security.SslPolicyErrors]::None
            ChainStatus  = @()
        }

        try {
            $tcp = [Net.Sockets.TcpClient]::new()

            $connectTask = $tcp.ConnectAsync(
                $uri.DnsSafeHost,
                $uri.Port
            )

            if (-not $connectTask.Wait(
                    [TimeSpan]::FromSeconds($TimeoutSeconds)
                )) {
                throw [TimeoutException]::new(
                    'The TCP connection timed out.'
                )
            }

            [void] $connectTask.GetAwaiter().GetResult()

            $callback =
                [Net.Security.RemoteCertificateValidationCallback] {
                    param(
                        $sender,
                        $remoteCertificate,
                        $chain,
                        $policyErrors
                    )

                    if ($null -ne $remoteCertificate) {
                        $state.Certificate =
                            [Security.Cryptography.X509Certificates.X509Certificate2]::new(
                                $remoteCertificate
                            )
                    }

                    $state.PolicyErrors = $policyErrors

                    if ($null -ne $chain) {
                        $state.ChainStatus = @(
                            $chain.ChainStatus |
                                Where-Object Status -ne (
                                    [Security.Cryptography.X509Certificates.X509ChainStatusFlags]::NoError
                                ) |
                                ForEach-Object {
                                    $_.Status.ToString()
                                }
                        )
                    }

                    return $true
                }

            $tls = [Net.Security.SslStream]::new(
                $tcp.GetStream(),
                $false,
                $callback
            )

            $tls.ReadTimeout = $TimeoutSeconds * 1000
            $tls.WriteTimeout = $TimeoutSeconds * 1000
            $tls.AuthenticateAsClient($uri.DnsSafeHost)

            $certificate = $state.Certificate

            if ($null -eq $certificate) {
                throw 'The server did not supply a certificate.'
            }

            $now = [DateTimeOffset]::Now
            $notBefore = [DateTimeOffset] $certificate.NotBefore
            $expiresAt = [DateTimeOffset] $certificate.NotAfter
            $reasons = [Collections.Generic.List[string]]::new()

            if ($now -lt $notBefore) {
                $reasons.Add(
                    'The certificate is not valid yet.'
                )
            }

            if ($now -gt $expiresAt) {
                $reasons.Add(
                    'The certificate has expired.'
                )
            }

            if ($state.PolicyErrors -ne
                [Net.Security.SslPolicyErrors]::None) {
                $reasons.Add(
                    $state.PolicyErrors.ToString()
                )
            }

            foreach ($chainStatus in $state.ChainStatus) {
                $reasons.Add($chainStatus)
            }

            $isValid = $reasons.Count -eq 0

            [pscustomobject]@{
                Url           = $uri.AbsoluteUri
                Status        = if ($isValid) {
                    'Valid'
                }
                else {
                    'Invalid'
                }
                IsValid       = $isValid
                ExpiresAt     = $expiresAt
                DaysRemaining = [math]::Floor(
                    ($expiresAt - $now).TotalDays
                )
                NotBefore     = $notBefore
                Subject       = $certificate.Subject
                Issuer        = $certificate.Issuer
                Thumbprint    = $certificate.Thumbprint
                Protocol      = $tls.SslProtocol.ToString()
                StatusDetails = @($reasons)
                Error         = $null
            }
        }
        catch {
            [pscustomobject]@{
                Url           = $uri.AbsoluteUri
                Status        = 'ConnectionError'
                IsValid       = $false
                ExpiresAt     = $null
                DaysRemaining = $null
                NotBefore     = $null
                Subject       = $null
                Issuer        = $null
                Thumbprint    = $null
                Protocol      = $null
                StatusDetails = @()
                Error         =
                    $_.Exception.GetBaseException().Message
            }
        }
        finally {
            if ($null -ne $tls) {
                $tls.Dispose()
            }

            if ($null -ne $tcp) {
                $tcp.Dispose()
            }

            if ($null -ne $certificate) {
                $certificate.Dispose()
            }
        }
    }
}


function HealthTest-HttpsCertificate {
<#
Description: Checks configured HTTPS endpoints for certificate validation and upcoming expiration.
AppliesTo: All
Scope: Computer
Category: Availability/Server Down Signals, Configuration Hygiene & Best Practices
Impact: Medium(Network), Medium(Time)
Uses: Get-HttpsCertificateStatus.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Url,

        [ValidateRange(0, 3650)]
        [int]$WarnDays = 60,

        [ValidateRange(0, 3650)]
        [int]$FailDays = 30,

        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds = 10
    )

    if ($WarnDays -lt $FailDays) {
        Write-Warning (
            "[FAILURE] HTTPS certificate test configuration issue" +
            "`nWarnDays ($WarnDays) must be greater than or equal to " +
            "FailDays ($FailDays)."
        )
        return
    }

    $findingCount = 0

    foreach ($targetUrl in $Url) {
        try {
            $result = Get-HttpsCertificateStatus -Url $targetUrl -TimeoutSeconds $TimeoutSeconds
        }
        catch {
            $escapedUrl = ([string]$targetUrl).Replace("'", "''")

            Write-Warning (
                "[NOTICE] HTTPS certificate could not be inspected: " +
                "Url='$escapedUrl'" +
                "`nError: $($_.Exception.Message)"
            )

            $findingCount++
            continue
        }

        $reportedUrl = [string]$result.Url
        if ([string]::IsNullOrWhiteSpace($reportedUrl)) {
            $reportedUrl = [string]$targetUrl
        }

        $escapedUrl = $reportedUrl.Replace("'", "''")

        if ($result.Status -eq 'ConnectionError') {
            $errorText = [string]$result.Error

            if ([string]::IsNullOrWhiteSpace($errorText)) {
                $errorText = 'No error details were reported.'
            }

            Write-Warning (
                "[NOTICE] HTTPS certificate could not be inspected: " +
                "Url='$escapedUrl'" +
                "`nError: $errorText"
            )

            $findingCount++
            continue
        }

        if ($result.Status -eq 'InvalidUrl') {
            Write-Warning (
                "[FAILURE] HTTPS certificate test configuration issue: " +
                "Url='$escapedUrl'" +
                "`nError: $($result.Error)"
            )

            $findingCount++
            continue
        }

        if (-not [bool]$result.IsValid) {
            $detailLines = @(
                "Status: $($result.Status)."
            )

            foreach ($statusDetail in @($result.StatusDetails)) {
                if (-not [string]::IsNullOrWhiteSpace(
                        [string]$statusDetail
                    )) {
                    $detailLines += "Certificate status: $statusDetail"
                }
            }

            if ($null -ne $result.ExpiresAt) {
                $detailLines += "Expires: $($result.ExpiresAt)."
            }

            Write-Warning (
                "[FAILURE] HTTPS certificate is invalid: " +
                "Url='$escapedUrl'" +
                "`n" +
                ($detailLines -join "`n")
            )

            $findingCount++
            continue
        }

        if ($null -eq $result.ExpiresAt) {
            Write-Warning (
                "[FAILURE] HTTPS certificate expiration was not reported: " +
                "Url='$escapedUrl'"
            )

            $findingCount++
            continue
        }

        try {
            $expiresAt = [DateTimeOffset]$result.ExpiresAt
        }
        catch {
            Write-Warning (
                "[FAILURE] HTTPS certificate expiration is invalid: " +
                "Url='$escapedUrl'" +
                "`nReported value: '$($result.ExpiresAt)'."
            )

            $findingCount++
            continue
        }

        $remainingDays = [int][Math]::Ceiling(
            ($expiresAt - [DateTimeOffset]::Now).TotalDays
        )

        $formattedExpiry = $expiresAt.ToString(
            'yyyy-MM-dd HH:mm:ss zzz',
            [Globalization.CultureInfo]::InvariantCulture
        )

        if ($remainingDays -le $FailDays) {
            Write-Warning (
                "[FAILURE] HTTPS certificate will expire very soon: " +
                "Url='$escapedUrl'" +
                "`nExpires: $formattedExpiry." +
                "`nRemaining days: $remainingDays."
            )

            $findingCount++
        }
        elseif ($remainingDays -le $WarnDays) {
            Write-Warning (
                "[WARNING] HTTPS certificate will expire soon: " +
                "Url='$escapedUrl'" +
                "`nExpires: $formattedExpiry." +
                "`nRemaining days: $remainingDays."
            )

            $findingCount++
        }
    }

    if ($findingCount -eq 0) {
        Write-Warning (
            "[PASS] All $($Url.Count) HTTPS certificates are valid " +
            "for more than $WarnDays days"
        )
    }
}
