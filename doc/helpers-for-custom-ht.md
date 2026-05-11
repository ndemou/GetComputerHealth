## How to check that recent Veeam backups exist in a folder

### For backups stored in local drives (NOT mapped drives)

```powershell
function HealthTest-FreshVeeamBackups {
    Start-HealthTestVeeamRecentBackupsExist       -RootPath "D:\Backups\Backup Job 1"
    Start-HealthTestVeeamRecentConfigBackupsExist -RootPath "D:\Backups\VeeamConfigBackup\SRV1"
}
```
### For backups stored in network shares

First create a configuration file with this information (note that you need to double all backslashes in paths):
```powershell
@"
    {
      "RootPath": "\\\\10.1.2.3\\share\\path\\to\\Backups",
      "Username": "foo",
      "Password": "bar"
    }
"@ > "C:\it\config\HealthTest-RecentBackupsExist.config"
```
And then create a custom health test that references this config file:

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
