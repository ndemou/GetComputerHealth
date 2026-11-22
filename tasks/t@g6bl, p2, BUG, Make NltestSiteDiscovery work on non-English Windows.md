<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:45.439Z","completions":[]} -->

GitHub source: [#115](https://github.com/ndemou/GetComputerHealth/issues/115) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/115#issuecomment-7062099977)

Confirmed: NltestSiteDiscovery requires an English success sentence in addition to exit code 0, so successful localized output fails.

Proposed fix:

1. Keep the existing nltest invocation and capture its exit code immediately, before any other command.
2. Treat a nonzero exit as command failure and preserve the raw output in details. Treat process-start failure separately.
3. For exit 0, extract the site from a validated output structure rather than matching translated success prose. Missing or ambiguous site data should produce an incomplete-output WARNING, not PASS with "(unknown)".
4. Add fixtures before finalizing the extractor. If supported Windows versions do not provide a reliable layout, use the read-only [ActiveDirectorySite.GetComputerSite API](https://learn.microsoft.com/en-us/dotnet/api/system.directoryservices.activedirectory.activedirectorysite.getcomputersite?view=windowsdesktop-9.0) as the structured replacement and update the help accordingly.

Tests: English and Greek successful output, a non-ASCII site name, nonzero status, missing executable, empty output, and a status-only response. Build non-ASCII PowerShell fixtures with character codes to retain PS5.1 source compatibility.

Priority P2; low to moderate risk, principally the output-layout contract. Plan only. Validate unit and smoke tests under Windows PowerShell 5.1.
