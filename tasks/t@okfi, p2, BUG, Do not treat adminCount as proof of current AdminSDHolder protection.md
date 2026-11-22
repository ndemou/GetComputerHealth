<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:46.655Z","completions":[]} -->

GitHub source: [#133](https://github.com/ndemou/GetComputerHealth/issues/133) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/133#issuecomment-7062168795)

Confirmed: adminCount=1 can remain after removal from protected groups, so the current message does not prove current protection. A second distinction matters: current protected-group membership establishes expected protection, not proof that SDProp has already applied the expected ACL. See Microsoft's [AdminSDHolder explanation](https://techcommunity.microsoft.com/blog/askds/five-common-questions-about-adminsdholder-and-sdprop/396293) and [protected accounts/groups](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/plan/security-best-practices/appendix-c--protected-accounts-and-groups-in-active-directory).

Proposed fix:

1. First make the existing result honest: INFO inventory of accounts marked adminCount=1, with no claim that protection was verified. This is a small independently useful change.
2. For actual expected-coverage reporting, resolve the documented protected accounts/groups by stable identities, including nested membership and protected built-in accounts. Account for supported AD behavior and configured exclusions; do not rely on localized group names.
3. Keep marked accounts, currently expected protected accounts, and any actually verified ACL state separate. Handle recursive membership without cycles and mark incomplete cross-domain or group queries explicitly.
4. Report formerly protected accounts with stale markers as review/cleanup candidates only after membership evaluation is complete. Do not automatically clear adminCount or reset ACL inheritance.
5. Do not claim that no users are protected merely because the marker query returned none.

Tests: direct/nested protected membership, built-in protected account, stale marker, membership cycles, incomplete lookup, and expected protection before the ACL has been verified.

Priority P2. The wording correction is low risk; complete coverage is moderate to high risk and should be a separate change. Plan only. Validate unit and smoke, then read-only AD integration under Windows PowerShell 5.1.
