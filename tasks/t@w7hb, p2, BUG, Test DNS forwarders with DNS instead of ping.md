<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:44.332Z","completions":[]} -->

GitHub source: [#97](https://github.com/ndemou/GetComputerHealth/issues/97) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/97#issuecomment-7062062612)

Confirmed: HealthTest-DnsForwarders tests Test-Connection, so it measures ICMP rather than DNS service behavior.

Proposed fix:

1. Replace the ping decision with a DNS-only query sent to the specific forwarder using Resolve-DnsName, bypassing hosts-file answers. Use the supported QuickTimeout option and document its limits rather than claiming a precise configurable millisecond deadline. See [Resolve-DnsName](https://learn.microsoft.com/en-us/powershell/module/dnsclient/Resolve-DnsName?view=windowsserver2022-ps).
2. Define the probe explicitly, initially a root NS query, and document its suitability for the intended resolver environment. Restricted resolvers may need an organization-approved probe.
3. Distinguish no response/transport failure from a DNS error response. NXDOMAIN or REFUSED proves a DNS responder exists but does not prove the chosen forwarding operation succeeded.
4. Include forwarder IP, query, and error in details; continue other forwarders. Keep loopback and public/private-address findings separate.
5. Update Uses and PASS wording to match the service actually tested.

Tests: ICMP blocked with DNS success, ICMP success with DNS timeout, refusal/NXDOMAIN, malformed response, multiple forwarders, and no configured forwarders. Assert ping is no longer a prerequisite.

Priority P2; moderate regression risk due to probe policy and timeout semantics. Plan only. Validate unit, smoke, and integration runners in Windows PowerShell 5.1.
