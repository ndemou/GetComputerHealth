<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:43.813Z","completions":[]} -->

GitHub source: [#84](https://github.com/ndemou/GetComputerHealth/issues/84) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/84#issuecomment-7062024396)

Confirmed in `HealthTest-LargeDirectories.ps1`. Both failed root resolution and failed child enumeration are discarded. The final PASS only checks whether a large directory was returned.

Proposed fix:

1. Collect traversal failures separately from directory results, preserving the helper's existing result shape for callers.
2. Record the requested root or failed child path and useful error details. Continue other readable branches.
3. Keep configured skips separate from failures. A deliberately skipped tree is outside the scan scope; an inaccessible tree is incomplete inspection. Do not turn missing optional skip paths into scan errors.
4. Emit one bounded WARNING summary with a total count and a few failed paths. Reserve PASS for a completed scan of the intended, non-excluded scope.
5. Keep the item-count threshold and traversal rules unchanged. Failure to build an optional narrative for an already-detected large directory must not hide that finding.

Tests: complete empty scan, detected large directory, unreadable root, unreadable child with a readable sibling, and configured skips whose contents are never enumerated. Use temporary fixtures and mocked read errors.

Priority P2; regression risk low to moderate, mainly excessive warnings from expected access restrictions. Plan only. Validate with unit and smoke runners in Windows PowerShell 5.1; no real whole-drive scan is needed for regression tests.
