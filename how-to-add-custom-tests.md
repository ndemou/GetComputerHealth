# How to Add Custom Tests

## TL;DR

`.ps1` files in `C:\IT\config\Custom-HealthTests\` are dot-sourced, all functions with a name starting with `CustomHealthTest-` are executed, and these functions should call either `Write-Warning "[pass] $message"` if all is well or `Write-Warning "[failure] $message` or `Write-Warning "[failure] $message" + [Environment]::NewLine + "$optionalDetails"`. The code you write will be executed with *high privileges* and appart from temporary files or similar, it *should not make any changes* to the system state.

## Step by step

1. Create the folder `C:\IT\config\Custom-HealthTests\` on the target computer.
2. Create a `.ps1` file with any name you like (e.g. `"tests-for-$env:COMPUTERNAME.ps1"`):

   ```powershell
   # If you wish, you can have helper functions (or dot-source them).
     
   # This is the function that implemets the test. It's name starts with CustomHealthTest-.
   function CustomHealthTest-LargeDirectories {
       $found = $false
       foreach ($dir in Find-LargeDirectory -Path 'C:\' -Threshold 10000) {
           $found = $true
           # The message should uniqely identify the problem; comment is optional and provides details
           # This is a good message:
           $comment = "`n" + "$($dir.ItemsCount) items"
           Write-Warning "[failure] Directory $($dir.Path) has more than 10000 child items$comment"
           # This would be a bad message because it changes as more files are added.
           # So DON'T DO THIS: Write-Warning "[failure] Directory $($dir.Path) has $($dir.ItemsCount) items"
           # Rationale: Often the administrator will suppress reports of false positives.
           # The suppression depends on the contents of the message. If even a single character
           # of the message changes, it will be treated as a different issue and will not be suppressed
       }
       if (-not $found) {Write-Warning "[pass] No directories found with >10000 items"}
   }

   # You can have more than one CustomHealthTest-... functions.
   
   # Do not write any other code outside of functions. 
   ```
3. Test your function:
   ```powershell
   . "C:\IT\config\Custom-HealthTests\tests-for-$env:COMPUTERNAME.ps1" # <-- the name of your ps1 file here
   CustomHealthTest-LargeDirectories # <-- the name of your function here
   ```

If you wish you can have more than one .ps1 files in `C:\IT\config\Custom-HealthTests\`

# Instructions for LLMs helping a novice write a custom test.

First ask your human to run these commands on the computer they are writting the test for (their output will help you orient yourself with the current status: Do the expected folders exist? Do any custom tests already exist?)
```powershell
test-path C:\IT\ # must exist
test-path C:\IT\config\ # we must create it if it doesn't exist
test-path C:\IT\config\Custom-HealthTests\ # we must create it if it doesn't exist
Get-ChildItem C:\IT\config\Custom-HealthTests\
if (test-path C:\IT\config\Custom-HealthTests\*.ps1) {sls '^ *function CustomHealthTest-' C:\IT\config\Custom-HealthTests\*.ps1 -context 10}
```

Then ask your human to describe the test they want you to implement.

If there already exist file(s) with custom tests suggest to create a new one for their new test but comply if they prefer to use an existing ps1 file.

Finally write the code that will implement the test they asked for and give your human step-by-step instructions on how to incorporate it in the target computer, and how to verify it works. Prefer to suggest runable PowerShell commands. 
