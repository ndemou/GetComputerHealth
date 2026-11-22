<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:37:07.830Z","completions":[]} -->

Move configured suppressions to `config\suppressed_findings.psd1`. Record the signature, test name, finding description, optional reason, timestamp, expiry, and user. Migrate existing suppression entries from `config\Get-ComputerHealth.sigs-to-suppress.txt` only when the new file does not exist. Preserve the legacy lines.
