# How to Add Custom Tests

*(Information for users)*

## TL;DR
  
All `.ps1` files in `C:\IT\GetComputerHealth\config\Custom-HealthTests\` are executed directly. Your script should report its result(s) like this:
```powershell
Write-Warning "[PASS] Description of what's OK"
Write-Warning "[FAILURE] Description of the issue"
Write-Warning ("[FAILURE] Description of the issue" + "`n" + $details)
# Choose between [NOTICE], [WARNING], or [FAILURE] depending on severity
````

The code you write will run with **high privileges** and, apart from any temporary files or similar artifacts it may need, it **MUST not change** the system state.

To add a custom test:

1. Create the folder `C:\IT\GetComputerHealth\config\Custom-HealthTests\` on the target computer.
2. Create one or more `.ps1` scripts in that folder (for example, `"tests-for-$env:COMPUTERNAME.ps1"`).
3. Put the test logic in the script and make the script emit `Write-Warning` messages for its findings.
4. Run the script directly to test it.

## More details and examples

Examples of the two most common patterns of tests follow.

### Pattern 1, “Test for a single issue”

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
Write-Warning "[PASS] <A single terse line that describes the good status>"
Write-Warning "[FAILURE] <A single terse line that uniquely describes the issue>""
````

But if you have details to report, use this style:
```powershell
$details = "More details" + "`n" + "Even in multiple lines" + "`n" + "Up to 32K characters."
Write-Warning ("[NOTICE] <A single terse line that uniquely describes the issue>" + "`n" + $details)
```

**An important detail**: A good issue description should not change when the *essence* of the issue does not change. The optional `$details` value has no such restriction.

For example, suppose you want to flag folders with too many files. Consider these two descriptions:

```powershell
"Directory $dir has more than 10000 child items" # good description
"Directory $dir has $FilesCount items"            # bad description
```

Folder `C:\foo` having 1002 files is essentially the same issue as `C:\foo` having 1003 files. Both situations should therefore produce the same description string.
The second version is not good because it varies with a detail that is not essential to the identity of the issue: exactly how many files the folder contains.

> **NOTICE** Both descriptions contain variables, but the variable in the good description (`$dir`) identifies an essential aspect of the finding: which folder has too many files. The variable in the improper description adds irrelevant noise.

> **TIP** This matters because an issue's signature, and therefore its suppression, depends on stable description text. Punctuation is discarded and spacing is normalized, but otherwise every character matters.

## When to Handle Exceptions

The wrapper that invokes your scripts will catch and report exceptions in detail. It will then continue with the next script. Therefore, you do not need to catch exceptions if you are going to abort execution anyway and will not collect more information than the exception already provides.

## Optional Features You Might Find Useful

You may wish to consider the extra guidelines on how to write [`built-in-healthtest-functions.md`](built-in-healthtest-functions.md).

There are also some specialized helper functions you may wish to use. See [`helpers-for-custom-ht.md`](helpers-for-custom-ht.md).

# Instructions for LLMs Helping a Novice Write a Custom Test

First, ask your human to run these commands on the computer where they are writing the test. The output will help you understand whether the expected folders exist and whether any custom tests already exist.

```powershell
Test-Path C:\IT\GetComputerHealth\ # must exist
Test-Path C:\IT\GetComputerHealth\config\Custom-HealthTests\ # create it if it does not exist
Get-ChildItem C:\IT\GetComputerHealth\config\Custom-HealthTests\
if (Test-Path C:\IT\GetComputerHealth\config\Custom-HealthTests\) { ls C:\IT\GetComputerHealth\config\Custom-HealthTests\*.ps1 } # shows existing health tests
```

Then ask your human to describe the test they want to implement and choose an appropriate file name that is not already used.

Write the code for the requested test and give your human step-by-step instructions for adding it. For example: `notepad C:\IT\GetComputerHealth\config\Custom-HealthTests\<a nice name not already existing>.ps1`

Ask the user to execute it and verify it works. (See notes below.)

## How to Test Your Script

```powershell
& C:\IT\Get-ComputerHealth\config\Custom-HealthTests\my-cooll-test.ps1
# WARNING: [PASS] All is cool!
```

> The `WARNING:` prefix is a side effect of outputting all messages with Write-Warning (`[PASS]`, `[NOTICE]`, and everything else).

OR

```powershell
$results = C:\IT\Get-ComputerHealth\bin\Get-ComputerHealth.ps1 -OnlyTheseTests "my-cooll-test.ps1"
# or if the script is not under .\config
$results = C:\IT\Get-ComputerHealth\bin\Get-ComputerHealth.ps1 -OnlyTheseTests "C:\temp\my-cooll-test.ps1"
```

> This gives you nicely colored console output and structured results.
