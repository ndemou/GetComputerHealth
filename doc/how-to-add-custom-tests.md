# How to Add Custom Tests

## TL;DR

`.ps1` files in `C:\IT\config\Custom-HealthTests\` are dot-sourced, all functions with a name starting with `HealthTest-` are executed, and these functions should call either `Write-Warning "[pass] $message"` if all is well or `Write-Warning "[failure] $message` or `Write-Warning "[failure] $message" + [Environment]::NewLine + "$optionalDetails"`. The code you write will be executed with *high privileges* and appart from temporary files or similar, it *should not make any changes* to the system state.

## Step by step

1. Create the folder `C:\IT\config\Custom-HealthTests\` on the target computer.
2. Create a `.ps1` file with any name you like (e.g. `"tests-for-$env:COMPUTERNAME.ps1"`):

   ```powershell
   # You *can* have helper functions and dot-source other ps1 files
     
   # This function implemets the test, it's name starts with HealthTest-. and it returns nothing
   function HealthTest-LargeDirectories {
       $issueFound = $false
       foreach ($dir in Find-LargeDirectory -Path 'C:\' -Threshold 10000) {
           $issueFound = $true

           # The synopsis should be a single terse line, that uniqely identifies the problem.
           $issueSynopsis = "Directory $($dir.Path) has more than 10000 child items"
   
           # You can emit optional text details along with the synopsis. 
           # You can have multiple lines and up to 32K characters.
           $details = "$($dir.ItemsCount) items" + "`n" + `
               "Most of them ($(dir.MostCommonExtCount)) are .$(dir.MostCommonExt)"
   
           # Chose between [notice],[warning] and [failure]
           Write-Warning "[notice] $issueSynopsis" + "`n" + $details
           # If you have no $details to include this is enough:
           #    Write-Warning "[notice] $issueSynopsis"
       }
       if (-not $issueFound) {
           Write-Warning "[pass] No directories found with >10000 items"
           # Notice that we also use Write-Warning to report a passed test
       }
   }

   # You can have more than one HealthTest-... functions.
   
   # But don't write any code besides functions. 
   ```
3. Test your function:
   ```powershell
   . C:\IT\bin\Get-ComputerHealth.ps1 -DoNothing # only needed if your function reads `$Global:GCHDQMTA`
   . "C:\IT\config\Custom-HealthTests\tests-for-$env:COMPUTERNAME.ps1" # <-- the name of your ps1 file here
   HealthTest-LargeDirectories # <-- the name of your function here
   ```
   
   Or to get both nicely colored console output and structured results:
   ```powershell
   $results = HealthTest-LargeDirectories 3>&1 | C:\IT\bin\Get-ComputerHealth.ps1 -PrettifyWriteWarning
   ```

If you wish you can have more than one .ps1 files in `C:\IT\config\Custom-HealthTests\`

## How to write a good synopsis

The synopsis should not change if the essense of the issue remains the same. 
So this synopsis is good:

```
$synopsis = "Directory $($dir.Path) has more than 10000 child items"
```

But this is a bad:

```
$synopsis = "Directory $($dir.Path) has $($dir.ItemsCount) items"
```

It's bad because the text will change even if just one file is added. But that change will be irelevant: it's hardly any more of a problem to have a folder with 10002 files compared to a folder with 10001.

  > Note that both the bad and the good synopsis contain variables but
  > the variable on the good message ($dir.path) is an essential part of 
  > the finding (which folder has too many files), while the variable
  > in the bad synopsis only adds an irelevant detail/noise.

## Error handling

Don't bother catching exceptions if you can't work around them.
The caller catches and reports exceptions nicely.

## Runtime context available to custom health tests

When `Get-ComputerHealth.ps1` runs, it populates a global variable named `$Global:GCHDQMTA` so all health tests can reuse these host facts without re-computing.

Available properties include these self-documenting booleans:
- `.isHostVM` (based on heuristics)
- `.isHostMobile` (based on heuristics)
- `.isHostDomainJoined`
- `.isHostServer`
- `.isHostDC`
- `.isHostPDC`
- `.isHostDnsServer`
- `.isHostDHCPServer`
- `.isHostHyperisor`
- `.isHostInDomainButNotDC`
- `.DebugSkipSlowTests` ($True if the `-DebugSkipSlowTests` switch was used on invocation)

And `.GetCurrentDomain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()`

## Optional features

### General

Consider the "Optional Features for Health Tests" mentioned in `How-to-add-built-in-health-tests.md`. They are not mandatory however.

### For Checking Backup Freshness

Example of how to check Veeam Backups:
```
function HealthTest-FreshVeeamBackups {
    Start-HealthTestVeeamRecentBackupsExist       -RootPath "D:\Backups\Backup Job 1"
    Start-HealthTestVeeamRecentConfigBackupsExist -RootPath "D:\Backups\VeeamConfigBackup\SRV1"
}
```

Example of how to verify at least one daily .BAK file exists in a folder
```
function HealthTest-RecentBakExist{
param(
    [string]$RootPath,
    [int]$MaxAgeHours = 24
)
    if (Get-RecentFilesConditional -Path $RootPath -Pattern *.BAK -MinBytes 25000 -MaxAgeHours $MaxAgeHours) {
        write-warning "[PASS] Found recent Backup in $RootPath"
    } else {
        write-warning "[FAILURE] No recent Backup in $RootPath"
    }
}
```

# Instructions for LLMs helping a novice write a custom test.

First ask your human to run these commands on the computer they are writting the test for (their output will help you orient yourself with the current status: Do the expected folders exist? Do any custom tests already exist?)
```powershell
test-path C:\IT\ # must exist
test-path C:\IT\config\ # we must create it if it doesn't exist
test-path C:\IT\config\Custom-HealthTests\ # we must create it if it doesn't exist
Get-ChildItem C:\IT\config\Custom-HealthTests\
if (test-path C:\IT\config\Custom-HealthTests\*.ps1) {sls '^ *function HealthTest-' C:\IT\config\Custom-HealthTests\*.ps1 -context 10}
```

Then ask your human to describe the test they want you to implement.

If there already exist file(s) with custom tests suggest to create a new one for their new test but comply if they prefer to use an existing ps1 file.

Finally write the code that will implement the test they asked for and give your human step-by-step instructions on how to incorporate it in the target computer, and how to verify it works. Prefer to suggest runable PowerShell commands. 
