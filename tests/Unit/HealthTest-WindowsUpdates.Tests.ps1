Describe 'Windows update checks' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $repoRoot 'health-tests\HealthTest-WindowsUpdates.ps1')

    function New-TestReleaseHtml {
      param([string]$Rows)
      return "<table><thead><tr><th>Servicing option</th><th>Update type</th><th>Availability date</th><th>Build</th><th>KB article</th></tr></thead><tbody>$Rows</tbody></table>"
    }

    function New-TestPendingUpdate {
      param([int]$Days, [string]$Id = 'pending-security', [switch]$Monthly)
      [pscustomobject]@{
        Id = $Id; KB = 'KB1234567'; Title = 'Security update'; AgeDays = $Days
        PublishedDate = $script:now.AddDays(-$Days); Source = 'test catalog'
        IsMonthlyBaseline = [bool]$Monthly
      }
    }
  }

  BeforeEach {
    $script:now = [datetime]'2026-10-15T12:00:00Z'
    $script:warnings = @()
    $script:debugMessages = @()
    Mock Write-Warning { $script:warnings += $Message }
    Mock Write-Debug { $script:debugMessages += $Message }
  }

  Context 'Installation activity facts' {
    It 'returns the newest installed CBS date and age without emitting a health finding' {
      Mock Get-HotFix { @(
        [pscustomobject]@{ InstalledOn = $script:now.AddDays(-80) }
        [pscustomobject]@{ InstalledOn = $script:now.AddDays(-46) }
        [pscustomobject]@{ InstalledOn = $null }
      ) }
      $result = Check-UpdateAge -Now $script:now
      $result.Succeeded | Should -BeTrue
      $result.AgeDays | Should -Be 46
      $result.LastInstallDate | Should -Be $script:now.AddDays(-46)
      $script:warnings.Count | Should -Be 0
    }

    It 'does not turn missing, failed, or invalid installation inventory into age zero' -ForEach @(
      @{ Case = 'missing' }, @{ Case = 'failed' }, @{ Case = 'future' }, @{ Case = 'malformed' }
    ) {
      Mock Get-HotFix {
        switch ($Case) {
          'failed' { throw 'WMI unavailable' }
          'future' { [pscustomobject]@{ InstalledOn = $script:now.AddDays(1) } }
          'malformed' { [pscustomobject]@{ InstalledOn = 'invalid date' } }
        }
      }
      $result = Check-UpdateAge -Now $script:now
      $result.Succeeded | Should -BeFalse
      $result.AgeDays | Should -BeNullOrEmpty
      $result.Error | Should -Not -BeNullOrEmpty
    }
  }

  Context 'Cached WUA inspection' {
    BeforeEach {
      $script:searcher = [pscustomobject]@{
        Online = $true; CanAutomaticallyUpgradeService = $true
        IncludePotentiallySupersededUpdates = $true
      }
      $script:searcher | Add-Member ScriptMethod Search {
        param($criteria)
        if ($this.Online -or $this.CanAutomaticallyUpgradeService -or $this.IncludePotentiallySupersededUpdates) {
          throw 'Unsafe search options'
        }
        $script:criteriaUsed = $criteria
        return $script:searchResult
      }
      $script:session = [pscustomobject]@{}
      $script:session | Add-Member ScriptMethod CreateUpdateSearcher { return $script:searcher }
      $script:searchResult = [pscustomobject]@{ ResultCode = 2; Updates = @() }
      Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
      Mock New-Object {
        if ($ComObject -eq 'Microsoft.Update.AutoUpdate') {
          return [pscustomobject]@{ Results = [pscustomobject]@{ LastSearchSuccessDate = $script:now.ToUniversalTime().AddHours(-1) } }
        }
        if ($ComObject -eq 'Microsoft.Update.Session') { return $script:session }
        throw "Unexpected COM activation: $ComObject"
      }
    }

    It 'queries only cached security and critical software updates without refresh or superseded entries' {
      $result = Get-CachedWindowsSecurityUpdates -Now $script:now
      $result.Succeeded | Should -BeTrue
      $result.LastSearchSuccessDate.Kind | Should -Be 'Utc'
      $script:criteriaUsed | Should -Match '0fa1201d-4330-4fa8-8ae9-b877473b6441'
      $script:criteriaUsed | Should -Match 'e6cf1350-c01b-414d-a61f-263d14d133b4'
      $script:criteriaUsed | Should -Not -Match 'e0789628-ce08-4437-be74-2495b842f43b'
      $script:criteriaUsed | Should -Match "IsInstalled=0 and IsHidden=0 and Type='Software'"
    }

    It 'does not activate WUA when its service is stopped' {
      Mock Get-Service { [pscustomobject]@{ Status = 'Stopped' } }
      $result = Get-CachedWindowsSecurityUpdates -Now $script:now
      $result.Succeeded | Should -BeFalse
      Should -Invoke New-Object -Times 0
    }

    It 'retains known pending security updates when a cached search is incomplete' {
      $script:searchResult.ResultCode = 3
      $script:searchResult.Updates = @([pscustomobject]@{
        Identity = [pscustomobject]@{ UpdateID = 'stuck' }
        Title = 'Critical Windows update'; KBArticleIDs = @('1234567')
        LastDeploymentChangeTime = $script:now.AddDays(-20)
      })
      $result = Get-CachedWindowsSecurityUpdates -Now $script:now
      $result.Succeeded | Should -BeFalse
      $result.Updates.Count | Should -Be 1
      $result.Updates[0].Id | Should -Be 'stuck'
      $result.Updates[0].KB | Should -Be 'KB1234567'
    }

    It 'reports COM access failures as unavailable inspection' {
      Mock New-Object { throw 'Access denied' }
      $result = Get-CachedWindowsSecurityUpdates -Now $script:now
      $result.Succeeded | Should -BeFalse
      $result.Error | Should -Match 'Access denied'
    }

    It 'does not treat zero results from an incomplete search as successful coverage' {
      $script:searchResult.ResultCode = 3
      $result = Get-CachedWindowsSecurityUpdates -Now $script:now
      $result.Succeeded | Should -BeFalse
      $result.Updates.Count | Should -Be 0
    }
  }

  Context 'Online monthly OS baseline' {
    BeforeEach {
      Mock Get-ItemProperty { [pscustomobject]@{ CurrentBuildNumber = '20348'; UBR = 4200; InstallationType = 'Server Core' } }
      $script:html = New-TestReleaseHtml @'
<tr><td>LTSC</td><td>2026-10 B</td><td>2026-10-13</td><td>20348.4400</td><td><a href="https://support.microsoft.com/help/1234400">KB1234400</a></td></tr>
<tr><td>LTSC</td><td>2026-09 B</td><td>2026-09-08</td><td>20348.4300</td><td>KB1234300</td></tr>
<tr><td>LTSC</td><td>2026-09 D</td><td>2026-09-22</td><td>20348.4350</td><td>KB1234350</td></tr>
<tr><td>LTSC</td><td>2026-10 OOB</td><td>2026-10-14</td><td>20348.4500</td><td>KB1234500</td></tr>
<tr><td>LTSC</td><td>2026-10 B</td><td>2026-10-13</td><td>26100.4400</td><td>KB9999999</td></tr>
'@
      Mock Invoke-WebRequest { [pscustomobject]@{ Content = $script:html } }
    }

    It 'detects an old security gap even when a newer cumulative update was just released' {
      $result = Get-OnlineWindowsSecurityBaseline -Now $script:now
      $result.Succeeded | Should -BeTrue
      $result.LatestBuild | Should -Be ([version]'20348.4400')
      $result.Updates.Count | Should -Be 1
      $result.Updates[0].KB | Should -Be 'KB1234400'
      $result.Updates[0].PublishedDate | Should -Be ([datetime]'2026-09-08T00:00:00Z').ToUniversalTime()
      Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter {
        $Uri -eq 'https://learn.microsoft.com/en-us/windows/release-health/windows-server-release-info' -and $UseBasicParsing -and $TimeoutSec -eq 30
      }
    }

    It 'does not require an old KB when the installed build already supersedes it' {
      Mock Get-ItemProperty { [pscustomobject]@{ CurrentBuildNumber = '20348'; UBR = 4450; InstallationType = 'Server' } }
      $result = Get-OnlineWindowsSecurityBaseline -Now $script:now
      $result.Succeeded | Should -BeTrue
      $result.Updates.Count | Should -Be 0
    }

    It 'chooses the correct Microsoft page for server and client builds' -ForEach @(
      @{ Build = '20348'; Type = 'Server'; Page = 'windows-server-release-info' }
      @{ Build = '26200'; Type = 'Client'; Page = 'windows11-release-information' }
      @{ Build = '19045'; Type = 'Client'; Page = 'release-information' }
    ) {
      Mock Get-ItemProperty { [pscustomobject]@{ CurrentBuildNumber = $Build; UBR = 4300; InstallationType = $Type } }
      $script:html = New-TestReleaseHtml "<tr><td>GA</td><td>2026-10 B</td><td>2026-10-13</td><td>$Build.4400</td><td>KB1234400</td></tr>"
      $result = Get-OnlineWindowsSecurityBaseline -Now $script:now
      $result.Succeeded | Should -BeTrue
      $result.Source | Should -Be "https://learn.microsoft.com/en-us/windows/release-health/$Page"
    }

    It 'does not accept unavailable, changed, unsupported, future, or stale online data as clean coverage' -ForEach @(
      @{ Case = 'network' }, @{ Case = 'format' }, @{ Case = 'branch' }, @{ Case = 'future' }, @{ Case = 'revision' }
    ) {
      switch ($Case) {
        'network' { Mock Invoke-WebRequest { throw 'Network unavailable' } }
        'format' { $script:html = '<html>Page changed</html>' }
        'branch' { Mock Get-ItemProperty { [pscustomobject]@{ CurrentBuildNumber = '99999'; UBR = 1; InstallationType = 'Server' } } }
        'future' { $script:html = $script:html.Replace('2026-10-13', '2026-10-16') }
        'revision' { Mock Get-ItemProperty { [pscustomobject]@{ CurrentBuildNumber = '20348'; UBR = $null; InstallationType = 'Server' } } }
      }
      $result = Get-OnlineWindowsSecurityBaseline -Now $script:now
      $result.Succeeded | Should -BeFalse
      $result.Error | Should -Not -BeNullOrEmpty
    }

    It 'preserves evidence of a security gap even when the last public release is old' {
      $result = Get-OnlineWindowsSecurityBaseline -Now $script:now.AddDays(46)
      $result.Succeeded | Should -BeTrue
      $result.Updates.Count | Should -Be 1
      $result.LatestPublishedDate | Should -Be ([datetime]'2026-10-13T00:00:00Z').ToUniversalTime()
    }

    It 'ignores hotpatch tables instead of confusing servicing modes' {
      $hotpatch = '<table><tr><th>Update type</th><th>Type</th><th>Availability date</th><th>Build</th><th>KB article</th></tr><tr><td>2026-10 B</td><td>Hotpatch</td><td>2026-10-13</td><td>20348.9999</td><td>KB9999999</td></tr></table>'
      $releases = @(Get-WindowsSecurityReleaseHistory -Html ($script:html + $hotpatch) -BuildNumber 20348)
      $releases.Count | Should -Be 2
    }
  }

  Context 'Combining independent facts' {
    BeforeEach {
      Mock Get-CachedWindowsSecurityUpdates {
        [pscustomobject]@{ Succeeded = $false; LastSearchSuccessDate = $null; Updates = @(); Error = 'Cache unavailable' }
      }
      Mock Get-OnlineWindowsSecurityBaseline {
        [pscustomobject]@{
          Succeeded = $true; Updates = @(New-TestPendingUpdate -Days 20); Source = 'Microsoft'
          InstalledBuild = '20348.4200'; LatestBuild = '20348.4400'; LatestPublishedDate = $script:now.AddDays(-2); Error = $null
        }
      }
    }

    It 'keeps independent online evidence when local inspection fails' {
      $result = Check-PendingSecurityUpdates -Now $script:now
      $result.Succeeded | Should -BeFalse
      $result.Updates[0].AgeDays | Should -Be 20
      $result.Errors | Should -Match 'Cache unavailable'
      Should -Invoke Get-OnlineWindowsSecurityBaseline -Times 1
    }

    It 'reports a stuck critical update through the real helpers despite a successful small CBS update today' {
      Mock Get-Date { $script:now }
      Mock Get-HotFix { [pscustomobject]@{ InstalledOn = $script:now } }
      Mock Get-CachedWindowsSecurityUpdates {
        [pscustomobject]@{ Succeeded = $true; LastSearchSuccessDate = $script:now.AddHours(-1); Updates = @(New-TestPendingUpdate -Days 21 -Id 'stuck-critical'); Error = $null }
      }
      Mock Get-OnlineWindowsSecurityBaseline {
        [pscustomobject]@{
          Succeeded = $true; Updates = @(); Source = 'Microsoft'; Error = $null
          InstalledBuild = '20348.4400'; LatestBuild = '20348.4400'; LatestPublishedDate = $script:now.AddDays(-2)
        }
      }
      HealthTest-WindowsUpdates
      $script:warnings.Count | Should -Be 1
      $script:warnings[0] | Should -Match '^\[FAILURE\] This computer is missing Windows security or critical updates\.'
      $script:warnings[0] | Should -Match '21 days'
    }

    It 'keeps known cached evidence when the online baseline fails' {
      Mock Get-CachedWindowsSecurityUpdates {
        [pscustomobject]@{ Succeeded = $true; LastSearchSuccessDate = $script:now; Updates = @(New-TestPendingUpdate -Days 18); Error = $null }
      }
      Mock Get-OnlineWindowsSecurityBaseline {
        [pscustomobject]@{ Succeeded = $false; Updates = @(); Source = 'Microsoft'; InstalledBuild = $null; LatestBuild = $null; LatestPublishedDate = $null; Error = 'Network unavailable' }
      }
      $result = Check-PendingSecurityUpdates -Now $script:now
      $result.Succeeded | Should -BeFalse
      $result.Updates[0].AgeDays | Should -Be 18
      $result.Errors | Should -Match 'Network unavailable'
    }

    It 'does not interpret missing or future publication dates as a new update' -ForEach @(
      @{ Date = $null }, @{ Date = [datetime]'2026-10-16T00:00:00Z' }
    ) {
      Mock Get-OnlineWindowsSecurityBaseline {
        $update = New-TestPendingUpdate -Days 0
        $update.PublishedDate = $Date
        $update.AgeDays = $null
        [pscustomobject]@{ Succeeded = $true; Updates = @($update); Source = 'Microsoft'; InstalledBuild = '1'; LatestBuild = '2'; LatestPublishedDate = $script:now.AddDays(-2); Error = $null }
      }
      $result = Check-PendingSecurityUpdates -Now $script:now
      $result.Updates[0].AgeDays | Should -BeNullOrEmpty
      $result.Errors -join ' ' | Should -Match 'invalid publication date'
    }
  }

  Context 'Health test reporting' {
    BeforeEach {
      Mock Get-Date { $script:now }
      $script:pendingFacts = [pscustomobject]@{
        Succeeded = $true; LastSearchSuccessDate = $script:now.AddHours(-1)
        Updates = @(); Errors = @(); InstalledBuild = '20348.4400'; LatestBuild = '20348.4400'
        LatestPublishedDate = $script:now.AddDays(-2); BaselineSource = 'Microsoft'
      }
      $script:ageFacts = [pscustomobject]@{
        Succeeded = $true; AgeDays = 0; LastInstallDate = $script:now; Source = 'CBS'; Error = $null
      }
      Mock Check-PendingSecurityUpdates { $script:pendingFacts }
      Mock Check-UpdateAge { $script:ageFacts }
    }

    It 'applies pending boundaries even when another update succeeded today' -ForEach @(
      @{ Days = 7; Level = 'PASS' }, @{ Days = 8; Level = 'WARNING' }
      @{ Days = 14; Level = 'WARNING' }, @{ Days = 15; Level = 'FAILURE' }
    ) {
      $script:pendingFacts.Updates = @(New-TestPendingUpdate -Days $Days)
      HealthTest-WindowsUpdates
      $script:warnings.Count | Should -Be 1
      $script:warnings[0] | Should -Match "^\[$Level\]"
    }

    It 'applies installation-age boundaries independently of the pending list' -ForEach @(
      @{ Days = 44; Level = 'PASS' }, @{ Days = 45; Level = 'WARNING' }
      @{ Days = 59; Level = 'WARNING' }, @{ Days = 60; Level = 'FAILURE' }
    ) {
      $script:ageFacts.AgeDays = $Days
      HealthTest-WindowsUpdates
      $script:warnings.Count | Should -Be 1
      $script:warnings[0] | Should -Match "^\[$Level\]"
    }

    It 'retains an overdue finding alongside stale-cache and source warnings without passing' {
      $script:pendingFacts.Succeeded = $false
      $script:pendingFacts.LastSearchSuccessDate = $script:now.AddHours(-49)
      $script:pendingFacts.Errors = @('Cached inspection failed')
      $script:pendingFacts.Updates = @(New-TestPendingUpdate -Days 20)
      HealthTest-WindowsUpdates
      ($script:warnings -join "`n") | Should -Match '\[FAILURE\] This computer is missing Windows security or critical updates'
      ($script:warnings -join "`n") | Should -Match 'no recent successful check for updates'
      ($script:warnings -join "`n") | Should -Not -Match '\[PASS\]'
    }

    It 'requires a recent successful scan even when zero updates are returned' -ForEach @(
      @{ Hours = 48; Level = 'PASS' }, @{ Hours = 49; Level = 'WARNING' }
      @{ Hours = -1; Level = 'WARNING' }, @{ Hours = $null; Level = 'WARNING' }
    ) {
      $script:pendingFacts.LastSearchSuccessDate = $null
      if ($null -ne $Hours) { $script:pendingFacts.LastSearchSuccessDate = $script:now.AddHours(-$Hours) }
      HealthTest-WindowsUpdates
      $script:warnings[0] | Should -Match "^\[$Level\]"
    }

    It 'reports unknown installation age without a pass' {
      $script:ageFacts.Succeeded = $false
      $script:ageFacts.AgeDays = $null
      $script:ageFacts.Error = 'No inventory'
      HealthTest-WindowsUpdates
      $script:warnings.Count | Should -Be 1
      $script:warnings[0] | Should -Match '^\[WARNING\].*installation could not be determined'
    }

    It 'warns about stale or missing public baselines without hiding a known security gap' -ForEach @(
      @{ Date = [datetime]'2026-08-11T00:00:00Z' }, @{ Date = $null }
    ) {
      $script:pendingFacts.LatestPublishedDate = $Date
      $script:pendingFacts.Updates = @(New-TestPendingUpdate -Days 40)
      HealthTest-WindowsUpdates
      ($script:warnings -join "`n") | Should -Match 'Current Windows security update information could not be confirmed'
      ($script:warnings -join "`n") | Should -Match '\[FAILURE\] This computer is missing Windows security or critical updates'
      ($script:warnings -join "`n") | Should -Not -Match '\[PASS\]'
    }

    It 'uses caller-specified thresholds and rejects reversed limits' {
      $script:pendingFacts.Updates = @(New-TestPendingUpdate -Days 10)
      HealthTest-WindowsUpdates -PendingWarnDays 5 -PendingFailDays 10
      $script:warnings[0] | Should -Match '^\[FAILURE\]'
      { HealthTest-WindowsUpdates -PendingWarnDays 15 -PendingFailDays 8 } | Should -Throw
      { HealthTest-WindowsUpdates -UpdateAgeWarnDays 60 -UpdateAgeFailDays 45 } | Should -Throw
    }

    It 'reports the same nine-day KB from both sources as one warning with both details' {
      $cached = New-TestPendingUpdate -Days 9
      $monthly = New-TestPendingUpdate -Days 9 -Monthly
      $cached.KB = 'KB5126655'
      $monthly.KB = 'KB5126655'
      $script:pendingFacts.Updates = @($cached, $monthly)
      HealthTest-WindowsUpdates

      $script:warnings | Should -HaveCount 1
      $script:warnings[0] | Should -Match '^\[WARNING\] This computer is missing Windows security or critical updates\.'
      $script:warnings[0] | Should -Match 'An uninstalled security or critical update was last published 9 days ago'
      $script:warnings[0] | Should -Match 'Missing monthly security updates since 9 days ago'
      $script:warnings[0] | Should -Match 'Update to check: KB5126655'
      $script:warnings[0] | Should -Match 'Latest monthly security update to install: KB5126655'
    }

    It 'uses the highest pending severity regardless of order and retains newer updates in details' -ForEach @(
      @{ Reverse = $false }, @{ Reverse = $true }
    ) {
      $monthly = New-TestPendingUpdate -Days 40 -Monthly
      $cached = New-TestPendingUpdate -Days 2
      $other = New-TestPendingUpdate -Days 9 -Id 'other-component'
      $other.KB = 'KB7654321'
      $script:pendingFacts.Updates = @($monthly, $other, $cached)
      if ($Reverse) { [array]::Reverse($script:pendingFacts.Updates) }
      HealthTest-WindowsUpdates

      $script:warnings | Should -HaveCount 1
      $script:warnings[0] | Should -Match '^\[FAILURE\] This computer is missing Windows security or critical updates\.'
      $script:warnings[0] | Should -Match 'Missing monthly security updates since 40 days ago'
      $script:warnings[0] | Should -Match 'last published 2 days ago'
      $script:warnings[0] | Should -Match 'last published 9 days ago'
      $script:warnings[0] | Should -Match 'Update to check: KB7654321'
    }

    It 'passes when all known pending updates are below the warning threshold' {
      $script:pendingFacts.Updates = @((New-TestPendingUpdate -Days 2), (New-TestPendingUpdate -Days 7 -Monthly))
      HealthTest-WindowsUpdates
      $script:warnings | Should -HaveCount 1
      $script:warnings[0] | Should -Match '^\[PASS\]'
    }

    It 'retains an undated update in details without hiding a known overdue update or its collection error' {
      $undated = New-TestPendingUpdate -Days 0 -Id 'undated'
      $undated.AgeDays = $null
      $undated.PublishedDate = $null
      $undated.KB = ''
      $undated.Title = 'Undated component update'
      $script:pendingFacts.Updates = @((New-TestPendingUpdate -Days 20), $undated)
      $script:pendingFacts.Succeeded = $false
      $script:pendingFacts.Errors = @('Unknown publication date')
      HealthTest-WindowsUpdates

      $script:warnings | Should -HaveCount 2
      $script:warnings[0] | Should -Match 'Some Windows update checks could not be completed'
      $script:warnings[1] | Should -Match '^\[FAILURE\] This computer is missing Windows security or critical updates\.'
      $script:warnings[1] | Should -Match 'last published 20 days ago'
      $script:warnings[1] | Should -Match 'The age of this missing update could not be determined'
      $script:warnings[1] | Should -Match 'Update to check: Undated component update'
      ($script:warnings -join "`n") | Should -Not -Match '\[PASS\]'
    }

    It 'explains an old monthly security gap separately from the latest recommended KB' {
      $update = New-TestPendingUpdate -Days 184 -Monthly
      $update.KB = 'KB5126655'
      $update.Id = 'OS baseline 20348.5761'
      $update.Source = 'Microsoft release history; gap since KB5082142; target KB5126655'
      $script:pendingFacts.Updates = @($update)
      HealthTest-WindowsUpdates

      $script:warnings | Should -HaveCount 1
      $script:warnings[0] | Should -Be (@(
        '[FAILURE] This computer is missing Windows security or critical updates.'
        'Check Windows Update for failed or blocked installations.'
        ''
        'Missing monthly security updates since 184 days ago (2026-04-14).'
        'Latest monthly security update to install: KB5126655.'
      ) -join "`n")
      ($script:debugMessages -join "`n") | Should -Match 'OS baseline 20348.5761'
      ($script:debugMessages -join "`n") | Should -Match 'gap since KB5082142'
      $script:warnings[0] | Should -Not -Match 'OS baseline|CBS|Publication/gap date|Source:|20348'
    }

    It 'reports missing installation activity in plain language' {
      $script:ageFacts.AgeDays = 202
      $script:ageFacts.LastInstallDate = $script:now.AddDays(-202)
      HealthTest-WindowsUpdates
      $script:warnings[0] | Should -Be (@(
        '[FAILURE] No recent Windows system update installation was found.'
        'Last recorded installation: 202 days ago (2026-03-27).'
        'Check why Windows system updates are not being installed.'
      ) -join "`n")
      ($script:debugMessages -join "`n") | Should -Match 'source=CBS'
      $script:warnings[0] | Should -Not -Match 'CBS|Get-HotFix|Source:'
    }

    It 'combines the monthly security gap and installation failure into one actionable finding' {
      $update = New-TestPendingUpdate -Days 184 -Monthly
      $update.KB = 'KB5126655'
      $script:pendingFacts.Updates = @($update)
      $script:ageFacts.AgeDays = 202
      HealthTest-WindowsUpdates
      $script:warnings | Should -HaveCount 1
      $script:warnings[0] | Should -Be (@(
        '[FAILURE] This computer is missing Windows security or critical updates.'
        'Check Windows Update for failed or blocked installations.'
        ''
        'Missing monthly security updates since 184 days ago (2026-04-14).'
        'Latest monthly security update to install: KB5126655.'
        ''
        'The last recorded Windows system update installation was 202 days ago.'
      ) -join "`n")
    }

    It 'combines a cached update failure without claiming it is a monthly OS security gap' {
      $script:pendingFacts.Updates = @(New-TestPendingUpdate -Days 20)
      $script:ageFacts.AgeDays = 70
      HealthTest-WindowsUpdates
      $script:warnings | Should -HaveCount 1
      $script:warnings[0] | Should -Match '^\[FAILURE\] This computer is missing Windows security or critical updates\.'
      $script:warnings[0] | Should -Match 'An uninstalled security or critical update was last published 20 days ago'
      $script:warnings[0] | Should -Match 'last recorded Windows system update installation was 70 days ago'
      $script:warnings[0] | Should -Not -Match 'monthly|Security fixes released'
      $script:warnings[0] | Should -Match 'Update to check: KB1234567'
    }

    It 'combines installation failure with all pending update details including overlapping sources' {
      $monthly = New-TestPendingUpdate -Days 30 -Monthly
      $sameKB = New-TestPendingUpdate -Days 20 -Id 'cached-monthly'
      $sameKB.KB = '1234567'
      $other = New-TestPendingUpdate -Days 9 -Id 'other-component'
      $other.KB = 'KB7654321'
      $script:pendingFacts.Updates = @($sameKB, $other, $monthly)
      $script:ageFacts.AgeDays = 70
      HealthTest-WindowsUpdates
      $script:warnings | Should -HaveCount 1
      @($script:warnings | Where-Object { $_ -match '^\[FAILURE\]' }) | Should -HaveCount 1
      $script:warnings[0] | Should -Match 'KB7654321'
      $script:warnings[0] | Should -Match 'last published 20 days ago'
      $script:warnings[0] | Should -Match 'Missing monthly security updates since 30 days ago'
      $script:warnings[0] | Should -Match 'last recorded Windows system update installation was 70 days ago'
      @($script:debugMessages | Where-Object { $_ -like 'Pending Windows update:*' }) | Should -HaveCount 3
    }

    It 'keeps warning-only evidence separate from an installation failure' {
      $script:pendingFacts.Updates = @(New-TestPendingUpdate -Days 8 -Monthly)
      $script:ageFacts.AgeDays = 60
      HealthTest-WindowsUpdates
      $script:warnings | Should -HaveCount 2
      ($script:warnings -join "`n") | Should -Not -Match 'seriously overdue'
      @($script:warnings | Where-Object { $_ -match '^\[WARNING\]' }) | Should -HaveCount 1
      @($script:warnings | Where-Object { $_ -match '^\[FAILURE\]' }) | Should -HaveCount 1
    }

    It 'keeps collection errors and build diagnostics out of operator messages' {
      $script:pendingFacts.Errors = @('COM HRESULT 0x80070005 from source X', 'Parser failed for build 20348')
      $script:pendingFacts.Succeeded = $false
      HealthTest-WindowsUpdates
      $script:warnings | Should -HaveCount 1
      $script:warnings[0] | Should -Match 'Some Windows update checks could not be completed'
      $script:warnings[0] | Should -Not -Match 'HRESULT|\bCOM\b|Parser|20348|CBS'
      ($script:debugMessages -join "`n") | Should -Match 'HRESULT 0x80070005'
      ($script:debugMessages -join "`n") | Should -Match 'installed build=20348.4400'
    }
  }
}
