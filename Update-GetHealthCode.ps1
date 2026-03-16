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
[CmdletBinding()]
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
None.
#>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Name,
    [string]$Scope = 'AllUsers'
  )

  Write-Verbose "Checking whether PowerShell module '$Name' is already installed"
  if (Get-Module -ListAvailable -Name $Name) {
    Write-Verbose "Module '$Name' is already installed"
    return
  }

  try {
    Write-Verbose "Installing PowerShell module '$Name' with scope '$Scope'"
    Install-Module -Name $Name -Scope $Scope -Force -ErrorAction Stop
    Write-Verbose "Successfully installed PowerShell module '$Name'"
  } catch {
    if ($_.Exception.Message -like "*No repository with the Name 'PSGallery'*") {
      Write-Warning "Registering PSGallery"
      Write-Verbose "Registering default PSRepository because PSGallery was missing"
      Register-PSRepository -Default -ErrorAction Stop
      Write-Verbose "Marking PSGallery as Trusted"
      Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
      Write-Verbose "Retrying installation of PowerShell module '$Name'"
      Install-Module -Name $Name -Scope $Scope -Force -ErrorAction Stop
      Write-Verbose "Successfully installed PowerShell module '$Name' after registering PSGallery"
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
System.String. The full path of the created directory under $env:TEMP.
#>
  [CmdletBinding()]
  param([string]$Name)

  $tmdDir = Join-Path $env:TEMP $Name
  Write-Verbose "Preparing temporary directory '$tmdDir'"

  if (Test-Path -Path $tmdDir) {
    if (Test-Path -Path $tmdDir -PathType Container) {
      Write-Verbose "Temporary directory already exists; clearing its contents: '$tmdDir'"
      Get-ChildItem -Path $tmdDir -Recurse -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    } else {
      Write-Verbose "A file already exists at '$tmdDir'; generating a unique directory name"
      while (Test-Path -Path $tmdDir) {
        $suffix = Get-Random -Minimum 100000 -Maximum 1000000
        $tmdDir = Join-Path $env:TEMP "$Name-$suffix"
      }
      Write-Verbose "Using alternate temporary directory '$tmdDir'"
    }
  }

  $null = New-Item -ItemType Directory -Path $tmdDir -Force
  Write-Verbose "Temporary directory ready: '$tmdDir'"
  return $tmdDir
}

function Convert-GitHubRepoUrlToSlug {
<#
.SYNOPSIS
Converts a GitHub repo URL into "owner/repo" format.
#>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$RepoUrl)

  Write-Verbose "Converting repository URL to slug: '$RepoUrl'"
  $slug = ($RepoUrl -replace '^https?://github\.com/','') -replace '\.git$',''
  $slug = $slug.Trim('/')
  if ([string]::IsNullOrWhiteSpace($slug)) {
    throw "Invalid GitHub repository URL: $RepoUrl"
  }
  Write-Verbose "Repository slug resolved to '$slug'"
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
    Write-Verbose "Querying latest release marker for '$RepositoryUrl'"
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
    $marker = ("{0}|{1}|{2}" -f $slug, $tag, $id)
    Write-Verbose "Latest release marker is '$marker'"
    return $marker
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

  Write-Verbose "Querying latest release metadata for '$RepositoryUrl'"
  $slug = Convert-GitHubRepoUrlToSlug -RepoUrl $RepositoryUrl
  $api = "https://api.github.com/repos/$slug/releases/latest"
  $headers = @{
    'User-Agent' = 'PowerShell'
    'Accept'     = 'application/vnd.github+json'
  }
  $release = Invoke-RestMethod -Method Get -Uri $api -Headers $headers -ErrorAction Stop
  Write-Verbose ("Latest release metadata retrieved: tag='{0}', id='{1}'" -f $release.tag_name, $release.id)
  return $release
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

  Write-Verbose "Preparing latest release from GitHub"
  $release = Get-GetComputerHealthLatestRelease -RepositoryUrl $RepositoryUrl
  if (-not $release.zipball_url) {
    throw "Latest release does not include zipball_url."
  }

  $zipNameSafeTag = ([string]$release.tag_name -replace '[^a-zA-Z0-9._-]', '_').Trim('_')
  if ([string]::IsNullOrWhiteSpace($zipNameSafeTag)) { $zipNameSafeTag = 'untagged' }

  $zipPath = Join-Path $ZipCacheDir ("GetComputerHealth-release-{0}-{1}.zip" -f $zipNameSafeTag, $release.id)
  $extractPath = Join-Path $TempPath 'latest-release'

  Write-Verbose "Release zip will be cached at '$zipPath'"
  Write-Verbose "Release zip will be extracted to '$extractPath'"

  if (-not (Test-Path $extractPath)) {
    $null = New-Item -ItemType Directory -Path $extractPath
  }

  $headers = @{
    'User-Agent' = 'PowerShell'
    'Accept'     = 'application/vnd.github+json'
  }

  Write-Verbose "Downloading release zip from GitHub"
  Invoke-WebRequest -Uri $release.zipball_url -OutFile $zipPath -Headers $headers -UseBasicParsing -ErrorAction Stop

  Write-Verbose "Expanding release zip '$zipPath'"
  Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force

  $root = Get-ChildItem -LiteralPath $extractPath -Directory | Select-Object -First 1
  if (-not $root) {
    throw "Release zip extracted but no top-level folder was found."
  }

  Write-Verbose "Extracted release root is '$($root.FullName)'"
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

  Write-Verbose "Preparing release from provided zip '$ZipPath'"
  if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
    throw "Zip file not found: $ZipPath"
  }

  $extractPath = Join-Path $TempPath 'provided-release'
  Write-Verbose "Provided zip will be extracted to '$extractPath'"

  if (-not (Test-Path $extractPath)) {
    $null = New-Item -ItemType Directory -Path $extractPath
  }

  Write-Verbose "Expanding provided zip '$ZipPath'"
  Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractPath -Force

  $root = Get-ChildItem -LiteralPath $extractPath -Directory | Select-Object -First 1
  if (-not $root) {
    throw "Provided zip extracted but no top-level folder was found."
  }

  Write-Verbose "Extracted provided release root is '$($root.FullName)'"
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
    Write-Verbose "Pruning cached release zips in '$CacheDir' using pattern '$Pattern'; keeping newest $KeepCount"
    $cachedZips = Get-ChildItem -LiteralPath $CacheDir -File -Filter $Pattern -ErrorAction Stop |
      Sort-Object -Property LastWriteTime -Descending

    Write-Verbose ("Found {0} cached release zip(s)" -f @($cachedZips).Count)

    if ($cachedZips.Count -gt $KeepCount) {
      $toDelete = $cachedZips | Select-Object -Skip $KeepCount
      foreach ($item in $toDelete) {
        Write-Verbose "Deleting old cached release zip '$($item.FullName)'"
      }
      $toDelete | Remove-Item -Force -ErrorAction Stop
    } else {
      Write-Verbose "No cached release zips need pruning"
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

  Write-Verbose "Synchronizing file '$FileName'"
  Write-Verbose "  Source      : $releaseFilePath"
  Write-Verbose "  Temp        : $DownloadPath"
  Write-Verbose "  Destination : $finalPath"

  try {
    if (-not (Test-Path -LiteralPath $releaseFilePath -PathType Leaf)) {
      throw "Expected file not found in release zip: $FileName"
    }

    Write-Verbose "Copying release file to temporary staging path"
    Copy-Item -LiteralPath $releaseFilePath -Destination $DownloadPath -Force -ErrorAction Stop

    $newHash = (Get-FileHash -Path $DownloadPath -Algorithm SHA256).Hash
    $existingHash = $null

    if (Test-Path $finalPath) {
      Write-Verbose "Destination file already exists; computing current hash"
      try {
        $existingHash = (Get-FileHash -Path $finalPath -Algorithm SHA256).Hash
      } catch {
        Write-Verbose "Failed computing existing hash for '$finalPath'; proceeding as different"
        $existingHash = $null
      }
    } else {
      Write-Verbose "Destination file does not exist and will be created"
    }

    $isDifferent = $true
    if ($existingHash -ne $null -and $existingHash -eq $newHash) {
      $isDifferent = $false
    }

    if ($isDifferent) {
      Write-Verbose "File content differs or destination is missing; update is required"

      if (Test-Path $finalPath) {
        $leaf    = Split-Path $finalPath -Leaf
        $dateStr = (Get-Date -Format 'yyyyMMdd.hhmmss')
        $first8  = if ($existingHash) { $existingHash.Substring(0,8) } else { 'NOHASH' }
        $perFileZip = Join-Path $BackupPath ("{0}.{1}_{2}.zip" -f $leaf, $dateStr, $first8)
        $stageDir = Join-Path $TempPath ("_bak_{0}_{1}" -f ($leaf -replace '[^\w\.-]','_'), $first8)
        $stageFile = Join-Path $stageDir $leaf

        if (-not (Test-Path $stageDir)) {
          $null = New-Item -ItemType Directory -Path $stageDir
        }

        try {
          Write-Verbose "Creating per-file backup archive '$perFileZip'"
          Copy-Item -LiteralPath $finalPath -Destination $stageFile -Force
          Compress-Archive -Path $stageFile -DestinationPath $perFileZip -Force
          Write-Verbose "Per-file backup created: '$perFileZip'"
        } catch {
          Write-Warning ("Failed to create per-file backup for {0}: {1}" -f $leaf, $_.Exception.Message)
        }
      }

      try {
        Write-Verbose "Replacing destination file '$finalPath'"
        Move-Item -LiteralPath $DownloadPath -Destination $finalPath -Force
        Write-Verbose "Updated '$finalPath'"
        $updated = $true
      } catch {
        Write-Warning ("Failed to update {0}: {1}" -f $finalPath, $_.Exception.Message)
        try {
          if (Test-Path $DownloadPath) {
            Remove-Item -LiteralPath $DownloadPath -Force
          }
        } catch {}
      }
    } else {
      Write-Verbose "No content change detected for '$FileName'"
      Remove-Item -LiteralPath $DownloadPath -Force
      $updated = $false
    }
  } catch {
    Write-Warning ("Failed to stage {0} from extracted release: {1}" -f $FileName, $_.Exception.Message)
    try {
      if (Test-Path $DownloadPath) {
        Remove-Item -LiteralPath $DownloadPath -Force
      }
    } catch {}
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
Write-Verbose "Starting Update-GetHealthCode"
Write-Verbose "Parameters: Reinstall=$Reinstall UpdateFromZip='$UpdateFromZip'"
Write-Verbose "Configuration:"
Write-Verbose "  DEST_DIR                    : $DEST_DIR"
Write-Verbose "  BAK_DIR                     : $BAK_DIR"
Write-Verbose "  CFG_DIR                     : $CFG_DIR"
Write-Verbose "  REPO_URL                    : $REPO_URL"
Write-Verbose "  REPO_REF                    : $REPO_REF"
Write-Verbose "  LATEST_RELEASE_MARKER_PATH  : $LATEST_RELEASE_MARKER_PATH"
Write-Verbose "  ZIP_CACHE_PATTERN           : $ZIP_CACHE_PATTERN"
Write-Verbose "  repoSlug                    : $repoSlug"

if (-not (Test-Path $DEST_DIR)) {
  Write-Verbose "Creating destination directory '$DEST_DIR'"
  New-Item -ItemType Directory -Path $DEST_DIR | Out-Null
} else {
  Write-Verbose "Destination directory already exists: '$DEST_DIR'"
}

if (-not (Test-Path $BAK_DIR)) {
  Write-Verbose "Creating backup/cache directory '$BAK_DIR'"
  New-Item -ItemType Directory -Path $BAK_DIR | Out-Null
} else {
  Write-Verbose "Backup/cache directory already exists: '$BAK_DIR'"
}

if (-not (Test-Path $CFG_DIR)) {
  Write-Verbose "Creating configuration directory '$CFG_DIR'"
  New-Item -ItemType Directory -Path $CFG_DIR | Out-Null
} else {
  Write-Verbose "Configuration directory already exists: '$CFG_DIR'"
}

Ensure-PSModuleInstalled -Name ImportExcel

$p = 'C:\it\config\Get-ComputerHealth.sigs-to-suppress.txt'
if (-not (Test-Path $p)) {
  Write-Verbose "Creating default suppressions file '$p'"
  $null = mkdir C:\it\config -Force -ErrorAction Ignore
  "# $($env:COMPUTERNAME)" | Out-File $p -Encoding UTF8
} else {
  Write-Verbose "Suppressions file already exists: '$p'"
}

$latestReleaseMarker = $null
if (-not $UpdateFromZip) {
  Write-Verbose "No -UpdateFromZip specified; querying latest GitHub release marker"
  $latestReleaseMarker = Get-GetComputerHealthLatestReleaseMarker -RepositoryUrl $REPO_URL
} else {
  Write-Verbose "-UpdateFromZip specified; skipping latest release marker query"
}

if ($latestReleaseMarker) {
  $storedReleaseMarker = $null

  if (Test-Path -LiteralPath $LATEST_RELEASE_MARKER_PATH -PathType Leaf) {
    Write-Verbose "Reading stored release marker from '$LATEST_RELEASE_MARKER_PATH'"
    try {
      $storedReleaseMarker = (Get-Content -LiteralPath $LATEST_RELEASE_MARKER_PATH -ErrorAction Stop | Select-Object -First 1).Trim()
      Write-Verbose "Stored release marker is '$storedReleaseMarker'"
    } catch {
      Write-Warning ("Failed reading release marker file {0}: {1}" -f $LATEST_RELEASE_MARKER_PATH, $_.Exception.Message)
    }
  } else {
    Write-Verbose "Stored release marker file does not exist yet"
  }

  if ((-not $Reinstall) -and $storedReleaseMarker -and ($storedReleaseMarker -eq $latestReleaseMarker)) {
    Write-Verbose "Latest release already downloaded and -Reinstall was not specified; skipping update download"
    return
  }

  if ($Reinstall -and $storedReleaseMarker -and ($storedReleaseMarker -eq $latestReleaseMarker)) {
    Write-Verbose "-Reinstall was specified; re-downloading current latest release"
  }
} else {
  Write-Verbose "No latest release marker is available"
}

Write-Verbose "Checking for code updates; local files will be backed up before replacement if needed"
$tmdDir = New-EmptyTempDirectory -Name "Update-GetHealthCode"
$releaseRoot = $null

try {
  if ($UpdateFromZip) {
    Write-Verbose "Updating from provided zip '$UpdateFromZip'"
    $releaseRoot = Expand-ReleaseFromZipFile -ZipPath $UpdateFromZip -TempPath $tmdDir
  } else {
    Write-Verbose "Updating from latest GitHub release"
    $releaseRoot = Expand-GetComputerHealthLatestRelease -RepositoryUrl $REPO_URL -TempPath $tmdDir -ZipCacheDir $BAK_DIR
    Keep-OnlyLatestReleaseZips -CacheDir $BAK_DIR -Pattern $ZIP_CACHE_PATTERN -KeepCount 2
  }
  Write-Verbose "Release root resolved to '$releaseRoot'"
} catch {
  throw "Unable to prepare release zip: $($_.Exception.Message)"
}

$_ = Sync-LocalFile -FileName 'lib-write-log-objects.ps1'      -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_ = Sync-LocalFile -FileName 'ht-AD-GPO-mgmt.ps1'             -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_ = Sync-LocalFile -FileName 'ht-DNS-DHCP-srvc.ps1'           -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_ = Sync-LocalFile -FileName 'ht-syscfg-featdisc.ps1'         -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_ = Sync-LocalFile -FileName 'ht-srvc-exe-resolve.ps1'        -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_ = Sync-LocalFile -FileName 'ht-file-dir-anlz.ps1'           -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_ = Sync-LocalFile -FileName 'ht-schtasks-master.ps1'         -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_ = Sync-LocalFile -FileName 'ht-net-conn.ps1'                -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_ = Sync-LocalFile -FileName 'ht-os-perf-hw.ps1'              -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_ = Sync-LocalFile -FileName 'ht-win-os-hyg.ps1'              -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_ = Sync-LocalFile -FileName 'ht-hyperv-mgmt.ps1'             -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_ = Sync-LocalFile -FileName 'ht-special.ps1'                 -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_ = Sync-LocalFile -FileName 'Get-ComputerHealth.ps1'         -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_ = Sync-LocalFile -FileName 'Invoke-GetComputerHealth.ps1'   -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_ = Sync-LocalFile -FileName 'Send-Message.ps1'               -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_ = Sync-LocalFile -FileName 'helpers-processes.ps1'          -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$_ = Sync-LocalFile -FileName 'helpers-networking.ps1'         -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR
$updated = Sync-LocalFile -FileName 'Update-GetHealthCode.ps1' -SourcePath $releaseRoot -TempPath $tmdDir -DestinationPath $DEST_DIR -BackupPath $BAK_DIR

if ($updated) {
  Write-Verbose "This script updated itself"

  if ($latestReleaseMarker) {
    try {
      Write-Verbose "Writing latest release marker to '$LATEST_RELEASE_MARKER_PATH'"
      $latestReleaseMarker | Out-File -LiteralPath $LATEST_RELEASE_MARKER_PATH -Encoding UTF8 -Force
    } catch {
      Write-Warning ("Failed writing latest release marker to {0}: {1}" -f $LATEST_RELEASE_MARKER_PATH, $_.Exception.Message)
    }
  }

#  Write-Verbose "Rerunning updated copy 'C:\it\bin\Update-GetHealthCode.ps1'"
#  & C:\it\bin\Update-GetHealthCode.ps1 @PSBoundParameters
  return
}

if ($latestReleaseMarker) {
  try {
    Write-Verbose "Writing latest release marker to '$LATEST_RELEASE_MARKER_PATH'"
    $latestReleaseMarker | Out-File -LiteralPath $LATEST_RELEASE_MARKER_PATH -Encoding UTF8 -Force
  } catch {
    Write-Warning ("Failed writing latest release marker to {0}: {1}" -f $LATEST_RELEASE_MARKER_PATH, $_.Exception.Message)
  }
}

if ((Get-Date) -le [datetime]'2026-04-30') {
  Write-Verbose "Executing temporary cleanup for obsolete files"
  if (Test-Path $DEST_DIR\lib-health-tests.ps1) {
    Write-Verbose "Removing obsolete file '$DEST_DIR\lib-health-tests.ps1'"
    Remove-Item $DEST_DIR\lib-health-tests.ps1
  }
  if (Test-Path $DEST_DIR\lib-helpers-for-health-tests.ps1) {
    Write-Verbose "Removing obsolete file '$DEST_DIR\lib-helpers-for-health-tests.ps1'"
    Remove-Item $DEST_DIR\lib-helpers-for-health-tests.ps1
  }
}

try {
  $backupRetentionCutoff = (Get-Date).AddMonths(-1)
  Write-Verbose "Pruning backup zip files older than '$backupRetentionCutoff' from '$BAK_DIR'"

  $oldBackups = Get-ChildItem -LiteralPath $BAK_DIR -File -Filter '*.zip' -ErrorAction Stop |
    Where-Object { $_.LastWriteTime -lt $backupRetentionCutoff }

  foreach ($item in $oldBackups) {
    Write-Verbose "Deleting old backup zip '$($item.FullName)'"
  }

  $oldBackups | Remove-Item -Force -ErrorAction Stop
} catch {
  Write-Warning ("Failed pruning old backups in {0}: {1}" -f $BAK_DIR, $_.Exception.Message)
}

Write-Verbose "Update-GetHealthCode completed"