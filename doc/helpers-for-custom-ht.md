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
[`how-to-add-custom-tests.md`](how-to-add-custom-tests.md) for the current
execution-scope details and cautions.

## How to check whether recent Veeam backups exist in a folder

### For backups stored in local drives (NOT mapped drives)

```powershell
function HealthTest-FreshVeeamBackups {
    Start-HealthTestVeeamRecentBackupsExist       -RootPath "D:\Backups\Backup Job 1"
    Start-HealthTestVeeamRecentConfigBackupsExist -RootPath "D:\Backups\VeeamConfigBackup\SRV1"
}
```
### For backups stored in network shares

First, create a configuration file with this information. Note that you need to double all backslashes in paths:
```powershell
@"
    {
      "RootPath": "\\\\10.1.2.3\\share\\path\\to\\Backups",
      "Username": "foo",
      "Password": "bar"
    }
"@ > "C:\it\config\HealthTest-RecentBackupsExist.config"
```
Then create a custom health test that references this config file:

```powershell
function HealthTest-FreshVeeamBackups {
    Start-HealthTestVeeamRecentBackupsExist `
        -ConfigPath 'C:\it\config\HealthTest-RecentBackupsExist.config' `
        -MaxAgeHoursForVibVbm 23 `
        -MaxAgeHoursForVBK 480
}
```

## How to check whether at least one recent file exists in a folder

```powershell
function HealthTest-RecentBakExist {
    param([int]$MaxAgeHours = 24)

    if (Get-RecentFilesConditional -Path "D:\Backups" -Pattern *.BAK -MinBytes 25000 -MaxAgeHours $MaxAgeHours) {
        Write-Warning "[PASS] Found a recent backup in D:\Backups"
    } else {
        Write-Warning "[FAILURE] No recent backup found in D:\Backups"
    }
}
```

## Other helper functions

You may wish to use functions from `health-tests\helpers-for-healthtests.ps1`.
