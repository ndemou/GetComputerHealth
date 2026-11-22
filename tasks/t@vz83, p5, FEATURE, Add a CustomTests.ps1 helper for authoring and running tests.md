<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:37:07.339Z","completions":[]} -->

`CustomTests.ps1 -New "scriptName"` should: a) create the necessary folders if needed, b) create a sample script named `scriptName.ps1`, and c) output the full path to the script. The sample code should check whether disk C: has at least 10 GB free. It must follow the documentation recommendations and include enough comments to help a first-time custom health test author modify it for their needs. It should include a link to the relevant documentation at the top.

`CustomTests.ps1 -List` should return a list of all scripts with custom health tests (file objects).

`CustomTests.ps1 -Invoke ScriptFileName.ps1` should wrap the [existing single-script invocation](../doc/user/custom-tests.md) with `-OutputConsoleMessages -Hide "" -OnlyTheseTests ScriptFileName.ps1`.

Update our documentation with the above info.
