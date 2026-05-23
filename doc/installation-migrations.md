# How to Perform Migrations of the On-Disk Installation

*(Information for developers only)*

## Introduction (what is an Installation Migration)

Sometimes, a new version of the program needs to work with:

* different file or directory names,
* a different directory structure,
* a different format for existing files,
* or a mixture of the above.

In that case, we say that the *"version"* of the *On-Disk Installation* must change.
This document describes how we perform this change, which is called an "Installation Migration."

## The basics

We must increment the major version every time the code needs to work with a Migrated Installation.
As a result, if an installation on disk is working for versions 3.x.y of the code, we say that
the disk installation is at version 3.

If a new version of the code needs to migrate the installation,
we must bump up the major version to 4.q.r and create an installation migration function that
will migrate the installation from v3 to v4. Its name must be `Invoke-MigrationToV4` and it must be stored in `Invoke-InstallationMigration.ps1`.

The updater is responsible for executing `Invoke-InstallationMigration` like this:

```
Invoke-InstallationMigration.ps1 -TargetVersion "4.0.0"
```
and `Invoke-InstallationMigration` handles everything else

## More details about `Invoke-InstallationMigration.ps1`

The main code of this script reads
the major part of the current version (the *On-Disk Installation Version*)
and the major part of the `$TargetVersion`.
Then, if the major part of the current version is different from that of the target version,
it invokes in numerical order of `y` all functions named like `Invoke-MigrationToVy` where `y > current_major_version` and `y <= target_major_version` (if any).

If a user attempts to downgrade the installation (e.g., from v5 to v4) `Invoke-InstallationMigration.ps1` must throw an error.

Exceptions in Installation Migration Functions should buble up via `Invoke-InstallationMigration.ps1` all the way to the updater which must abort the update.

`Invoke-InstallationMigration.ps1` still works if called with `-TargetVersion "4.0"` or `-TargetVersion "4"` or `-TargetVersion 4`.

### Example of an execution of `Invoke-InstallationMigration.ps1`

Consider that we have these Installation Migration Functions:

```
Invoke-MigrationToV3
Invoke-MigrationToV5
Invoke-MigrationToV7
Invoke-MigrationToV9

```
> Note: The missing versions are normal. They indicate that some major release didn't require any change of the On-Disk Installation and so no migration is needed.

If an installation on disk is at v3.x.y and the updater is installing v8.q.r, then `target_major_version=8`, `current_major_version=3`, and these functions need to be executed in this order:

  1. `Invoke-MigrationToV5`  (5 > 3 and <= 8)
  2. `Invoke-MigrationToV7`  (7 > 3 and <= 8)

## Guidelines for Installation Migration Functions

These functions must be named like `Invoke-MigrationToVx` where `x` is the target major version.

They must be stored in `Invoke-InstallationMigration.ps1`.

They **must be idempotent and atomic**. (To accomplish atomicity it's best to keep their core functionality as simple as possible and they must track all changes made in detail so that reverting them is possible.)

Thet must  handle all exceptions. At the very least if an exception that can't be ciscumvented/worked-around occurs they should revert any changes they've already done (atomicity) and then throw the original exception. 
