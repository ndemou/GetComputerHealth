<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:46.924Z","completions":[]} -->

GitHub source: [#136](https://github.com/ndemou/GetComputerHealth/issues/136) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/136#issuecomment-7062170712)

Confirmed: the default result claims every AD site has a GC but only enumerates the current domain's DCs. It can both miss sites in other domains and falsely reject a shared site whose GC belongs to another domain.

Proposed fix:

1. In forest mode, enumerate every forest domain and query its DCs explicitly. Track successful, empty, and failed domain queries separately.
2. Build site membership from the complete DC inventory, using the forest site inventory to validate site identities. A site containing no DCs is not automatically a missing-GC failure.
3. Apply the existing per-site expectation only to its documented applicable sites. Clarify that a GC-per-site requirement is a deployment policy, not a universal AD correctness rule; preserve explicit exceptions/configuration where required.
4. A failed domain query makes the forest result incomplete. If an unavailable domain could supply a site's GC, report that uncertainty instead of confidently asserting no GC exists.
5. Preserve the explicit domain-only mode and make both metadata and messages describe the actual scope. No forest-wide PASS from domain-only or partial data.

Tests: multiple domains, a site appearing only in another domain, a shared site with its GC in another domain, a confirmed site without a GC, an unreachable domain, an empty site, empty discovery, and domain-only mode.

Priority P2; moderate risk due to cross-domain coverage and site-policy semantics. Plan only. Validate unit and smoke, followed by read-only multi-domain integration under Windows PowerShell 5.1.
