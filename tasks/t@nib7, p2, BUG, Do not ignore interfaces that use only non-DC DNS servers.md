<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:44.908Z","completions":[]} -->

GitHub source: [#105](https://github.com/ndemou/GetComputerHealth/issues/105) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/105#issuecomment-7062068636)

Confirmed: an interface with only non-DC DNS addresses is deliberately ignored, and another clean interface can then trigger "All interfaces ... use only DC IPs." That conclusion is false for the inspected set.

A separate policy qualification matters: a non-DC DNS server can be intentionally configured to resolve AD zones. This test's DC-only rule should be explicit, not presented as a universal networking requirement.

Proposed fix:

1. Define relevant interfaces from active/connected adapter data, joining by stable interface identity. IPEnabled alone does not establish that a link is active.
2. For interfaces subject to the DC-only baseline, evaluate every configured address. Remove the all-non-DC silent exemption.
3. Make deliberate VPN/special-purpose exclusions explicit and visible in details; do not infer exclusion from the DNS addresses being tested.
4. Treat an empty/unavailable DC-IP inventory as incomplete evidence, not proof that every resolver is wrong.
5. Emit overall PASS only when all applicable interfaces satisfy the baseline. Correct the stale detailed help, which currently describes an unrelated ipconfig/suffix check.

Tests: clean Ethernet plus public-DNS Wi-Fi, mixed address lists, inactive/excluded interfaces, and missing DC inventory.

Priority P2; moderate false-positive risk unless scope/exclusions are defined first. Plan only. Validate unit, smoke, and integration runners in Windows PowerShell 5.1.
