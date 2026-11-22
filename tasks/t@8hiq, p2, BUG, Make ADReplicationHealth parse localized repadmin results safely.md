<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:46.121Z","completions":[]} -->

GitHub source: [#125](https://github.com/ndemou/GetComputerHealth/issues/125) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/125#issuecomment-7062162794)

Confirmed, with an important qualification: completely unparsed repadmin output already emits FAILURE/WARNING rather than silently passing. The remaining risks are localized false diagnoses, partial parser coverage, ignored process exit codes, and a local RSAT result that cannot establish domain-wide health.

Proposed fix:

1. Prefer structured AD replication metadata for every intended DC and naming context, not only the local DC. Use explicit DC enumeration and record query completeness.
2. Evaluate LastReplicationResult, consecutive failures where available, and last-success age using the existing thresholds. Missing timestamps are unknown, not recent success.
3. Preserve DC/partner/partition identities so results cannot be merged incorrectly. Handle single-DC/no-partner cases explicitly.
4. If repadmin remains as fallback or diagnostic detail, capture exit status and parser coverage. Unparsed/truncated output must be labeled incomplete, not diagnosed as replication corruption.
5. A local fallback result must retain local wording. No domain-wide PASS after an unreadable DC or incomplete source.
6. Update dependencies and impact metadata for the actual coverage.

Tests: healthy multi-DC data, partner failure, stale/unknown success time, one unreachable DC, local-only fallback, and English/localized native samples that cannot create false all-clear results.

Priority P2 despite high impact, because replacing the evidence source has moderate to high coverage/regression risk. Plan only. Validate unit, smoke, and integration under Windows PowerShell 5.1.
