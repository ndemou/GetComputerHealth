# HostRequirement: All

function Check-UpdateAge {
  [CmdletBinding()]
  param([datetime]$Now = (Get-Date))

  $result = [pscustomobject]@{
    Succeeded = $false
    AgeDays = $null
    LastInstallDate = $null
    Source = 'Get-HotFix (installed CBS updates)'
    Error = $null
  }
  try {
    # CBS inventory excludes Defender definitions. This is a supplementary
    # installation-activity signal, not proof that every OS patch is installed.
    foreach ($hotfix in @(Get-HotFix -ErrorAction Stop)) {
      if (-not $hotfix.InstalledOn) { continue }
      $date = [datetime]$hotfix.InstalledOn
      if ($date -gt $Now) { throw 'An installed update has a future installation date.' }
      if ($null -eq $result.LastInstallDate -or $date -gt $result.LastInstallDate) {
        $result.LastInstallDate = $date
      }
    }
    if ($null -eq $result.LastInstallDate) { throw 'No installed CBS update has a usable installation date.' }
    $result.AgeDays = [int][math]::Floor(($Now - $result.LastInstallDate).TotalDays)
    $result.Succeeded = $true
  } catch {
    $result.Error = $_.Exception.Message
  }
  return $result
}

function Get-CachedWindowsSecurityUpdates {
  [CmdletBinding()]
  param([datetime]$Now = (Get-Date))

  $result = [pscustomobject]@{
    Succeeded = $false
    LastSearchSuccessDate = $null
    Updates = @()
    Error = $null
  }
  $session = $null
  $searcher = $null
  $automaticUpdates = $null
  $searchResult = $null
  try {
    # Do not activate WUA when its service is stopped. Never start services,
    # register scan packages, or refresh the catalog as part of this test.
    $service = Get-Service -Name wuauserv -ErrorAction Stop
    if ($service.Status -ne 'Running') { throw 'Windows Update service is not running; cached inspection was skipped.' }
    $automaticUpdates = New-Object -ComObject Microsoft.Update.AutoUpdate -ErrorAction Stop
    $lastSearch = $automaticUpdates.Results.LastSearchSuccessDate
    if ($lastSearch) {
      # WUA returns a UTC COM DATE without a DateTime Kind.
      $result.LastSearchSuccessDate = [datetime]::SpecifyKind([datetime]$lastSearch, [DateTimeKind]::Utc)
    }
    $session = New-Object -ComObject Microsoft.Update.Session -ErrorAction Stop
    $searcher = $session.CreateUpdateSearcher()
    # These are options on this searcher instance, not machine configuration.
    $searcher.Online = $false
    $searcher.CanAutomaticallyUpgradeService = $false
    $searcher.IncludePotentiallySupersededUpdates = $false
    $criteria = "IsInstalled=0 and IsHidden=0 and Type='Software' and CategoryIDs contains '0fa1201d-4330-4fa8-8ae9-b877473b6441'"
    $criteria += " or IsInstalled=0 and IsHidden=0 and Type='Software' and CategoryIDs contains 'e6cf1350-c01b-414d-a61f-263d14d133b4'"
    $searchResult = $searcher.Search($criteria)
    foreach ($update in $searchResult.Updates) {
      $published = [datetime]::SpecifyKind([datetime]$update.LastDeploymentChangeTime, [DateTimeKind]::Utc)
      $kbArticles = @()
      foreach ($kb in $update.KBArticleIDs) { $kbArticles += "KB$kb" }
      $result.Updates += [pscustomobject]@{
        Id = [string]$update.Identity.UpdateID
        KB = ($kbArticles -join ', ')
        Title = [string]$update.Title
        PublishedDate = $published
        AgeDays = $null
        Source = 'Windows Update cached security/critical classification'
        IsMonthlyBaseline = $false
      }
    }
    # SucceededWithErrors is incomplete, including when zero updates are returned.
    if ([int]$searchResult.ResultCode -ne 2) { throw "Cached search did not fully succeed (ResultCode $($searchResult.ResultCode))." }
    $result.Succeeded = $true
  } catch {
    $result.Error = $_.Exception.Message
  } finally {
    foreach ($comObject in @($searchResult, $searcher, $session, $automaticUpdates)) {
      if ($null -ne $comObject -and [Runtime.InteropServices.Marshal]::IsComObject($comObject)) {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($comObject)
      }
    }
  }
  return $result
}

function Get-WindowsSecurityReleaseHistory {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Html,
    [Parameter(Mandatory)][int]$BuildNumber
  )

  # Parse only release-history tables, not the "latest build" summary (which
  # can point to an optional preview). No browser/HTML COM engine is involved.
  foreach ($table in [regex]::Matches($Html, '(?is)<table\b[^>]*>.*?</table>')) {
    $headers = @()
    foreach ($header in [regex]::Matches($table.Value, '(?is)<th\b[^>]*>(.*?)</th>')) {
      $headers += [Net.WebUtility]::HtmlDecode(($header.Groups[1].Value -replace '<[^>]+>', '')).Trim()
    }
    if ('Update type' -notin $headers -or 'Build' -notin $headers -or
        'Availability date' -notin $headers -or 'KB article' -notin $headers -or 'Type' -in $headers) { continue }
    foreach ($row in [regex]::Matches($table.Value, '(?is)<tr\b[^>]*>.*?</tr>')) {
      $cells = @()
      foreach ($cell in [regex]::Matches($row.Value, '(?is)<td\b[^>]*>(.*?)</td>')) {
        $cells += [Net.WebUtility]::HtmlDecode(($cell.Groups[1].Value -replace '<[^>]+>', '')).Trim()
      }
      if ($cells.Count -ne $headers.Count) { continue }
      $type = $cells[[array]::IndexOf($headers, 'Update type')]
      $build = $cells[[array]::IndexOf($headers, 'Build')]
      # B releases are monthly security baselines. OOB does not imply security;
      # OOB security updates are still covered by the cached classifications.
      if ($type -notmatch '^\d{4}-\d{2}\s+B$' -or $build -notmatch ('^' + $BuildNumber + '\.\d+$')) { continue }
      $date = [datetime]::ParseExact($cells[[array]::IndexOf($headers, 'Availability date')], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
      $kb = [regex]::Match($cells[[array]::IndexOf($headers, 'KB article')], '\bKB\d+\b').Value
      if (-not $kb) { throw 'A matching Microsoft security release has no KB identifier.' }
      [pscustomobject]@{ Build = [version]$build; PublishedDate = [datetime]::SpecifyKind($date, [DateTimeKind]::Utc); KB = $kb }
    }
  }
}

function Get-OnlineWindowsSecurityBaseline {
  [CmdletBinding()]
  param([datetime]$Now = (Get-Date))

  $result = [pscustomobject]@{
    Succeeded = $false
    InstalledBuild = $null
    LatestBuild = $null
    LatestPublishedDate = $null
    Updates = @()
    Source = $null
    Error = $null
  }
  try {
    $os = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    if (-not $os.CurrentBuildNumber -or $null -eq $os.UBR -or -not $os.InstallationType) {
      throw 'Cannot identify the installed Windows build, revision, and installation type.'
    }
    $buildNumber = [int]$os.CurrentBuildNumber
    $result.InstalledBuild = [version]"$buildNumber.$($os.UBR)"
    $page = 'release-information'
    if ($os.InstallationType -like 'Server*') { $page = 'windows-server-release-info' }
    elseif ($os.InstallationType -ne 'Client') { throw "Unsupported Windows installation type '$($os.InstallationType)'." }
    elseif ($buildNumber -ge 22000) { $page = 'windows11-release-information' }
    $result.Source = "https://learn.microsoft.com/en-us/windows/release-health/$page"
    # Only an HTTPS GET; no scan, downloads of update packages, or persistent cache.
    $response = Invoke-WebRequest -Uri $result.Source -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    $releases = @(Get-WindowsSecurityReleaseHistory -Html $response.Content -BuildNumber $buildNumber | Sort-Object Build -Descending)
    if ($releases.Count -eq 0) { throw "No monthly security baseline found for build $buildNumber; the branch or page format may be unsupported." }
    $latest = $releases[0]
    $result.LatestBuild = $latest.Build
    $result.LatestPublishedDate = $latest.PublishedDate
    $nowUtc = $Now.ToUniversalTime()
    if ($latest.PublishedDate -gt $nowUtc) { throw 'The Microsoft baseline has a future publication date.' }
    $missing = @($releases | Where-Object { $_.Build -gt $result.InstalledBuild })
    if ($missing.Count -gt 0) {
      $oldest = $missing | Sort-Object PublishedDate | Select-Object -First 1
      # A new cumulative release supersedes old packages, but must not reset the
      # age of an existing security gap. Recommend the latest package only.
      $result.Updates = @([pscustomobject]@{
        Id = "OS baseline $($latest.Build)"
        KB = $latest.KB
        Title = "Windows OS monthly security baseline $($latest.Build) (installed $($result.InstalledBuild))"
        PublishedDate = $oldest.PublishedDate
        AgeDays = $null
        Source = "Microsoft release history; gap since $($oldest.KB); target $($latest.KB)"
        IsMonthlyBaseline = $true
      })
    }
    $result.Succeeded = $true
  } catch {
    $result.Error = $_.Exception.Message
  }
  return $result
}

function Check-PendingSecurityUpdates {
  [CmdletBinding()]
  param([datetime]$Now = (Get-Date))

  $cache = Get-CachedWindowsSecurityUpdates -Now $Now
  # Always consult the independent baseline, even when the cached query fails.
  $baseline = Get-OnlineWindowsSecurityBaseline -Now $Now
  $result = [pscustomobject]@{
    Succeeded = ($cache.Succeeded -and $baseline.Succeeded)
    LastSearchSuccessDate = $cache.LastSearchSuccessDate
    Updates = @($cache.Updates) + @($baseline.Updates)
    Errors = @()
    BaselineSource = $baseline.Source
    InstalledBuild = $baseline.InstalledBuild
    LatestBuild = $baseline.LatestBuild
    LatestPublishedDate = $baseline.LatestPublishedDate
  }
  if (-not $cache.Succeeded) { $result.Errors += "Cached inspection: $($cache.Error)" }
  if (-not $baseline.Succeeded) { $result.Errors += "Online OS baseline: $($baseline.Error)" }
  foreach ($update in $result.Updates) {
    if (-not $update.PublishedDate -or $update.PublishedDate -lt [datetime]'2000-01-01' -or $update.PublishedDate.ToUniversalTime() -gt $Now.ToUniversalTime()) {
      $result.Errors += "Unknown or invalid publication date for '$($update.Title)'."
      $result.Succeeded = $false
    } else {
      $update.AgeDays = [int][math]::Floor(($Now.ToUniversalTime() - $update.PublishedDate.ToUniversalTime()).TotalDays)
    }
  }
  return $result
}

function HealthTest-WindowsUpdates {
<#
Description: Checks pending security updates, cached scan freshness, the online OS security baseline, and installation age.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Tags: Essential
Uses: Check-PendingSecurityUpdates, Check-UpdateAge.
#>
  [CmdletBinding()]
  param(
    [ValidateRange(1, 3650)][int]$PendingWarnDays = 8,
    [ValidateRange(1, 3650)][int]$PendingFailDays = 15,
    [ValidateRange(1, 3650)][int]$UpdateAgeWarnDays = 45,
    [ValidateRange(1, 3650)][int]$UpdateAgeFailDays = 60,
    [ValidateRange(1, 8760)][int]$MaxScanAgeHours = 48,
    [ValidateRange(1, 3650)][int]$MaxBaselineAgeDays = 45
  )

  if ($PendingWarnDays -ge $PendingFailDays -or $UpdateAgeWarnDays -ge $UpdateAgeFailDays) {
    throw 'Each warning threshold must be lower than its failure threshold.'
  }
  $now = Get-Date
  $hadIssue = $false
  $pending = Check-PendingSecurityUpdates -Now $now
  $age = Check-UpdateAge -Now $now
  Write-Debug "Windows Update OS baseline: installed build=$($pending.InstalledBuild); latest build=$($pending.LatestBuild); publication (UTC)=$($pending.LatestPublishedDate); source=$($pending.BaselineSource)."
  Write-Debug "Windows Update installation inventory: succeeded=$($age.Succeeded); source=$($age.Source); last installation=$($age.LastInstallDate); age days=$($age.AgeDays); error=$($age.Error)."
  foreach ($errorMessage in $pending.Errors) {
    Write-Debug "Windows Update inspection error: $errorMessage"
  }
  if ($pending.Errors.Count -gt 0) {
    $hadIssue = $true
    Write-Warning "[WARNING] Some Windows update checks could not be completed.`nCheck that Windows Update is working and this computer can reach Microsoft's release information."
  }
  # Do not call a discontinued branch (or an outdated public table) current.
  if (-not $pending.LatestPublishedDate -or
      ($now.ToUniversalTime() - $pending.LatestPublishedDate.ToUniversalTime()).TotalDays -gt $MaxBaselineAgeDays) {
    $hadIssue = $true
    Write-Warning "[WARNING] Current Windows security update information could not be confirmed.`nCheck this Windows version's update support and access to Microsoft's release information."
  }
  $lastSearch = $pending.LastSearchSuccessDate
  Write-Debug "Windows Update last successful automatic scan (UTC): $lastSearch; maximum age: $MaxScanAgeHours hours. No online scan was requested."
  if (-not $lastSearch -or $lastSearch.ToUniversalTime() -gt $now.ToUniversalTime() -or
      ($now.ToUniversalTime() - $lastSearch.ToUniversalTime()).TotalHours -gt $MaxScanAgeHours) {
    $hadIssue = $true
    Write-Warning "[WARNING] Windows Update has no recent successful check for updates.`nCheck that Windows Update can check for updates successfully."
  }
  $ageLevel = $null
  if ($age.Succeeded) {
    if ($age.AgeDays -ge $UpdateAgeFailDays) { $ageLevel = 'FAILURE' }
    elseif ($age.AgeDays -ge $UpdateAgeWarnDays) { $ageLevel = 'WARNING' }
  }
  $combinedUpdate = $null
  if ($ageLevel -eq 'FAILURE') {
    $combinedUpdate = $pending.Updates |
      Where-Object { $null -ne $_.AgeDays -and $_.AgeDays -ge $PendingFailDays } |
      Sort-Object IsMonthlyBaseline, AgeDays -Descending |
      Select-Object -First 1
  }
  foreach ($update in $pending.Updates) {
    Write-Debug "Pending Windows update: id=$($update.Id); title=$($update.Title); KB=$($update.KB); age days=$($update.AgeDays); publication/gap date (UTC)=$($update.PublishedDate); source=$($update.Source)."
    if ($null -eq $update.AgeDays) { continue }
    $level = $null
    if ($update.AgeDays -ge $PendingFailDays) { $level = 'FAILURE' }
    elseif ($update.AgeDays -ge $PendingWarnDays) { $level = 'WARNING' }
    if ($level) {
      $hadIssue = $true
      # The combined finding already identifies this monthly target. Retain all
      # other pending updates, including unrelated component/security failures.
      if ($combinedUpdate -and $combinedUpdate.IsMonthlyBaseline -and $update -ne $combinedUpdate -and
          ($update.KB -replace 'KB', '') -eq ($combinedUpdate.KB -replace 'KB', '')) { continue }
      $dateText = $update.PublishedDate.ToString('yyyy-MM-dd')
      $targetText = ''
      if ($update.IsMonthlyBaseline) {
        $missingText = "Missing monthly security updates since $($update.AgeDays) days ago ($dateText)."
        $targetText = "`nLatest monthly security update to install: $($update.KB)."
      } else {
        $missingText = "An uninstalled security or critical update was last published $($update.AgeDays) days ago ($dateText)."
        if ($update.KB) { $targetText = "`nUpdate to check: $($update.KB)." }
      }
      if ($update -eq $combinedUpdate) {
        if ($update.IsMonthlyBaseline) {
          $missingText = "Security fixes released $($update.AgeDays) days ago are still missing."
        }
        $message = "[FAILURE] Windows security updates are seriously overdue.`n$missingText`nThe last recorded Windows system update installation was $($age.AgeDays) days ago.`n"
      } else {
        $message = "[$level] This computer is missing Windows security updates.`n$missingText"
      }
      Write-Warning "$message`nCheck Windows Update for failed or blocked installations.$targetText"
    }
  }
  if (-not $age.Succeeded) {
    $hadIssue = $true
    Write-Warning "[WARNING] The last Windows system update installation could not be determined.`nCheck Windows Update installation history."
  } elseif ($ageLevel -and -not $combinedUpdate) {
    $hadIssue = $true
    Write-Warning "[$ageLevel] No recent Windows system update installation was found.`nLast recorded installation: $($age.AgeDays) days ago ($($age.LastInstallDate.ToString('yyyy-MM-dd'))).`nCheck why Windows system updates are not being installed."
  }
  if (-not $pending.Succeeded) { $hadIssue = $true }
  if (-not $hadIssue) {
    Write-Warning '[PASS] Windows updates are within the configured time limits.'
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-WindowsUpdates
}
