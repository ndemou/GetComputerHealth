Set-strictmode -version latest

mkdir -Force c:\it\temp-gch\bin > $null

mkdir -Force c:\it\temp-gch\config > $null
echo "" > "c:\it\temp-gch\config\Get-ComputerHealth.sigs-to-suppress.txt"

robocopy C:\Users\NickDemou\dev\GetComputerHealth\ c:\it\temp-gch\bin\ /xd .git /mir /nfl /ndl /nc /ns | Out-Null
if ($LASTEXITCODE -ge 8) {
    Throw "Robocopy failed with exit code $LASTEXITCODE"
}

$data = c:\it\temp-gch\bin\Get-ComputerHealth.ps1 -Hide DIPSNWFC `
    -OutputConsoleMessages -OutputObjects -RunWithoutElevation `
    -ExcludeTests ("HealthTest-LargeDirectories,HealthTest-SoftwareLicensing," + `
                   "HealthTest-ScheduledTasks,HealthTest-NonMicrosoftServices," + `
                   "HealthTest-UnsignedDrivers")

$programErrors = $data | ?{$_.message -like '*program error*'}
if ($programErrors) {
    echo "`n"
    $programErrors | %{echo $_.message; echo $_.comment; echo ""}
    throw "Program Error(s) in tests:`n$($programErrors.message)"
    echo ""
    throw "Program Error(s) in test(s)"
}

if (($data|measure).count -lt 200) {
    throw "Expected at least 200 messages from GCH -- examine $data"
}

