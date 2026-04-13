# AGENTS.md

## Testing

Run tests from the repository root in PowerShell.

### Preferred order

1. Fast unit checks:
   ```powershell
   .\tests\run-unit-tests.ps1
   ```
2. Quick smoke coverage:
   ```powershell
   .\tests\run-all-tests.ps1 -Smoke
   ```
3. Broader integration coverage when the change affects machine-coupled behavior:
   ```powershell
   .\tests\run-all-tests.ps1 -Category Integration
   ```
4. Full repo test pass:
   ```powershell
   .\tests\run-all-tests.ps1
   ```

### What each command does

- `.\tests\run-unit-tests.ps1`
  Runs the Pester suite under [`tests/Unit`](C:/Users/NickDemou/dev/GetComputerHealth/tests/Unit). This is the default check for most code changes.
- `.\tests\run-all-tests.ps1 -Smoke`
  Runs a small, fast subset intended for quick validation.
- `.\tests\run-all-tests.ps1 -Category Integration`
  Runs machine-coupled checks and standalone test scripts. Use this when changes touch broader runtime behavior, service resolution, installer behavior, or environment-dependent logic.
- `.\tests\run-all-tests.ps1`
  Runs the full combined test selection.
- `.\tests\run-all-tests.ps1 -Detailed`
  Same as the full run, but prints extra detail and artifact locations.

### Requirements

- Use Windows PowerShell / PowerShell on Windows.
- Pester 5 or newer must be installed. `.\tests\run-unit-tests.ps1` checks this explicitly.
- Some integration tests depend on the local machine state and may behave differently on CI or sandboxed environments.

### Notes for agents

- Prefer the repo test runners over calling `Invoke-Pester` directly.
- For a small pure-unit change, `.\tests\run-unit-tests.ps1` is usually enough.
- If you add or modify Pester tests, verify them with `.\tests\run-unit-tests.ps1`.
- If you touch installer code, service-path resolution, or machine-environment behavior, also run `.\tests\run-all-tests.ps1 -Smoke` at minimum.
- If a full or integration run fails only because of sandbox or host restrictions, report that clearly instead of treating it as a product regression.
