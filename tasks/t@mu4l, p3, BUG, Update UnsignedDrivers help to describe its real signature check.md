<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:44.036Z","completions":[]} -->

GitHub source: [#90](https://github.com/ndemou/GetComputerHealth/issues/90) · [ndemou’s instructions](https://github.com/ndemou/GetComputerHealth/issues/90#issuecomment-7062030793)

Confirmed as a documentation bug. The Uses line names Get-AuthenticodeSignature, but the implementation checks Win32_PnPSignedDriver data and uses SetupVerifyInfFile through SetupAPI for unsigned-looking packages.

Proposed fix:

1. Remove Get-AuthenticodeSignature from Uses.
2. Keep Get-PnpDeviceProperty as the applicable module cmdlet.
3. Describe Win32_PnPSignedDriver and SetupVerifyInfFile/SetupAPI in the detailed help. The repository's Uses rules exclude common built-in cmdlets and nested helper functions, so do not replace the inaccurate entry with an invalid Uses list.
4. Keep the driver classification and signature-verification code unchanged.

Validation: run the existing help-block/unit checks, review the documented dependencies against actual calls, and retain the three-entry limit. No new runtime test is needed for a help-only correction.

Priority P3; very low regression risk. Bundle with #91 and #92 as a small documentation commit. Plan only, no code changed or tests run.
