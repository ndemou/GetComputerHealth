# How to deal with Migrations of the Installation itself

(Information for developers only)

Often a new version of Get-ComputerHealth is just different code, 
but sometimes, a new version may need to work with 
a different directory structure, 
different file names, 
different format of existing files,
or even all of them together.
In such cases the updater must perform a migration of the existing dirs & files 
from the old "installation version" to the new. 
This file describes the way we deal with these migrations.

# Terminology and Installtion Migrations 101

We call these migrations "Installation Migrations". 

We always increment the major version every time the code needs to work with a Migrated Installation.
As a result if an installation on disk is working for versions 3.x.y of code we say that 
the disk installation is at version 3.

If a new version of the code needs to migrate the installation 
we must bump up the major version to 4.q.r, and create an installaiton migration function that
will migrate the installation from v3 to v4.

All installation migration functions must be stored in `Invoke-InstallationMigration.ps1` 
and they must be named like this `Invoke-MigrationFromV3ToV4`.
These functions **must be idempotent**.


`Invoke-InstallationMigration.ps1` is executed by the updater like this:
```
Invoke-InstallationMigration.ps1 -TargetVersion "4.0.0"
# or 
Invoke-InstallationMigration.ps1 -TargetVersion "4.0"
# or even just
Invoke-InstallationMigration.ps1 -TargetVersion "4"
```

The main code of the script reads the major part of the current version of the installation on the disk
and the major part of the the `$TargetVersion`
and if the major part of the current version is different than that of the target version 
and there are functions named `Invoke-MigrationFromV<current major version>ToVx` 
it invokes it and if `x` is still less than the target major version it looks again 
for a function named `Invoke-MigrationFromVxToVy`, on and on until there's no other function to invoke.


