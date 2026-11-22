<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:37:09.154Z","completions":[]} -->

`HealthTest-SchanelBaseline` already checks Schannel protocols for both Client and Server roles. Add a baseline check for `SchUseStrongCrypto` and `SystemDefaultTlsVersions` under `.NETFramework\v4.0.30319` in the applicable 64-bit and 32-bit registry views. Compare each to the proposed DWORD value `1` and show the observed values and key when a setting is missing or differs. TLS override fingerprints are tracked in [#123](https://github.com/ndemou/GetComputerHealth/issues/123).
