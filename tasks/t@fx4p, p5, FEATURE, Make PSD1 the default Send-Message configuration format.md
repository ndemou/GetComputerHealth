<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:37:07.217Z","completions":[]} -->

`Send-Message.ps1 -ConfigFile` already reads JSON and PSD1. Make reporting prefer `config\Send-Message.psd1` and have `-GenerateConfig` write that format by default. Migrate `config\Send-Message.conf` to PSD1 and remove the JSON file after a successful conversion.
