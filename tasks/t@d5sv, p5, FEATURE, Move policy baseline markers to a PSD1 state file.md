<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:37:07.769Z","completions":[]} -->

Migrate `POLICY_TEST_WAS_RUN` lines from `config\Get-ComputerHealth.sigs-to-suppress.txt` if the destination file does not exist. Preserve the existing lines. Record the test name and baseline version, treating legacy unversioned markers as version 1. Record the timestamp and user for new entries. The original proposal uses the migration timestamp and user for legacy entries.
