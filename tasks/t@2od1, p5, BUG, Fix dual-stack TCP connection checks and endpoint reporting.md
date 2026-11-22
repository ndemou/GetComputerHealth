<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:37:08.949Z","completions":[]} -->

The helper prefers IPv4 when it fills `RemoteAddress`, but opens TCP using the hostname. Verify that a reachable IPv4 address can succeed when IPv6 is unreachable and that the reported address matches the endpoint used. The TCP timeout is tracked in [#94](https://github.com/ndemou/GetComputerHealth/issues/94).
