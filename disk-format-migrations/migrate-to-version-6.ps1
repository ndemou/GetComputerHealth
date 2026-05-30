<#
.DESCRIPTION
Converts legacy Excel message archives under the data folder to CLIXML archives.

.MANIFEST
ModifiedTopFolders = data
NewTopFolders =
#>

$ErrorActionPreference = 'Stop'

function Get-UniqueDestinationPath {
  param(
    [Parameter(Mandatory)][string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return $Path
  }

  $directory = Split-Path -Parent $Path
  $leaf = Split-Path -Leaf $Path
  $baseName = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
  $extension = [System.IO.Path]::GetExtension($leaf)

  for ($attempt = 1; $attempt -le 100; $attempt++) {
    $candidate = Join-Path $directory ('{0}.{1}{2}' -f $baseName, $attempt, $extension)
    if (-not (Test-Path -LiteralPath $candidate)) {
      return $candidate
    }
  }

  throw "Could not find a unique destination path for '$Path'."
}

try {
  $rootDir = (Get-Location).Path
  $dataDir = Join-Path $rootDir 'data'
  $updaterPath = Join-Path $rootDir 'bin\Update-GetHealthCode.ps1'

  if (-not (Test-Path -LiteralPath $dataDir -PathType Container)) {
    Write-Output 'No migration is needed'
    exit 1
  }

  $xlsxFiles = @(Get-ChildItem -LiteralPath $dataDir -File -Filter '*.xlsx' -ErrorAction Stop)
  if ($xlsxFiles.Count -eq 0) {
    Write-Output 'No migration is needed'
    exit 1
  }

  Import-Module ImportExcel -ErrorAction Stop

  foreach ($file in $xlsxFiles) {
    $destinationPath = [System.IO.Path]::ChangeExtension($file.FullName, '.clixml')
    if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
      $destinationPath = Get-UniqueDestinationPath -Path $destinationPath
    }

    $rows = @(Import-Excel -Path $file.FullName -ErrorAction Stop)
    $rows | Export-Clixml -LiteralPath $destinationPath
    $check = @(Import-Clixml -LiteralPath $destinationPath -ErrorAction Stop)
    if (@($rows).Count -ne @($check).Count) {
      throw "Row count mismatch for '$($file.FullName)': XLSX=$(@($rows).Count) CLIXML=$(@($check).Count)"
    }

    Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
    Write-Output ("Converted '{0}' to '{1}' ({2} rows)" -f $file.FullName, $destinationPath, @($rows).Count)
  }

  Write-Output "PATH_TO_UPDATER=$updaterPath"
  exit 0
} catch {
  Write-Error $_.Exception.Message
  Write-Error 'Migration failed'
  exit 2
}
