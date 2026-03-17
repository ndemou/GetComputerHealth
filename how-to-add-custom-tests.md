# How to Add Custom Tests

These instrunction are also valid for contributing health tests in the core library. The only difference is that ps1 scripts for custom tests are stored in a special folder.

## TL;DR

`.ps1` files in `C:\IT\config\Custom-HealthTests\` are dot-sourced, all functions with a name starting with `HealthTest-` are executed, and these functions should call either `Write-Warning "[pass] $message"` if all is well or `Write-Warning "[failure] $message` or `Write-Warning "[failure] $message" + [Environment]::NewLine + "$optionalDetails"`. The code you write will be executed with *high privileges* and appart from temporary files or similar, it *should not make any changes* to the system state.

## Step by step

1. Create the folder `C:\IT\config\Custom-HealthTests\` on the target computer.
2. Create a `.ps1` file with any name you like (e.g. `"tests-for-$env:COMPUTERNAME.ps1"`):

   ```powershell
   # If you wish, you can have helper functions (or dot-source them).
     
   # This is the function that implemets the test.
   # It's name starts with HealthTest-. and it doesn't return anything.
   # It outputs either information for a passed test or findings using  Write-Warning.
   function HealthTest-LargeDirectories {
       $issueFound = $false
       # Don't bother catching exceptions if you can't work around them.
       # The caller catches and reports them nicely.
       foreach ($dir in Find-LargeDirectory -Path 'C:\' -Threshold 10000) {
           $issueFound = $true

           # The synopsis should be a single terse line, that uniqely identifies the problem.
           # The synopsis should not change if the essense of the issue remains the same.
           # So this is good:
           $synopsis = "Directory $($dir.Path) has more than 10000 child items"
		   #
           # And this is a bad:
           # $synopsis = "Directory $($dir.Path) has $($dir.ItemsCount) items"
		   #
		   # Note that both the bad and the good synopsis contain variables but
		   # the variable on the good message ($dir.path) is an essential part of 
		   # the finding (which folder has too many files), while the variable
		   # in the bad synopsis is not. Rather it adds information that may change
           # even if the issue remains (e.g. if a file is added, ItemsCount will
		   # increase while the fact that this specific folder has too many files 
		   # will not change).
   
           # The optional details can contain one or more lines(up to 32K characters)
		   # and there's no other limitation on what you can include in them. 
		   # If you do include details you must prefix them with a newline:
           $details = "`n" +"$($dir.ItemsCount) items" + "`n" + `
               "Most of them ($(dir.MostCommonExtCount)) are .$(dir.MostCommonExt)"
		   # If you don't want to include details, set $details = ""
   
           # We use [notice] here, which is the lightest level for a finding.
           # You can also use [warning], and [failure] for more sever findings
           # and [info] for non-findings (informational messages).
		   Write-Warning "[notice] $synopsis$details"
       }
       if (-not $issueFound) {
           $synopsis = "No directories found with >10000 items"
           $details = "" 
           Write-Warning "[pass] $synopsis$details"
           # Note a counter-intuitive fact: we *always* report using Write-Warning, 
		   # even for *passed* tests.
       }
   }

   # You can have more than one HealthTest-... functions.
   
   # Do not write any other code outside of functions. 
   ```
3. Test your function:
   ```powershell
   . C:\IT\bin\Get-ComputerHealth.ps1 -DoNothing # only needed if your function reads `$Global:GetComputerHealthDataQMTA`
   . "C:\IT\config\Custom-HealthTests\tests-for-$env:COMPUTERNAME.ps1" # <-- the name of your ps1 file here
   HealthTest-LargeDirectories # <-- the name of your function here
   ```

If you wish you can have more than one .ps1 files in `C:\IT\config\Custom-HealthTests\`

## Runtime context available to custom health tests

When `Get-ComputerHealth.ps1` runs, it populates a global variable named `$Global:GetComputerHealthDataQMTA` so all health tests can reuse these host facts without re-computing.

Available properties include these self-documenting booleans:
- `.isHostVM` (based on heuristics)
- `.isHostMobile` (based on heuristics)
- `.isHostDomainJoined`
- `.isHostServer`
- `.isHostDC`
- `.isHostPDC`

And `.GetCurrentDomain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()`

## Required help-block format for every `HealthTest-*` function

Every `HealthTest-*` function must include an **in-function** comment-based help block immediately after the opening `{`.

### Example

```powershell
function HealthTest-Example {
<#
.SYNOPSIS
Checks if foo is of type bar

.DESCRIPTION
Uses: Get-FooType
AppliesTo: Domain Controllers
TestScope: Computer
Category: Availability / Server Down Signals, Security & Stability Risks.
Impact: Medium(Time), High(Network)
#>
  # ...
}
```

- `.SYNOPSIS` is mandatory and must be **<= 320 characters**. It must explain what the test detects/checks, and the key signal logic used to decide healthy vs unhealthy.
- `.DESCRIPTION` is mandatory and must be **<= 900 characters**.
- Do not add any other help sections (e.g. `.PARAMETER`, `.OUTPUTS`, `.EXAMPLE`).
  
For the `.DESCRIPTION` use plain text with one field per line in this exact order, so it is easy to lint with regex:

1. `AppliesTo:` Type of computer (One of: `All`, `VM`, `Mobile`, `DomainJoined`, `Server`, `Workstation`, `DC`, `PDC` )
2. `TestScope:` `Computer`, `Domain`, `Forest`
3. `Category:` Primary + optional Secondary (see below for list)
4. `Impact:` `Medium` or `High`, and include resource dimension only if not low (`CPU`, `Disk`, `Network`, `Time`)
5. `Uses:` List of up to three essential for the test external cmdlets/executables. E.g. Get-Services, Get-ADComputer,...
  > This field is intended for essential dependency metadata, not implementation details. Include only essential external commands (e.g., `ipconfig.exe`, `Get-DnsServerZone`) that are both required to execute the test and return the core information that determines if the test passes. Do not list a) a function defined within this repository b) helper calls c) broad commands like `Get-Service`, or `Get-ADUser` unless they represent the **sole** essential dependency of the test. Avoid descriptive sentences. Use `Uses: None.` for empty dependencies.
6. `FalsePositives:` short note (optional)

Allowed values for `Category`:
- `Availability / Server Down Signals`
- `Security & Stability Risks`
- `Configuration Hygiene & Best Practices`
- `Audit / Compliance / Informational`

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
