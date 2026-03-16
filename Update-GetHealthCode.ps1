<#
.SYNOPSIS
Ensures all health-check scripts and PS Modules are installed & up-to-date.

.DESCRIPTION
Missing files are created. Existing files that differ are replaced.
Identical files are left unchanged. If this script updates itself, 
it re-invokes the updated copy. When replacing a file, backup copies
are created in the backups directory. 
Will set PSGallery as Trusted.

.OUTPUTS
None.
#>
param(
  [switch]$Reinstall,
  [string]$UpdateFromZip
)

####################################################################
#
#  START OF CONFIG
#
$DEST_DIR = 'C:\it\bin'
$BAK_DIR  = 'C:\it\temp'
$CFG_DIR  = 'c:\it\config'
$REPO_URL = 'https://github.com/ndemou/GetComputerHealth'
$REPO_REF = 'main'
$LATEST_RELEASE_MARKER_PATH = 'c:\it\config\Get-ComputerHealth-latest-release.dat'
$ZIP_CACHE_PATTERN = 'GetComputerHealth-release-*.zip'
$repoSlug = (($REPO_URL -replace '^https?://github\.com/','') -replace '\.git$','').Trim('/')
#
#  END OF CONFIG
#
####################################################################

####################################################################
#
#  HELPER FUNCTIONS START
#
function Ensure-PSModuleInstalled {
<#
.SYNOPSIS
Ensures a PowerShell module is installed locally; installs it if missing.
.DESCRIPTION
If installation fails due to PSGallery not being registered, registers
PSGallery, marks it Trusted, and retries the installation once.
.OUTPUTS
Logs messages about what it does with Write-Output/Write-Warning.
#>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Name,
    [string]$Scope = 'AllUsers'
  )
  if (Get-Module -ListAvailable -Name $Name) {return}
  try {
    Write-Output "Installing PS Module $Name" 
    Install-Module -Name $Name -Scope $Scope -Force -ErrorAction Stop
  } catch {
    if ($_.Exception.Message -like "*No repository with the Name 'PSGallery'*") {
      Write-Warning "Registering PSGallery" 
      Register-PSRepository -Default -ErrorAction Stop
      Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
      Write-Output "Installing PS Module $Name (previous attempt failed)"
      Install-Module -Name $Name -Scope $Scope -Force -ErrorAction Stop
    } else {
      throw
    }
  }
}

function New-EmptyTempDirectory {
<#
.SYNOPSIS
Creates a directory at "$env:TEMP\<Name>" and returns its full path.
.OUTPUTS
System.String, The full path of the created directory under $env:TEMP.
#>
    [CmdletBinding()]param([string]$Name)
    $tmdDir = Join-Path $env:TEMP $Name
    # If $tmdDir already exists
    if (Test-Path -Path $tmdDir) {
        # If it's a folder: Clear it out
        if (Test-Path -Path $tmdDir -PathType Container) {
            Get-ChildItem -Path $tmdDir -Recurse | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        } 
        # If it's a file: Find a unique 6-digit alternative name
        else {
            while (Test-Path -Path $tmdDir) {
                $suffix = Get-Random -Minimum 100000 -Maximum 1000000
                $tmdDir = Join-Path $env:TEMP "$Name-$suffix"
            }
        }
    }
    # Create the directory
    $null = New-Item -ItemType Directory -Path $tmdDir -Force
    return $tmdDir
}

function Convert-GitHubRepoUrlToSlug {
<#
.SYNOPSIS
Converts a GitHub repo URL into "owner/repo" format.
#>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$RepoUrl)
  $slug = ($RepoUrl -replace '^https?://github\.com/','') -replace '\.git$',''
  $slug = $slug.Trim('/')
  if ([string]::IsNullOrWhiteSpace($slug)) {
    throw "Invalid GitHub repository URL: $RepoUrl"
  }
  return $slug
}
function Get-GetComputerHealthLatestReleaseMarker {
<#
.SYNOPSIS
Gets a stable marker string for the latest GitHub release.
.DESCRIPTION
Returns "owner/repo|tag|id" when available, otherwise $null on non-terminating failures.
#>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$RepositoryUrl)
  try {
    $slug = Convert-GitHubRepoUrlToSlug -RepoUrl $RepositoryUrl
    $api = "https://api.github.com/repos/$slug/releases/latest"
    $headers = @{
      'User-Agent' = 'PowerShell'
      'Accept'     = 'application/vnd.github+json'
    }
    $rel = Invoke-RestMethod -Method Get -Uri $api -Headers $headers -ErrorAction Stop
    $tag = [string]$rel.tag_name
    if ([string]::IsNullOrWhiteSpace($tag)) { $tag = 'untagged' }
    $id = [string]$rel.id
    if ([string]::IsNullOrWhiteSpace($id)) { $id = 'noid' }
    return ("{0}|{1}|{2}" -f $slug, $tag, $id)
  } catch {
    Write-Warning ("Could not query latest release metadata from {0}: {1}" -f $RepositoryUrl, $_.Exception.Message)
    return $null
  }
}

function Get-GetComputerHealthLatestRelease {
<#.SYNOPSIS
Gets latest GitHub release metadata for the configured repository.
#>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$RepositoryUrl)
  $slug = Convert-GitHubRepoUrlToSlug -RepoUrl $RepositoryUrl
  $api = "https://api.github.com/repos/$slug/releases/latest"
  $headers = @{
    'User-Agent' = 'PowerShell'
    'Accept'     = 'application/vnd.github+json'
  }
  return (Invoke-RestMethod -Method Get -Uri $api -Headers $headers -ErrorAction Stop)
}

function Expand-GetComputerHealthLatestRelease {
<#.SYNOPSIS
Downloads and extracts the latest release zip into a temporary folder.
.OUTPUTS
System.String. Full path to extracted release root directory.
#>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$RepositoryUrl,
    [Parameter(Mandatory)][string]$TempPath,
    [Parameter(Mandatory)][string]$ZipCacheDir
  )

  $release = Get-GetComputerHealthLatestRelease -RepositoryUrl $RepositoryUrl
  if (-not $release.zipball_url) {
    throw "Latest release does not include zipball_url."
  }

  $zipNameSafeTag = ([string]$release.tag_name -replace '[^a-zA-Z0-9._-]', '_').Trim('_')
  if ([string]::IsNullOrWhiteSpace($zipNameSafeTag)) { $zipNameSafeTag = 'untagged' }
  $zipPath = Join-Path $ZipCacheDir ("GetComputerHealth-release-{0}-{1}.zip" -f $zipNameSafeTag, $release.id)
  $extractPath = Join-Path $TempPath 'latest-release'
  if (-not (Test-Path $extractPath)) { $null = New-Item -ItemType Directory -Path $extractPath }

  $headers = @{
    'User-Agent' = 'PowerShell'
    'Accept'     = 'application/vnd.github+json'
  }
  Invoke-WebRequest -Uri $release.zipball_url -OutFile $zipPath -Headers $headers -UseBasicParsing -ErrorAction Stop
  Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force

  $root = Get-ChildItem -LiteralPath $extractPath -Directory | Select-Object -First 1
  if (-not $root) {
    throw "Release zip extracted but no top-level folder was found."
  }

  return $root.FullName
}

function Expand-ReleaseFromZipFile {
<#.SYNOPSIS
Extracts a provided release zip into a temporary folder and returns extracted root path.
#>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ZipPath,
    [Parameter(Mandatory)][string]$TempPath
  )

  if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
    throw "Zip file not found: $ZipPath"
  }

  $extractPath = Join-Path $TempPath 'provided-release'
  if (-not (Test-Path $extractPath)) { $null = New-Item -ItemType Directory -Path $extractPath }

  Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractPath -Force
  $root = Get-ChildItem -LiteralPath $extractPath -Directory | Select-Object -First 1
  if (-not $root) {
    throw "Provided zip extracted but no top-level folder was found."
  }
  return $root.FullName
}

function Keep-OnlyLatestReleaseZips {
<#.SYNOPSIS
Keeps only the latest N cached release zips.
#>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$CacheDir,
    [Parameter(Mandatory)][string]$Pattern,
    [int]$KeepCount = 2
  )

  try {
    $cachedZips = Get-ChildItem -LiteralPath $CacheDir -File -Filter $Pattern -ErrorAction Stop |
      Sort-Object -Property LastWriteTime -Descending
    if ($cachedZips.Count -gt $KeepCount) {
      $cachedZips | Select-Object -Skip $KeepCount | Remove-Item -Force -ErrorAction Stop
    }
  } catch {
    Write-Warning ("Failed pruning cached release zips in {0}: {1}" -f $CacheDir, $_.Exception.Message)
  }
}

function Sync-LocalFile {
<#
.SYNOPSIS
Copies a file from the extracted release and updates local copy if they differ.

.DESCRIPTION
Compares SourcePath\FileName to DestinationPath\FileName.

If the destination file does not exist, the downloaded file is placed into
DestinationPath.

If the destination file exists and content is identical, the temp file is
removed, and the destination file remains unchanged.

If the destination file exists and content differs, the destination file is
replaced with the downloaded file and the function returns $true. When
replacing an existing file, the function attempts to create a per-file
backup archive in BackupPath; backup failures do not prevent the update.

Warnings are emitted on copy or update failures.

.OUTPUTS
System.Boolean
$true  - DestinationPath\FileName was created or replaced.
$false - No change occurred or the operation failed.
#>
  [CmdletBinding()]
  param (
    [Parameter(Mandatory=$true)][string]$FileName,
    [Parameter(Mandatory=$true)][string]$SourcePath,
    [Parameter(Mandatory=$true)][string]$TempPath,
    [Parameter(Mandatory=$true)][string]$DestinationPath,
    [Parameter(Mandatory=$true)][string]$BackupPath
  )

  $releaseFilePath = Join-Path $SourcePath $FileName
  $DownloadPath = Join-Path $TempPath $FileName 
  $finalPath    = Join-Path $DestinationPath $FileName
  $updated      = $false

  try {
    if (-not (Test-Path -LiteralPath $releaseFilePath -PathType Leaf)) {
      throw "Expected file not found in release zip: $FileName"
    }
    Copy-Item -LiteralPath $releaseFilePath -Destination $DownloadPath -Force -ErrorAction Stop

    $newHash = (Get-FileHash -Path $DownloadPath -Algorithm SHA256).Hash
    $existingHash = $null

    if (Test-Path $finalPath) {
      try { $existingHash = (Get-FileHash -Path $finalPath -Algorithm SHA256).Hash } catch { $existingHash = $null }
    }

    $isDifferent = $true
    if ($existingHash -ne $null -and $existingHash -eq $newHash) { $isDifferent = $false }

    if ($isDifferent) {
      if (Test-Path $finalPath) {
        $leaf    = Split-Path $finalPath -Leaf
        $dateStr = (Get-Date -Format 'yyyyMMdd.hhmmss')
        $first8  = if ($existingHash) { $existingHash.Substring(0,8) } else { 'NOHASH' }
        $perFileZip = Join-Path $BackupPath ("{0}.{1}_{2}.zip" -f $leaf, $dateStr, $first8)

        $stageDir = Join-Path $TempPath ("_bak_{0}_{1}" -f ($leaf -replace '[^\w\.-]','_'), $first8)
        
        if (-not (Test-Path $stageDir)) { $null = New-Item -ItemType Directory -Path $stageDir }
        $stageFile = Join-Path $stageDir $leaf

        try {
          Copy-Item -LiteralPath $finalPath -Destination $stageFile -Force
          Compress-Archive -Path $stageFile -DestinationPath $perFileZip -Force
          Write-Host -ForegroundColor DarkGray ("Per-file backup created: {0}" -f $perFileZip)
        } catch {
          Write-Warning ("Failed to create per-file backup for {0}: {1}" -f $leaf, $_.Exception.Message)
        }
      }

      try {
        Move-Item -LiteralPath $DownloadPath -Destination $finalPath -Force
        Write-Host -ForegroundColor DarkGray ("Updated {0}" -f $finalPath)
        $updated = $true
      } catch {
        Write-Warning ("Failed to update {0}: {1}" -f $finalPath, $_.Exception.Message)
        try { if (Test-Path $DownloadPath) { Remove-Item -LiteralPath $DownloadPath -Force } } catch {}
      }
    } else {
      Remove-Item -LiteralPath $DownloadPath -Force
      Write-Verbose ("No change for {0}" -f $FileName)
      $updated = $false
    }
  } catch {
    Write-Warning ("Failed to stage {0} from extracted release: {1}" -f $FileName, $_.Exception.Message)
    try { if (Test-Path $DownloadPath) { Remove-Item -LiteralPath $DownloadPath -Force } } catch {}
    $updated = $false
  }

  return $updated
}
#
#  HELPER FUNCTIONS END
#
####################################################################

####################################################################
#
#  MAIN CODE
#

# Ensure dirs
if (-not (Test-Path $DEST_DIR)) { New-Item -ItemType Directory -Path $DEST_DIR | Out-Null }
if (-not (Test-Path $BAK_DIR))  { New-Item -ItemType Directory -Path $BAK_DIR  | Out-Null }
if (-not (Test-Path $CFG_DIR))  { New-Item -ItemType Directory -Path $CFG_DIR  | Out-Null }

# Install needed PS Modules
Ensure-PSModuleInstalled -Name ImportExcel

# Ensure file Get-ComputerHealth.sigs-to-suppress.txt exists
$p = 'C:\it\config\Get-ComputerHealth.sigs-to-suppress.txt'
if (-not (Test-Path $p)) {
    $null = mkdir C:\it\config -force -ErrorAction Ignore
    "# $($env:COMPUTERNAME)" | Out-File $p -Encoding UTF8
}

# Check latest release marker to avoid redownloading the same release repeatedly
$latestReleaseMarker = $null
if (-not $UpdateFromZip) {
  $latestReleaseMarker = Get-GetComputerHealthLatestReleaseMarker -RepositoryUrl $REPO_URL
}
if ($latestReleaseMarker) {
  $storedReleaseMarker = $null
  if (Test-Path -LiteralPath $LATEST_RELEASE_MARKER_PATH -PathType Leaf) {
    try {
      $storedReleaseMarker = (Get-Content -LiteralPath $LATEST_RELEASE_MARKER_PATH -ErrorAction Stop | Select-Object -First 1).Trim()
    } catch {
      Write-Warning ("Failed reading release marker file {0}: {1}" -f $LATEST_RELEASE_MARKER_PATH, $_.Exception.Message)
    }
  }
  if ((-not $Reinstall) -and $storedReleaseMarker -and ($storedReleaseMarker -eq $latestReleaseMarker)) {
    Write-Host -ForegroundColor DarkGray "Latest release already downloaded. Skipping update download."
    return
  }
  if ($Reinstall -and $storedReleaseMarker -and ($storedReleaseMarker -eq $latestReleaseMarker)) {
    Write-Host -ForegroundColor Yellow "-Reinstall was specified; re-downloading current latest release."
  }
}

# Download/update scripts
Write-Host -for DarkGray "Checking for code updates (I will backup local files before update)"
$tmdDir = New-EmptyTempDirectory -Name "Update-GetHealthCode"
$releaseRoot = $null
try {
  if ($UpdateFromZip) {
    Write-Host -ForegroundColor DarkGray ("Updating from provided zip: {0}" -f $UpdateFromZip)
    $releaseRoot = Expand-ReleaseFromZipFile -ZipPath $UpdateFromZip -TempPath $tmdDir
  } else {
    $releaseRoot = Expand-GetComputerHealthLatestRelease -RepositoryUrl $REPO_URL -TempPath $tmdDir -ZipCacheDir $BAK_DIR
    Keep-OnlyLatestReleaseZips -CacheDir $BAK_DIR -Pattern $ZIP_CACHE_PATTERN -KeepCount 2
  }
} catch {
  throw "Unable to prepare release zip: $($_.Exception.Message)"
}

$_=Sync-LocalFile -FileName 'lib-write-log-objects.ps1'      -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_=Sync-LocalFile -FileName 'ht-AD-GPO-mgmt.ps1'             -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_=Sync-LocalFile -FileName 'ht-DNS-DHCP-srvc.ps1'           -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_=Sync-LocalFile -FileName 'ht-syscfg-featdisc.ps1'         -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_=Sync-LocalFile -FileName 'ht-srvc-exe-resolve.ps1'        -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_=Sync-LocalFile -FileName 'ht-file-dir-anlz.ps1'           -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_=Sync-LocalFile -FileName 'ht-schtasks-master.ps1'         -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_=Sync-LocalFile -FileName 'ht-net-conn.ps1'                -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_=Sync-LocalFile -FileName 'ht-os-perf-hw.ps1'              -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_=Sync-LocalFile -FileName 'ht-win-os-hyg.ps1'              -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_=Sync-LocalFile -FileName 'ht-hyperv-mgmt.ps1'             -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_=Sync-LocalFile -FileName 'ht-special.ps1'                 -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_=Sync-LocalFile -FileName 'Get-ComputerHealth.ps1'         -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_=Sync-LocalFile -FileName 'Invoke-GetComputerHealth.ps1'   -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_=Sync-LocalFile -FileName 'Send-Message.ps1'               -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_=Sync-LocalFile -FileName 'helpers-processes.ps1'          -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_=Sync-LocalFile -FileName 'helpers-networking.ps1'         -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$updated = Sync-LocalFile -FileName 'Update-GetHealthCode.ps1' -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
if ($updated) {
    if ($latestReleaseMarker) {
      try {
        $latestReleaseMarker | Out-File -LiteralPath $LATEST_RELEASE_MARKER_PATH -Encoding UTF8 -Force
      } catch {
        Write-Warning ("Failed writing latest release marker to {0}: {1}" -f $LATEST_RELEASE_MARKER_PATH, $_.Exception.Message)
      }
    }
    Write-Host -ForegroundColor White "Rerunning myself because I was updated."
    & c:\it\bin\Update-GetHealthCode.ps1
    return
}

if ($latestReleaseMarker) {
  try {
    $latestReleaseMarker | Out-File -LiteralPath $LATEST_RELEASE_MARKER_PATH -Encoding UTF8 -Force
  } catch {
    Write-Warning ("Failed writing latest release marker to {0}: {1}" -f $LATEST_RELEASE_MARKER_PATH, $_.Exception.Message)
  }
}

# cleanups:
if ((Get-Date) -le [datetime]'2026-04-30') {
	if (test-path $DEST_DIR\lib-health-tests.ps1) {rm $DEST_DIR\lib-health-tests.ps1}
	if (test-path $DEST_DIR\lib-helpers-for-health-tests.ps1) {rm $DEST_DIR\lib-helpers-for-health-tests.ps1}
}

# Delete automatically created backup zips older than 1 month
try {
  $backupRetentionCutoff = (Get-Date).AddMonths(-1)
  Get-ChildItem -LiteralPath $BAK_DIR -File -Filter '*.zip' -ErrorAction Stop |
    Where-Object { $_.LastWriteTime -lt $backupRetentionCutoff } |
    Remove-Item -Force -ErrorAction Stop
} catch {
  Write-Warning ("Failed pruning old backups in {0}: {1}" -f $BAK_DIR, $_.Exception.Message)
}
