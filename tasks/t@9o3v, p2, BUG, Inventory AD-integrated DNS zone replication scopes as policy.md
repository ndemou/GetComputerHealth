<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:44.485Z","completions":[]} -->

GitHub source: [#99](https://github.com/ndemou/GetComputerHealth/issues/99) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/99#issuecomment-7062064166)

Confirmed: HealthTest-DnsZoneReplicationScope prints scopes and then claims they were reviewed. No expected value is compared. Domain, Forest, and custom replication scopes can all be intentional, so a universal Domain requirement would create false positives.

Proposed fix:

1. Make the default test a policy inventory of AD-integrated zones.
2. Emit one finding per zone with stable zone identity and a fingerprint of replication scope plus any custom directory-partition identity needed to distinguish custom scopes.
3. Document the identity and baseline version, update help/category/tags, and remove the claim that listing a value validated it.
4. Preserve a successful no-applicable-zones result, but report query or missing-property failures as incomplete inspection.
5. Use explicit organization configuration if mandatory scopes are needed later.

Tests: Domain versus Forest and distinct custom partitions change identities; ordering changes do not; failed enumeration cannot pass; a genuinely empty applicable set is handled clearly. Include first-run baseline and subsequent scope-change behavior.

Priority P2; low to moderate regression risk, concentrated in policy migration and expected initial baselining. Plan only. Run unit, metadata, and smoke checks under Windows PowerShell 5.1.
