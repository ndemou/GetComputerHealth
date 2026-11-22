<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:44.816Z","completions":[]} -->

GitHub source: [#103](https://github.com/ndemou/GetComputerHealth/issues/103) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/103#issuecomment-7061936550)

Confirmed by static review of `health-tests/HealthTest-DfsNamespaceEnumerate.ps1`. Both DFSN queries use `SilentlyContinue`. A root-query error reaches the no-roots PASS, and a folder-query error is counted as zero before the final PASS.

Proposed fix:

1. Read roots with `-ErrorAction Stop` in a narrow try/catch. Report a failed query as WARNING with its error details and return. Preserve the no-roots result only for successful empty discovery.
2. Query each root's folders independently with terminating errors. On failure, record the root path, mark the check incomplete, and continue to the remaining roots.
3. Use the documented namespace wildcard form, such as `\\Contoso\AccountingResources\*`, to enumerate child folders. The current call passes only the root path. Verify the exact argument in tests. See [Get-DfsnFolder, example 2](https://learn.microsoft.com/en-us/powershell/module/dfsn/get-dfsnfolder?view=windowsserver2025-ps#example-2-get-settings-for-all-folders-in-a-dfs-namespace).
4. Count folders only from successful queries. Emit the overall enumeration PASS only when every requested query completed. Summarize failed roots without presenting their counts as zero.

Add mocked Pester cases for no roots, a root with no folders, successful enumeration of multiple roots, root-discovery failure, one failed root followed by a successful root, and all folder queries failing. Include both terminating and nonterminating cmdlet errors.

Regression risk is low. Queries remain read-only; the important compatibility check is the folder-query argument and successful empty-result behavior.

Plan only. No code changed or tests run. Validate with the unit, smoke, and integration runners under Windows PowerShell 5.1.
