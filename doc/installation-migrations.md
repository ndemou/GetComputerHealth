# On-Disk Format Migration Design Draft

**CAUTION**: This is a WORK IN PROGRESS document.

*(Information for developers only)*

## What is an On-Disk Format Migration

Sometimes a new version of the program needs to work with:

  * different file or directory names
  * different directory structure
  * different format for some file(s)
  * or a mixture of the above

In that case, we say that the *On-Disk Format* changes, and we invoke an *On-Disk Format Migration* function to perform the change in a controlled and safe manner.

We keep track of the current "version" of the On-Disk Format by recording it in `data\disk-format.state`.


## Versioning Rules

`data\disk-format.state` contains something two numbers:
```
@{
  LastVersionThatChangedDiskFormat = 3,
  LastVersionThatWorksWithThisDiskFormat = 4,
}
```


The basic rules are these:
  * `LastVersionThatWorksWithThisDiskFormat` is always aligned to the latest code's major version number.
  * When the On-Disk Format needs to change, we increase all these three: `LastVersionThatChangedDiskFormat`, `LastVersionThatWorksWithThisDiskFormat`, and the code's major version number.
  * When the code's major version number needs to increase, but no change is required in the On-Disk Format, we only increment `LastVersionThatWorksWithThisDiskFormat`.

By the way, the code version is declared in `Get-ComputerHealth.ps1` via its `VERSION="..."` line.

## Main Design

The updater is responsible for orchestrating On-Disk Format Migrations.

The updater must:

1. acquire a mutex so that two updates (and migrations) can never overlap
2. detect the source On-Disk Format version from `data\disk-format.state` -- if no such file exists it assumes LastVersionThatChangedDiskFormat = 4 and LastVersionThatWorksWithThisDiskFormat = 4.
3. determine the target On-Disk Format version from the Code Version being installed
4. allow code downgrades that do not require an On-Disk Format downgrade, reject these that do
5. compute the ordered list of migrations that must run and execute them one by one. For each one:
   1. load the migration manifest
   2. create backups for every touched top folder
   3. run the selected migrations
   4. run post-migration verification
   5. persist the final On-Disk Format version
6. change CWD to the `InstallRoot` returned by the last migration
7. execut the rest of the update code
8. release the mutex

Failures must leave a logged, resumable state.

**IMPORTANT NOTE**: every On-Disk Format change is accompanied with a bumb in the major Code Version number but not vice versa (it's expected that some new Code Version with bumped major number does not need an On-Disk Format change). 

## Migration Manifest

Migrations are described by a manifest-like list with metadata. The manifest is included in the help-block of the migration script under the "MANIFEST" heading. Each migration entry must define at least:

```
<#

MANIFEST
  target format version
  implementation entrypoint
  preconditions
  which top folders are touched
  the updater path to rerun after the migration
#>
```

Touched top folders means top-level installation folders such as:

  * `bin`
  * `config`
  * `data`
  * `log`
  * `temp`

If a migration modifies a folder itself or any file under it, that folder is considered touched.

The manifest must be ordered and explicit enough that the updater can determine exactly which migrations must run for a given source and target On-Disk Format version.

Missing versions are normal. They mean that no On-Disk Format Migration is needed for that version transition.

Migrations are not required to be adjacent. Skipping versions is normal because On-Disk Format is tied to the code's major version number, and not every major version requires a migration.

One migration entry must look like this:

`Migrate-Disk-Format-to-version-4.ps1`:

```powershell
<#
.DESCRIPTION

Blah, blah,...

.MANIFEST
@{
  # Note that ".\" in preconditions points to the CURRENT install path
  Preconditions = @(
    @{
      Type = 'PathExists'
      Path = '.\data\some.file'
    },
    @{
      Type = 'FileContainsRegex'
      Path = '.\config\foo.conf'
      Pattern = '^bar'
    }
  )
  TouchedTopFolders = @('bin', 'config')
  # Note that ".\" in RerunUpdaterPath points to the NEW install path
  RerunUpdaterPath = '.\bin\Update-GetHealthCode.ps1'
}
```

Notes:

  * `TargetVersion` also serves as the migration identifier
  * there is no `SourceVersion`; a migration applies from any source version less than `TargetVersion`, subject to its preconditions
  * there is no `RequiresRerun`; the updater is always reinvoked after any On-Disk Format migration
  * `RerunUpdaterPath` tells the invoker which updater path to execute after the migration finishes

## Migration Selection Rules

If the source On-Disk Format version already matches the target On-Disk Format version, no On-Disk Format Migration is needed.

If the target On-Disk Format version is lower than the source On-Disk Format version, that is a format downgrade request and must throw.

If the Code Version is lower than the currently installed Code Version, but the required On-Disk Format version is unchanged, that code downgrade is allowed.

## Safety Requirements

Migration design should optimize for:

  * safe retry
  * idempotency where possible
  * a clear failure state
  * the ability to resume safely or abort safely

Migration design should not assume full filesystem atomicity.

The goal is not "revert everything at all costs." The goal is to make progress in small safe steps and leave the installation in a known, repairable, and well-logged state if something fails.

## Backup Rules

Before any selected migration runs, the migration invoker must create backups of every touched top folder.

Example:

  * if a migration touches `config\Send-Message.conf`, the invoker backs up `config`
  * if a migration touches `bin\Get-ComputerHealth.ps1` and `data\something.psd1`, the invoker backs up both `bin` and `data`

Backups are the responsibility of the migration invoker, not the individual migration implementation.

Backups must be logged.

Backups older than 7 days must be deleted.

## Mutex Rules

The updater must acquire the named OS mutex:

`Global\GetComputerHealth-DiskFormatMigration`

before planning or running migrations.

The mutex must protect the entire migration orchestration flow, including:

  * migration selection
  * backup creation
  * migration execution
  * post-migration verification
  * persistence of the final On-Disk Format version

No two On-Disk Format Migrations may overlap.

The updater must wait up to 5 seconds to acquire the mutex.

If acquiring `Global\GetComputerHealth-DiskFormatMigration` fails because of privilege or session limitations, the updater must throw. It must not silently fall back to a different mutex scope.

## Post-Migration Verification

Migrations must have a post-migration verification phase.

Verification runs after the selected migrations finish and before the final On-Disk Format version is persisted.

Verification must confirm at least:

  * no exception was thrown during migration execution
  * the version declared in `Get-ComputerHealth.ps1` matches the persisted On-Disk Format version file

Each migration function must also include migration-specific post-migration verification and must throw on failure.

If verification fails, the migration must be treated as failed and the failure must be logged clearly.

## Logging Requirements

The migration invoker must log at least:

1. detected source format
2. target format
3. backups created
4. final persisted format

Migration implementations must log at least:

1. each migration step
2. warnings
3. rerun updater path

Together, the full migration flow must log at least:

1. detected source format
2. target format
3. backups created
4. each migration step
5. warnings
6. rerun updater path
7. final persisted format

## Rules for Migration Implementations

Each migration implementation should:

  * validate aggressively before mutating
  * apply small ordered steps
  * on failure, either resume safely or leave the installation in a known repairable state
  * only roll back changes that are cheap and unambiguous to undo

Migration implementations should avoid:

  * broad best-effort mutations with unclear step boundaries
  * hidden side effects outside the declared touched top folders
  * complex rollback logic that is harder to trust than forward recovery

## Suggested Migration Entry Shape

Each manifest entry should conceptually contain fields like:

  * `TargetVersion`
  * `Entrypoint`
  * `Preconditions`
  * `TouchedTopFolders`
  * `RerunUpdaterPath`
  * `Description`

The manifest is a PowerShell data file. The design uses PowerShell data files everywhere rather than JSON.

The exact manifest file path is still to be decided, but the design requires explicit metadata of this kind.

## Example

Assume the installed On-Disk Format is `3` and the updater is installing Code Version `5.2.0`, whose On-Disk Format version is also `5`.

Assume the manifest declares:

  * a migration targeting `4` touching `config` and `bin`
  * a migration targeting `5` touching `data`

Then the updater must:

1. acquire the mutex
2. read `data\disk-format.state` and detect source format `3`
3. determine target format `5`
4. back up `config`, `bin`, and `data`
5. run all selected migrations in ascending `TargetVersion` order
7. run post-migration verification
8. persist On-Disk Format version `5`
9. release the mutex

If a migration fails, the result must be a logged and repairable failure state. The updater must not silently persist format `5`.

## Non-Goals

For simplicity, this design does not allow format downgrades.

## Open Questions

The following implementation details are still open and should be decided when this design is implemented:

  * the exact manifest file path
  * whether preconditions remain strings or are represented differently within the PowerShell data file
  * where backups are stored under the installation root
  * where migration logs are stored and how they are rotated
