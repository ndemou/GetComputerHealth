# AGENTS.md

## Testing

Run tests from the repository root in Windows PowerShell (v5).

1. Fast unit checks:
   ```powershell
   .\tests\run-unit-tests.ps1
   ```
  Runs the Pester suite under [`tests/Unit`](C:/Users/NickDemou/dev/GetComputerHealth/tests/Unit). This is the default check for most code changes.
  This is usually enough for a small pure-unit change.
  Also use it if you add or modify Pester tests.

2. Quick smoke coverage:
   ```powershell
   .\tests\run-all-tests.ps1 -Smoke
   ```
  Runs a small, fast subset intended for quick validation.
  Use this at minimum if you touch installer code, service-path resolution, or machine-environment behavior.

3. Broader integration coverage when the change affects machine-coupled behavior:
   ```powershell
   .\tests\run-all-tests.ps1 -Category Integration
   ```
  Runs machine-coupled checks and standalone test scripts. Use this when changes touch broader runtime behavior, service resolution, installer behavior, or environment-dependent logic.
  
4. Full repo test pass:
   ```powershell
   .\tests\run-all-tests.ps1
   ```
  Runs the full combined test selection. `.\tests\run-all-tests.ps1 -Detailed` is the same as the full run, but prints extra detail and artifact locations.

## Notes

- Pester 5 or newer must be installed. `.\tests\run-unit-tests.ps1` checks this explicitly.
- Prefer the repo test runners over calling `Invoke-Pester` directly.
- If a full or integration run fails only because of sandbox or host restrictions, report that clearly instead of treating it as a product regression.
