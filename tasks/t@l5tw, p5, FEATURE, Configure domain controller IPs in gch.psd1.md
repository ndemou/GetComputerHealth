<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:37:07.149Z","completions":[]} -->

The trick with `cache.IpsOfAllDcs.clixml` is a hack. I should incorporate it into gch.psd1. An on-disk format migration can populate the new setting if the file is found, and then remove the old file.

Example `gch.psd1`:
```pwsh
@{
    AutomaticUpdates = $false
    ShowAsPostponedWindowDays = 15
    IpsOfAllDCs = @('192.0.2.10', '192.0.2.11')
}
```
