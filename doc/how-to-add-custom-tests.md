# How to Add Custom Tests

## TL;DR

All `.ps1` files in `C:\IT\config\Custom-HealthTests\` are dot-sourced, and all their functions named like `HealthTest-*` are executed. These functions should call either `Write-Warning "[PASS] $message"`, or `Write-Warning "[FAILURE] $message` or `Write-Warning "[FAILURE] $message" + "```n" + $optionalDetails`. The code you write will be executed with **high privileges** and appart from any needed temporary files and such, it **should not make any changes** to the system state.

The steps to add a custom test are:

1. Create the folder `C:\IT\config\Custom-HealthTests\` on the target computer.
2. Create one or more `.ps1` script there (e.g. `"tests-for-$env:COMPUTERNAME.ps1"`).
3. Include one or more functions named `HealthTest-<SOME_DESCRIPTIVE_NAME>` in your script.
4. Dot source your script and run your function to test it.

## Example Code

```powershell
# This function implemets the test. It returns nothing
function HealthTest-IsFooLessThanLimit {
     # ...
     # Code that will set $issueFound if Foo>$limit
     # ...

     if ($issueFound) {
         Write-Warning "[NOTICE] Foo is above the limit (Foo>$limit)"
         # Chose between [NOTICE],[WARNING], or [FAILURE]
     } else {
         # Notice that we also use Write-Warning to report a passed test
         Write-Warning "[PASS] Foo is within the limit (Foo<=$limit)"
     }
}

# You can have helper functions or dot-source other ps1 files

# You can have more than one HealthTest-... functions.

# Don't write any code besides functions. 
```

If you have more details to report use this style:

```powershell
$issueDescription = "A single terse line, that uniqely describes the issue"
$details = "More details" +"`n" + "Even in multiple lines" +"`n" + "With a limit of 32K characters."
Write-Warning "[NOTICE] $issueDescription" + "`n" + $details
```

Another very common pattern is the "enumeration of findings style":

```powershell
function HealthTest-LargeDirectories {
    $issueFound = $false
    foreach ($dir in Find-LargeDirectory -Path 'C:\' -Threshold 10000) {
        $issueFound = $true
        $details = "$($dir.ItemsCount) items in folder" + "`n" + `
            "Most of them ($(dir.MostCommonExtCount)) are .$(dir.MostCommonExt)"
        $issueDescription = "Directory $($dir.Path) has more than 10000 child items"
        Write-Warning "[NOTICE] $issueDescription" + "`n" + $details
    }
    if (-not $issueFound) {
        Write-Warning "[PASS] No directories found with >10000 items"
    }
}
```

## How to test your function

```powershell
. C:\IT\bin\Get-ComputerHealth.ps1 -DoNothing # only needed if your function reads `$Global:GCHDQMTA`
. "C:\IT\config\Custom-HealthTests\tests-for-$env:COMPUTERNAME.ps1" # <-- the name of your script
HealthTest-LargeDirectories # <-- the name of your function here
```

The above gives OK but crude output; if you want to get both nicely colored console output and structured results:

```powershell
$results = HealthTest-LargeDirectories 3>&1 | C:\IT\bin\Get-ComputerHealth.ps1 -PrettifyWriteWarning
```

## How to write proper issue descriptions

The string of a proper description should not change if the essense of the issue does not change (there's no restriction for the optional `$details`).

Let's say for example that you want to flag folders with too many files (e.g. >1000). Consider these descriptions:

```powershell
$description = "Directory $dir has more than 10000 child items" # Proper
$description = "Directory $dir has $FilesCount items"           # NOT Proper
```

Folder `C:\foo` having 1002 files is practically the same issue as `C:\foo` having 1003 files, so both situations should produce the same description string. The 2nd version is not proper because it produces a string that is sensitive to the irrelevant detail of exactly how many files the folder contains.

> Note that both the proper and improper descriptions contain variables but
> the variable on the proper descriptio ($dir) reports information that is
> an essential aspect of the finding (which folder exactly has too many files), 
> while the variable in the improper description only adds irelevant noise.

*TIP*: This is a very important detail to remember when writting descriptions of issues/findings 
because the signature (and as a result the suppression) of issues depends on the text of the 
description staying the same (punctuation is discarded and spacing is normalized but otherwise
every character matters).

## When to handle exceptions

Do not catch an exception just to report it and abort the test: The wrapper that invokes `HealthTest-` functions will catch exceptions, report enough details to help you debug them and gracefully skip to the next test.

Catch exceptions if you want to achieve another goal (work around them, or while collecting optioanl info, e.t.c.).

## Optional features you might find useful

### Host facts available to custom health tests

`Get-ComputerHealth.ps1` populates a global variable named `$Global:GCHDQMTA` with host facts. 
The available properties are:

- `$Global:GCHDQMTA.isHostVM` (based on heuristics)
- `$Global:GCHDQMTA.isHostMobile` (based on heuristics)
- `$Global:GCHDQMTA.isHostDomainJoined`
- `$Global:GCHDQMTA.isHostServer`
- `$Global:GCHDQMTA.isHostDC`
- `$Global:GCHDQMTA.isHostPDC`
- `$Global:GCHDQMTA.isHostDnsServer`
- `$Global:GCHDQMTA.isHostDHCPServer`
- `$Global:GCHDQMTA.isHostHyperisor`
- `$Global:GCHDQMTA.isHostInDomainButNotDC`
- `$Global:GCHDQMTA.DebugSkipSlowTests = $DebugSkipSlowTests`
- `$Global:GCHDQMTA.GetCurrentDomain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()`

Health tests can reuse these host facts without re-computing them.

### How to check recent Veeam Backups exist in a folder

```powershell
function HealthTest-FreshVeeamBackups {
    Start-HealthTestVeeamRecentBackupsExist       -RootPath "D:\Backups\Backup Job 1"
    Start-HealthTestVeeamRecentConfigBackupsExist -RootPath "D:\Backups\VeeamConfigBackup\SRV1"
}
```

### How to check if at least one recent .BAK file exists in a folder

```powershell
function HealthTest-RecentBakExist{
param(
    [int]$MaxAgeHours = 24
)
    if (Get-RecentFilesConditional -Path "D:\Backups" -Pattern *.BAK -MinBytes 25000 -MaxAgeHours $MaxAgeHours) {
        Write-Warning "[PASS] Found recent Backup in D:\Backups"
    } else {
        Write-Warning "[FAILURE] No recent Backup in D:\Backups"
    }
}
```

### Other

The "Optional Features for Health Tests" mentioned in `How-to-add-built-in-health-tests.md` are not mandatory but you may want to consider them.

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

Finally write the code that will implement the test they asked for and give your human step-by-step instructions on how to add it, and verify it works (see above).

When possible prefer to suggest copy-paste ready PowerShell commands.
