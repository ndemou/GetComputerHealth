# On-Disk Format Migration Design Draft

**CAUTION**: This is a WORK IN PROGRESS document.

*(Information for developers only)*

## What is an On-Disk Format Migration

Sometimes a new version, besides the expected changes of code in `.\bin`, needs to work with:

  * different file or directory names or different directory structure (e.g. moving a subfolder from one place to another)
  * different format for some file(s)
  * or a mixture of the above

In that case, we say that the *On-Disk Format* changes, and we invoke an *On-Disk Format Migration* script to perform the change in a controlled and safe manner.

We keep track of the current "version" of the On-Disk Format by recording it in `data\disk-format.state`.


## Versioning Rules

`data\disk-format.state` contains these two numbers (and the comments):
```
@{
  # This is the major version of the last code release that changed the On-Disk Format
  CurrentDiskFormat = 3
  # This is the major version of the latest code that works fine with the above On-Disk Format
  LatestCompatibleCodeVersion = 4
}
```

The basic rules are these:
  * When the On-Disk Format needs to change, we also increase the code's major version number and ofcourse both of the above (`CurrentDiskFormat`, `LatestCompatibleCodeVersion`).
  * When the code's major version number needs to increase, but no change is required in the On-Disk Format, we only increment `LatestCompatibleCodeVersion`.

As a result `LatestCompatibleCodeVersion` is expected to be always aligned with the latest installed code release.

> NOTE: The code version is declared inside `Get-ComputerHealth.ps1` (in a line like `$VERSION="1.2.3"`).

## Migration Scripts & Migration Manifest

Migration scripts are kept under `.\bin\migrations` and named like `Migrate-Disk-Format-to-version-V.ps1` where `V` is the On-Disk Format version that will result if this migration script runs succesfully. 

Migration scripts are invoked by the updater.

Migration scripts begin with this mandatory help-block:
```powershell
<#
.DESCRIPTION

A short description of what the script does (the changes it performs on the On-Disk Format)

.MANIFEST
ModifiedTopFolders = temp, config 
# This is a comma separated list of top folders (spaces are ignored)
# 'bin' is always modified, so no need to include it
NewTopFolders = foo

```
Modified top folders means top-level installation folders such as `config`, `log`, etc. If a migration MAY modifie a folder itself or any file under it, that folder is considered modified.

Migration scripts must:
  1. Optionally run one or more precondition tests. 
    1.1. If the tests reveals that no action is needed the script must return with exit code 1 and emit the message "No migration is needed" as the last line in stdout.
    1.2. If the tests reveals any problem the script must emit a message explaining the situation in stderr, emit "Migration failed" as the last stderr and return with exit code 2.
    1.3. If the tests pass (or not tests are defined) code execution proceeds
  2. Perform the migration
  3. Optionally perform a post-migration verification (throw on failure).
  4. Print this as the last line in stdout "PATH_TO_UPDATER=C:\some\path\to\Update-GetHealthCode.ps1" and return with exit code 0.

The migration script is expected to generate verbose output on the actions it performs (this output is captured by a Start-Transcript controlled by the updaterd)

## Main Design

The updater is responsible for invoking these scripts that perform On-Disk Format Migrations and making sure their output finds its way in the log file via Start-Transcript.

The updater must:

1. acquire a mutex so that two updates (and migrations) can never overlap
2. detect the source On-Disk Format version from `data\disk-format.state` -- if no such file exists it assumes CurrentDiskFormat = 4 and LatestCompatibleCodeVersion = 4.
3. determine the target On-Disk Format version from the version of the zip file (`$versionToInstall`)
4. Decide what to do:
  4.1. If the source On-Disk Format version already matches the target On-Disk Format version, no On-Disk Format Migration is needed.
  4.2. If the target On-Disk Format version is lower than the source On-Disk Format version, that is a format downgrade request and must throw.
  4.3. If the Code Version is lower than the currently installed Code Version, but the required On-Disk Format version is unchanged, that code downgrade is allowed. No On-Disk Format Migration is needed.
  4.4. If the Code Version(CV) is higher than the Current On-Disk Format version (FV) then all migration scripts with version(V) such that `FV < V <= CV` must run in ascending order. For each one:
    4.4.1. load the migration manifest from the script
    4.4.2. create backups for every modified top folder
    4.4.3. run the selected migrations
    4.4.4. If migration script throws or returns an exit code that reveals a failure:
       4.4.4.1. revert all modified top folders from backups 
       4.4.4.2. delete any new top folders introduced from the migration
       4.4.4.3. buble up the exception
    4.4.5. If all seem to have gonne well 
       4.4.5.1. persist the final On-Disk Format version in `data\disk-format.state`.
       4.4.5.2. release the mutex
       4.4.5.3. execute the updater that is returned by the last migration script

Migrations are not required to be adjacent (e.g. needing to run migrations 4,6,10 and 11). Skipping versions is normal because On-Disk Format is tied to the code's major version number, and not every major code version requires a migration.

Backups must be logged. Backups older than 7 days must be deleted. Backups are created in the root installation folder and are named like `config.3-to-4.bak` (a backup of top folder config for a migration from version 3 to version 4). If an existing backup with the same name (i.e. same version transition) is found it is deleted.

The updater must acquire the named OS mutex `Global\GetComputerHealth-DiskFormatMigration` with a timeout of 5 sec. 

The updater must log(output) at least:
    1. detected source format
    2. target format
    3. backups created
    4. final persisted format

## Safety Requirements

Migration design should optimize for pragmatic robustness:

  * safe retry
  * idempotency where possible
  * a clear failure state
  * the ability to resume safely or abort safely
  * human readable logging

The goal is not "revert everything at all costs." The goal is to make progress in small safe steps and leave the installation in a known, repairable, and well-logged state if something fails.

## Rules for Migration Implementations

Each migration implementation should:

  * validate aggressively before mutating
  * apply small ordered steps
  * on failure, either resume safely or leave the installation in a known repairable state
  * only roll back changes that are cheap and unambiguous to undo

Migration implementations should avoid:

  * broad best-effort mutations with unclear step boundaries
  * hidden side effects outside the declared modified top folders
  * complex rollback logic that is harder to trust than forward recovery

## Non-Goals

For simplicity, this design does not allow format downgrades.
