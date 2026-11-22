<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:45.340Z","completions":[]} -->

GitHub source: [#114](https://github.com/ndemou/GetComputerHealth/issues/114) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/114#issuecomment-7062098543)

Confirmed: the SYSVOL "manifest" is only file count plus total length. Equal-sized different content or filenames can pass, and enumeration errors are suppressed.

Proposed fix:

1. Enumerate each intended DC's Policies tree with explicit error handling. Use normalized relative paths and a content hash for each file, sorted deterministically before comparison.
2. Hash file streams rather than loading whole trees into memory. Include path boundaries unambiguously and define the treatment of reparse points.
3. Record enumeration/read failures by DC and path; retain useful comparisons from readable DCs, but never emit the all-DC PASS on partial data.
4. Distinguish no DCs, one DC, missing Policies, and a completed multi-DC comparison. Do not confuse an inaccessible path with a proven absent path.
5. Handle files changing during the scan as an unstable snapshot. A bounded recheck or incomplete result is safer than immediately diagnosing persistent replication corruption.
6. Update time/network/disk impact metadata to reflect the additional reads.

Tests: equal trees in different enumeration orders, rename/add/delete, changed bytes with identical size, partial reads, missing root, and concurrent modification.

Priority P2, with high diagnostic value but moderate to high runtime/false-positive risk. Plan only. Validate temporary-tree unit fixtures plus smoke/integration in Windows PowerShell 5.1.
