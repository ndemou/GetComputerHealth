<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:44.563Z","completions":[]} -->

GitHub source: [#100](https://github.com/ndemou/GetComputerHealth/issues/100) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/100#issuecomment-7062064915)

Confirmed: HealthTest-DuplicateSpn declares Forest scope but queries Get-ADObject without selecting other domains. There is a second related trap: owners are deduplicated by sAMAccountName when available, so two different domains containing the same account name could still collapse into one owner after a naive forest-wide fix.

Proposed fix:

1. Enumerate forest domains and query each domain explicitly with terminating errors. Continue after one domain fails, but mark the forest result incomplete.
2. Compare SPNs case-insensitively and identify owners by object GUID or distinguished name, not an unqualified account name. Include the domain in readable details.
3. Report duplicates found in the successfully read data even when another domain is unavailable.
4. Emit the no-duplicates PASS only after every intended domain query succeeds. Empty discovery must not hide an unreadable domain.
5. Update Uses, scope explanation, and impact metadata for the larger query.

Tests: same-domain and cross-domain duplicates, equal sAMAccountName on different objects, one object returned twice, case variants, clean multi-domain forest, and a failed domain query.

Priority P1 for detection correctness, but implement after the smallest fixes because forest enumeration has moderate runtime/coverage risk. Plan only. Validate unit, smoke, and integration runners with mocked multi-domain data in Windows PowerShell 5.1.
