# Provides:
#  - New-ZipFromFolder: Creates a zip file from a folder keeping that folder as the top-level entry in the zip.
. C:\Users\NickDemou\dev\scripts\helpers-files.ps1

Set-strictmode -version latest

try{
    $path="C:\it\config\Get-ComputerHealth-latest-release-meta.json"
    if (test-path $path) {rm $path}

    robocopy C:\Users\NickDemou\dev\GetComputerHealth\ C:\Users\NickDemou\dev\GetComputerHealth-v0.0.1\ /xd .git /mir /nfl /ndl /nc /ns | Out-Null
    if ($LASTEXITCODE -ge 8) {
        Throw "Robocopy failed with exit code $LASTEXITCODE"
    }

    $path="C:\Users\NickDemou\dev\GetComputerHealth-v0.0.1.zip"
    if (test-path $path) {rm $path}
    New-ZipFromFolder -SourceFolderPath C:\Users\NickDemou\dev\GetComputerHealth -DestinationPath  C:\Users\NickDemou\dev\GetComputerHealth-v0.0.1.zip -Exclude @('*.bak','*.tmp','.git') -NoCompression

    mkdir -Force c:\it\temp-gch\bin > $null
    cd c:\it\temp-gch\bin
    
    cp C:\Users\NickDemou\dev\GetComputerHealth\Update-GetHealthCode.ps1 .\
    .\Update-GetHealthCode.ps1 -Reinstall `
        C:\Users\NickDemou\dev\GetComputerHealth-v0.0.1.zip  

    $data = .\Get-ComputerHealth.ps1 -Hide DIPSN `
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

} finally {
    # CLEANUP
    $path="C:\it\config\Get-ComputerHealth-latest-release-meta.json"
    if (test-path $path) {rm $path}
}
