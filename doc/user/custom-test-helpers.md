# Available Helpers for Custom Health Tests

*(Information for both users and developers)*

These helpers are **not** automatically dot-sourced by
`Get-ComputerHealth.ps1`.

If a custom test wants to use them, it should load them explicitly, for
example:

```powershell
. 'C:\IT\Get-ComputerHealth\bin\helpers-for-custom-ht.ps1'
```

Custom tests do currently run in the same PowerShell session as
`Get-ComputerHealth.ps1`, in a child script scope, so they can also see some
already-loaded functions and variables. See
[`user/custom-tests.md`](./custom-tests.md) for the current
execution-scope details and cautions.

## How to check HTTPS certificates

Use `HealthTest-HttpsCertificate` to check certificate validation and
expiration for one or more HTTPS URLs:

```powershell
. 'C:\IT\Get-ComputerHealth\bin\helpers-for-custom-ht.ps1'

HealthTest-HttpsCertificate -Url 'https://example.com/', 'https://www.example.com/' -WarnDays 60 -FailDays 30
```

`Get-HttpsCertificateStatus` returns the certificate details without writing a
health finding. Use it when a custom test needs its own reporting logic.

The helper opens a direct TCP/TLS connection to the URL's host and port. It does
not request the URL path or test HTTP response status. Certificate validation
errors are captured for reporting on that connection; it does not change a
process-wide certificate-validation callback. Connection failures produce a
notice, invalid certificates produce a failure, and valid certificates produce
warning/failure findings when their remaining lifetime reaches the configured
threshold. `-TimeoutSeconds` defaults to 10.

## How to check whether recent Veeam backups exist in a folder

### For backups stored in local drives (NOT mapped drives)

```powershell
. 'C:\IT\Get-ComputerHealth\bin\helpers-for-custom-ht.ps1'

Start-HealthTestVeeamRecentBackupsExist       -RootPath 'D:\Backups\Backup Job 1'
Start-HealthTestVeeamRecentConfigBackupsExist -RootPath 'D:\Backups\VeeamConfigBackup\SRV1'
```

The VM-backup check requires a `.vbm` file of at least 10 KiB and either a `.vib`
file of at least 1 GiB or a `.vbk` file of at least 10 GiB, all modified within
`MaxAgeHoursForVibVbm` (23 hours by default). It also requires a `.vbk` of at least
10 GiB modified within `MaxAgeHoursForVBK` (480 hours by default).
The configuration-backup check requires a `.BCO` of at least 25,000 bytes modified
within `MaxAgeHours` (24 hours by default). Both checks inspect only the named
folder. File presence, size, and modification time do not validate restorability.

### For backups stored in network shares

If the account running the test already has access to the UNC path, pass that path
with `-RootPath`; no credential file is needed. Otherwise, create a JSON
configuration file with this information. Double all backslashes in JSON paths:
```powershell
@"
    {
      "RootPath": "\\\\10.1.2.3\\share\\path\\to\\Backups",
      "Username": "foo",
      "Password": "bar"
    }
"@ | Set-Content -LiteralPath 'C:\IT\Get-ComputerHealth\config\HealthTest-RecentBackupsExist.config' -Encoding UTF8
```
The JSON password is stored as plaintext. Restrict access to the configuration
file to the administrators and account that run the test.

Then create a custom health test that references this config file:

```powershell
. 'C:\IT\Get-ComputerHealth\bin\helpers-for-custom-ht.ps1'

$configPath = 'C:\IT\Get-ComputerHealth\config\HealthTest-RecentBackupsExist.config'
Start-HealthTestVeeamRecentBackupsExist -ConfigPath $configPath -MaxAgeHoursForVibVbm 23 -MaxAgeHoursForVBK 480
```

The helper first tries the current SMB connection. Only if access fails does it
try the supplied credentials through a temporary, nonpersistent PowerShell drive.
It removes that drive in `finally`. It does not disconnect an existing SMB
connection to resolve a credential conflict. If both `-RootPath` and `-ConfigPath`
are supplied, the explicit root path takes precedence and the file supplies the
credentials. `Start-HealthTestVeeamRecentConfigBackupsExist` accepts a root path,
but does not accept `-ConfigPath`.

## How to check whether at least one recent file exists in a folder

```powershell
. 'C:\IT\Get-ComputerHealth\bin\helpers-for-custom-ht.ps1'

function HealthTest-RecentBakExist {
    param([int]$MaxAgeHours = 24)

    if (Get-RecentFilesConditional -Path "D:\Backups" -Pattern *.BAK -MinBytes 25000 -MaxAgeHours $MaxAgeHours) {
        Write-Warning "[PASS] Found a recent backup in D:\Backups"
    } else {
        Write-Warning "[FAILURE] No recent backup found in D:\Backups"
    }
}

HealthTest-RecentBakExist
```

`Get-RecentFilesConditional` filters by `LastWriteTime`, not `CreationTime`. It
returns matching file objects ordered by `LastWriteTime`, or no result when the
count is outside `MinCount`/`MaxCount`. The default minimum is one file. It accepts
multiple paths and patterns and searches subfolders only with `-Recurse`.

## Other helper functions

You may wish to use functions from `health-tests\helpers-for-healthtests.ps1`.
