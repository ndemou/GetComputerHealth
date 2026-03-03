## How to Add Custom Tests

You do not need to modify the core library.

### TL;DR

`.ps1` files in `C:\IT\config\Custom-HealthTests\` are dot-sourced, all functions with a name starting with `CustomHealthTest-` are executed, and these functions should call either `Log-Pass $message` if all is well or `Log-Failure $messageIfSomethingsWrong -Comment $optionalDetailsAboutWhatsWrong`. Start your scripts with this line `if(Get-Command Log-Pass -CommandType Function -ErrorAction SilentlyContinue){. C:\it\bin\lib-write-log-objects.ps1}`. Dot source them and call the function you've written to test it. The code you write will be executed with high privileges and appart from temporary files or similar, it should not make **any** changes to the system state.

### Step by step

1. Create the folder `C:\IT\config\Custom-HealthTests\` on the target computer.
2. Create a `.ps1` file with any name you like (e.g. `"tests-for-$env:COMPUTERNAME.ps1"`):

   ```powershell
   if (-not (Get-Command -Name Log-Pass -CommandType Function -ErrorAction SilentlyContinue)) {
      . 'C:\it\bin\lib-write-log-objects.ps1'
   }
   
   # Feel free to include as many helper functions as you like it; just don't name them like CustomHealthTest-*.
     
   # This is the function that implemets the test. It's name starts with CustomHealthTest-.
   function CustomHealthTest-LargeDirectories {
       $found = $false
       foreach ($dir in Find-LargeDirectory -Path 'C:\' -Threshold 10000) {
           $found = $true
           # The message should uniqely identify the problem; comment is optional and provides details
           # This is a good message:
           Log-failure "Directory $($dir.Path) has more than 10000 child items" -Comment "$($dir.ItemsCount) items"
           # This would be a bad message because it changes as more files are added.
           # So DON'T DO THIS: Log-failure "Directory $($dir.Path) has $($dir.ItemsCount) items"
           # Rationale: Often the administrator will suppress reports of false positives.
           # The suppression depends on the contents of the message. If even a single character
           # of the message changes, it will be treated as a different issue and will not be suppressed
       }
       if (-not $found) {Log-pass 'No directories found with >10000 items'}
   }

   # You can have more than one CustomHealthTest-... functions.
   
   # Do not write any other code outside of functions. 
   ```
3. Test your function like this:
   ```powershell
   . "C:\it\bin\lib-write-log-objects.ps1"
   . "C:\IT\config\Custom-HealthTests\tests-for-$env:COMPUTERNAME.ps1" # <-- the name of your ps1 file here
   CustomHealthTest-LargeDirectories # <-- the name of your function here
   ```

If you wish you can have more than one .ps1 files in `C:\IT\config\Custom-HealthTests\`
