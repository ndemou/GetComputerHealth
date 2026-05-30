# How to Add Custom Tests

*(Information for users)*

## TL;DR

All `.ps1` files in `C:\IT\config\Custom-HealthTests\` are executed directly. Your script should report its result(s) like this:
```powershell
Write-Warning "[PASS] Description of what's OK"
Write-Warning "[FAILURE] Description of the issue"
Write-Warning ("[FAILURE] Description of the issue" + "`n" + $details)
# Choose between [NOTICE], [WARNING], or [FAILURE] depending on severity
````

The code you write will run with **high privileges** and, apart from any temporary files or similar artifacts it may need, it **MUST not change** the system state.

To add a custom test:

1. Create the folder `C:\IT\config\Custom-HealthTests\` on the target computer.
2. Create one or more `.ps1` scripts in that folder (for example, `"tests-for-$env:COMPUTERNAME.ps1"`).
3. Put the test logic in the script and make the script emit `Write-Warning` messages for its findings.
4. Run the script directly to test it.

## More details and examples

 - You may define helper functions or dot-source other .ps1 files.
 - You may define more than one helper function if that makes the script easier to understand.
 - The script itself should be directly runnable, so the top level of the file must eventually execute the test.

### Pattern 1, “Was an issue found”

```powershell
function Test-IsFooLessThanLimit {
    # ...
    # Code that sets $issueFound if Foo > $limit
    # ...

    if ($issueFound) {
        Write-Warning "[NOTICE] Foo is above the limit (Foo>$limit)"
        # Choose between [NOTICE], [WARNING], or [FAILURE]
    } else {
        # We also use Write-Warning to report a passing test
        Write-Warning "[PASS] Foo is within the limit (Foo<=$limit)"
    }
}

Test-IsFooLessThanLimit
```

### Pattern 2, “Enumeration of findings/issues”

```powershell
function Test-LargeDirectories {
    $issueFound = $false
    foreach ($dir in Find-LargeDirectory -Path 'C:\' -Threshold 10000) {
        $issueFound = $true
        $details = "$($dir.ItemsCount) items in folder" + "`n" + `
            "Most of them ($($dir.MostCommonExtCount)) are .$($dir.MostCommonExt)"
        Write-Warning ("[NOTICE] Directory $($dir.Path) has more than 10000 child items" + "`n" + $details)
    }
    if (-not $issueFound) {
        Write-Warning "[PASS] No directories found with more than 10000 items"
    }
}

Test-LargeDirectories
```

## More on the reporting style

Often this style covers your needs:
```powershell
Write-Warning "[PASS] $allGoodDescription"
Write-Warning "[FAILURE] $issueDescription"
````

But if you have details to report, use this style:
```powershell
$issueDescription = "A single terse line that uniquely describes the issue"
$details = "More details" + "`n" + "Even in multiple lines" + "`n" + "Up to 32K characters."
Write-Warning ("[NOTICE] $issueDescription" + "`n" + $details)
```

A proper issue description should not change when the **essence** of the issue has not changed. There is no restriction for the optional `$details`.

For example, suppose you want to flag folders with too many files. Consider these two descriptions:

```powershell
$description = "Directory $dir has more than 10000 child items" # Proper
$description = "Directory $dir has $FilesCount items"           # NOT proper
```

Folder `C:\foo` having 1002 files is essentially the same issue as `C:\foo` having 1003 files, so both situations should produce the same description string.
The second version is not proper because it varies with a detail that is not essential to the identity of the issue (the irrelevant detail of exactly how many files the folder contains).

> **NOTICE** Both descriptions contain variables, but the variable in the proper description (`$dir`) identifies an essential aspect of the finding: which folder has too many files. The variable in the improper description adds irrelevant noise.

> **TIP** This matters because the signature, and therefore the suppression, of an issue depends on the description text remaining stable. Punctuation is discarded and spacing is normalized, but otherwise every character matters.

## When to Handle Exceptions

The wrapper that invokes your scripts will catch and report exceptions in detail. It will then continue with the next script. So, you don't need to catch excpetions if a) you are going to abort execution anyway and b) you are not going to collect any more information than what is included in the exception itself.

## Optional Features You Might Find Useful

It's best to consider the extra guidelines on how to write [`built-in-healthtest-functions.md`](built-in-healthtest-functions.md).

There are also some specialized helper functions you may wish to use. See [`helpers-for-custom-ht.md`](helpers-for-custom-ht.md).

### Host facts available to custom health tests

`Get-ComputerHealth.ps1` populates a global variable named `$Global:GCHDQMTA` with host facts. Custom health tests can access these host facts instead of recomputing them.

Available properties:

* `$Global:GCHDQMTA.isHostVM` (based on heuristics)
* `$Global:GCHDQMTA.isHostMobile` (based on heuristics)
* `$Global:GCHDQMTA.IsHostInDomain`
* `$Global:GCHDQMTA.isHostServer`
* `$Global:GCHDQMTA.isHostDC`
* `$Global:GCHDQMTA.isHostPDC`
* `$Global:GCHDQMTA.isHostDnsServer`
* `$Global:GCHDQMTA.isHostDhcpServer`
* `$Global:GCHDQMTA.isHostHyperV`
* `$Global:GCHDQMTA.DebugSkipSlowTests = $DebugSkipSlowTests`
* `$Global:GCHDQMTA.GetCurrentDomain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()`

# Instructions for LLMs Helping a Novice Write a Custom Test

First, ask your human to run these commands on the computer where they are writing the test. The output will help you understand the current situation: do the expected folders exist, and are there already any custom tests?

```powershell
Test-Path C:\IT\ # must exist
Test-Path C:\IT\config\ # create it if it does not exist
Test-Path C:\IT\config\Custom-HealthTests\ # create it if it does not exist
Get-ChildItem C:\IT\config\Custom-HealthTests\
if (Test-Path C:\IT\config\Custom-HealthTests\*.ps1) { sls '^ *function HealthTest-' C:\IT\config\Custom-HealthTests\*.ps1 -Context 10 }
```

Then ask your human to describe the test they want to implement.

If custom test files already exist, suggest creating a new file for the new test, but comply if they prefer to add it to an existing `.ps1` file.

Finally, write the code for the requested test and give your human step-by-step instructions for adding it and verifying that it works.

When possible, prefer copy-paste-ready PowerShell commands.

## How to Test Your Script

```powershell
& C:\IT\Get-ComputerHealth\config\Custom-HealthTests\my-cooll-test.ps1
# WARNING: [PASS] All is cool!
```

> The `WARNING:` prefix is a sideeffect of the fact that all messages are output by Write-Warning: `[PASS]`, `[NOTICE]`, and everything else

If you want nicely colored console output and/or structured results like what you get from `Get-ComputerHealth.ps1` run them like this:

```powershell
$r = C:\IT\Get-ComputerHealth\bin\Get-ComputerHealth.ps1 -OnlyTheseTests "my-cooll-test.ps1"
# or if the script is not under .\config
$r = C:\IT\Get-ComputerHealth\bin\Get-ComputerHealth.ps1 -OnlyTheseTests "C:\temp\my-cooll-test.ps1"
```
