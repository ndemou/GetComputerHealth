<#
.DESCRIPTION
Creates the data folder and moves existing Excel health result workbooks from temp to data.

.MANIFEST
ModifiedTopFolders = temp
NewTopFolders = data
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
  $tempDir = Join-Path $rootDir 'temp'
  $dataDir = Join-Path $rootDir 'data'
  $updaterPath = Join-Path $rootDir 'bin\Update-GetHealthCode.ps1'

  $xlsxFiles = @()
  if (Test-Path -LiteralPath $tempDir -PathType Container) {
    $xlsxFiles = @(Get-ChildItem -LiteralPath $tempDir -File -Filter '*.xlsx' -ErrorAction Stop)
  }

  if ((Test-Path -LiteralPath $dataDir -PathType Container) -and ($xlsxFiles.Count -eq 0)) {
    Write-Output 'No migration is needed'
    exit 1
  }

  if (-not (Test-Path -LiteralPath $dataDir -PathType Container)) {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    Write-Output "Created data directory: $dataDir"
  }

  foreach ($file in $xlsxFiles) {
    $destinationPath = Join-Path $dataDir $file.Name
    if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
      $destinationPath = Get-UniqueDestinationPath -Path $destinationPath
    }

    Move-Item -LiteralPath $file.FullName -Destination $destinationPath -Force -ErrorAction Stop
    Write-Output ("Moved '{0}' to '{1}'" -f $file.FullName, $destinationPath)
  }

  Write-Output "PATH_TO_UPDATER=$updaterPath"
  exit 0
} catch {
  Write-Error $_.Exception.Message
  Write-Error 'Migration failed'
  exit 2
}
