# Windows Update monitoring

`WindowsUpdates` replaces the former `UpdateAge` health test. Update any
`OnlyTheseTests`, exclusions, test parameters, required findings, or suppression
configuration that referred to `UpdateAge`; previous finding signatures do not
automatically transfer to the new test.

The test combines two data-returning helpers, `Check-PendingSecurityUpdates` and
`Check-UpdateAge`, defined in `HealthTest-WindowsUpdates.ps1`. The health test owns
the reporting thresholds:

| Parameter | Default | Meaning |
|---|---:|---|
| `PendingWarnDays` | 8 | Warn when a pending security/critical update reaches this age |
| `PendingFailDays` | 15 | Fail when a pending security/critical update reaches this age |
| `UpdateAgeWarnDays` | 45 | Warn after this many days without a successful CBS update installation |
| `UpdateAgeFailDays` | 60 | Fail after this many days without a successful CBS update installation |
| `MaxScanAgeHours` | 48 | Warn when the last successful automatic update scan is older or unknown |
| `MaxBaselineAgeDays` | 45 | Warn when the latest public monthly OS security baseline is older or unknown |

The cached check queries uninstalled, non-hidden software updates in Microsoft's
Security Updates and Critical Updates classifications. It preserves the configured
update source, excludes superseded entries, uses `Online = $false`, and disables
automatic WUA upgrades. It only activates WUA objects if `wuauserv` is already
running. It never starts services, initiates an online Windows Update scan,
registers scan services, downloads patches, installs updates, or changes policies.
Classification GUIDs avoid depending on localized update titles. Defender
definition updates do not reset the age of another pending update.

An independent HTTPS GET reads Microsoft's English Windows Server, Windows 10,
or Windows 11 release-history tables and compares the installed build/revision
with monthly B security releases in the same build branch. Optional previews are
not required. A newer installed cumulative build covers older KBs. When several
monthly releases have been missed, the age starts at the oldest missing baseline,
while the recommended target is the newest one. A new cumulative release therefore
does not restart the grace period.

The online baseline covers monthly OS cumulative security updates, not a complete
inventory of .NET, Office, Defender, or other products. OOB releases are not assumed
to be security releases solely from their label; cached security/critical
classifications cover applicable OOB updates. Hotpatch tables are excluded from
the public-table comparison; specialized servicing modes and older branches may
need separate validation. Missing build revisions, unsupported branches, network
errors, changed page formats, incomplete searches, and stale or unknown scan dates
produce warnings, never a clean pass. A failed source does not discard findings
from another source. Cached dates use WUA's last successful *automatic* scan;
manual or management-tool scans may not update that timestamp.

Cached pending age is measured from the last publication on the configured update
server, not first detection or the first failed installation on this machine.
WSUS approvals, deferrals, and republishing can affect that approximation. The
supplementary installation-age helper reads installed CBS updates with
`Get-HotFix`; it is an activity signal, not proof of OS patch completeness.
The wrapper emits a pass only when both sources are usable, freshness checks pass,
and no threshold is exceeded. `PendingReboot` remains a separate test.

Missing security or critical updates produce one finding when any update reaches
the pending warning or failure threshold. Its severity is the highest threshold
reached across the known publication/gap ages. The first line is the finding's
message; the remaining lines become its details. Those details include each
source's pending updates, including newer updates below the warning threshold.
The same KB may appear more than once in the details when both sources identify it.
The age of a monthly security gap remains separate from the latest recommended KB.

If pending updates and installation activity both reach their failure thresholds,
the installation-age evidence is included in the same finding's details. Otherwise,
installation-age findings remain separate. Collection errors and freshness checks
also retain their own findings. Build numbers, collection methods, source details,
and raw collection errors are available through PowerShell debug output.

## Why both pending-update checks are kept

The cached Windows Update check and the online OS baseline overlap on monthly OS
updates, but each provides coverage that the other cannot replace:

- The cached check can find security or critical updates outside the monthly OS
  baseline, including .NET and OOB updates, when the configured update source
  supplies them with those classifications. Removing this check would lose that
  coverage. It can also report known pending updates when Microsoft's
  release-history website is unreachable.
- The online baseline compares the installed OS build with Microsoft's published
  monthly releases independently of the Windows Update cache and configured
  update source. Removing it would lose evidence of monthly OS security gaps when
  the cache is unavailable, incomplete, or lacks a relevant monthly release.
- The online baseline preserves the age of the oldest missing monthly release.
  For example, a machine may be months behind while its cache returns only a
  cumulative replacement published two days ago. The cached pending-update check
  may then stay below the warning threshold, while the online baseline still
  reports the older security gap. Removing the baseline would lose this protection
  against restarting the grace period when an update is superseded.

The installation-age check cannot replace either source: a recent system update
installation does not establish that all applicable security fixes are installed.
Both sources can identify the same KB, providing overlapping evidence of one
missing update. That overlap is expected and does not make either check redundant.
