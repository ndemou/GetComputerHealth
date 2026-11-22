<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:45.084Z","completions":[]} -->

GitHub source: [#110](https://github.com/ndemou/GetComputerHealth/issues/110) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/110#issuecomment-7062096690)

Confirmed: HealthTest-RdpHardening reads NLA/certificate settings without first determining whether inbound RDP is enabled. The local checkout has newer severity wording than GitHub main, but both have this applicability problem.

Proposed fix:

1. Read the effective inbound-RDP enablement state before the NLA/certificate checks, using read-only Terminal Services state or the effective fDenyTSConnections setting with policy precedence accounted for.
2. If explicitly disabled, emit a short INFO that hardening is not applicable to an active RDP listener, and return.
3. If state is unreadable or missing, report unknown with useful details. Do not cast missing data into "disabled" or infer disablement merely because a connection attempt fails.
4. If enabled, preserve the existing hardening checks and the current local severity/message changes. Keep this separate from broader certificate-validation policy.

Tests: disabled host without NLA/certificate, enabled-and-hardened, enabled-and-unhardened, unreadable/missing state, and conflicting local/policy values. Verify disabled hosts do not query certificate hardening unnecessarily.

Priority P1 for common false-positive reduction; low to moderate risk because effective state must be read correctly. Plan only. Validate unit and smoke tests under Windows PowerShell 5.1; no RDP settings are to be changed.
