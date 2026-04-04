# Provides:
#  - New-ZipFromFolder: Creates a zip file from a folder keeping that folder as the top-level entry in the zip.
. C:\Users\NickDemou\dev\scripts\helpers-files.ps1

Set-strictmode -version latest

robocopy C:\Users\NickDemou\dev\GetComputerHealth\ C:\Users\NickDemou\dev\GetComputerHealth-v0.0.1\ /xd .git /mir /nfl /ndl /nc /ns | Out-Null
if ($LASTEXITCODE -ge 8) {
    Throw "Robocopy failed with exit code $LASTEXITCODE"
}

$path="C:\Users\NickDemou\dev\GetComputerHealth-v0.0.1.zip"
if (test-path $path) {rm $path}
New-ZipFromFolder -SourceFolderPath C:\Users\NickDemou\dev\GetComputerHealth -DestinationPath  C:\Users\NickDemou\dev\GetComputerHealth-v0.0.1.zip -Exclude @('*.bak','*.tmp','.git') -NoCompression

mkdir -Force c:\it\temp-gch\bin > $null

cp C:\Users\NickDemou\dev\GetComputerHealth\Update-GetHealthCode.ps1 c:\it\temp-gch\bin\

c:\it\temp-gch\bin\Update-GetHealthCode.ps1 -Reinstall `
    C:\Users\NickDemou\dev\GetComputerHealth-v0.0.1.zip  
