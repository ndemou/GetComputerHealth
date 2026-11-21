Describe 'HealthTest-VssWriters' {
    BeforeAll {
        . "$PSScriptRoot\..\..\health-tests\HealthTest-VssWriters.ps1"

        function vssadmin.exe {
            $global:LASTEXITCODE = $script:status
            $script:nativeOutput
        }

        function New-WriterBlock([string]$Name, [int]$Code, [guid]$InstanceId) {
            @"
Writer name: '$Name'
   Writer Id: {d61d61c8-d73a-4eee-8cdd-f6f9786b7124}
   Writer Instance Id: {$InstanceId}
   State: [$Code] Description
   Last error: Details
"@
        }
    }

    BeforeEach {
        $script:previousExitCode = Get-Variable LASTEXITCODE -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        $script:status = 0
        $script:banner = "vssadmin 1.1 - Volume Shadow Copy Service administrative command-line tool`n(C) Copyright 2001-2013 Microsoft Corp."
        $script:stable = (New-WriterBlock 'Task Scheduler Writer' 1 ([guid]::NewGuid())) -replace 'Description', 'Stable' -replace 'Details', 'No error'
    }

    AfterEach {
        if ($null -eq $script:previousExitCode) {
            Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        } else {
            $global:LASTEXITCODE = $script:previousExitCode
        }
    }

    It 'passes real-format English records and equivalent localized fields' {
        $localized = (New-WriterBlock 'System Writer' 1 ([guid]::NewGuid())) -replace 'Writer name', 'Nom du redacteur' -replace 'Writer Instance Id', 'ID instance' -replace 'Writer Id', 'ID redacteur' -replace 'State', 'Etat' -replace 'Last error', 'Derniere erreur'
        $script:nativeOutput = $script:banner + "`n`n" + $script:stable + "`n`n" + $localized

        $findings = @(HealthTest-VssWriters 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match '^\[PASS\]'
    }

    It 'passes when another writer is in waiting state <Code>' -ForEach @(
        @{ Code = 2 }
        @{ Code = 3 }
        @{ Code = 4 }
        @{ Code = 5 }
    ) {
        $waiting = (New-WriterBlock 'Waiting Writer' $Code ([guid]::NewGuid())) -replace 'Details', 'No error'
        $script:nativeOutput = $script:stable + "`n`n" + $waiting

        $findings = @(HealthTest-VssWriters 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Be '[PASS] All VSS writers report stable or waiting states'
    }

    It 'reports <Level> for state <Code> even when other writers are stable or waiting' -ForEach @(
        @{ Code = 6; Level = 'FAILURE'; Detail = 'failed' }
        @{ Code = 15; Level = 'FAILURE'; Detail = 'failed' }
        @{ Code = 0; Level = 'WARNING'; Detail = 'Unknown VSS writer state' }
        @{ Code = 16; Level = 'WARNING'; Detail = 'Unknown VSS writer state' }
    ) {
        $other = New-WriterBlock 'Second Writer' $Code ([guid]::NewGuid())
        $waiting = (New-WriterBlock 'Waiting Writer' 5 ([guid]::NewGuid())) -replace 'Details', 'No error'
        $script:nativeOutput = $script:stable + "`n`n" + $waiting + "`n`n" + $other

        $findings = @(HealthTest-VssWriters 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match "^\[$Level\]"
        $findings[0].Message | Should -Match 'Second Writer'
        $findings[0].Message | Should -Match $Detail
    }

    It 'warns for <Case> output' -ForEach @(
        @{ Case = 'empty' }
        @{ Case = 'duplicate' }
        @{ Case = 'missing state' }
        @{ Case = 'no recognized records' }
    ) {
        $script:nativeOutput = switch ($Case) {
            'empty' { '' }
            'duplicate' { $script:stable + "`n`n" + $script:stable }
            'missing state' { $script:stable -replace 'State: \[1\] Stable', '' }
            'no recognized records' { $script:banner + "`n`nNo items found." }
        }

        $findings = @(HealthTest-VssWriters 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match '^\[WARNING\].*inspection was incomplete'
    }

    It 'reports a nonzero native status without classifying the writer output' {
        $script:status = 5
        $script:nativeOutput = $script:stable

        $findings = @(HealthTest-VssWriters 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match '^\[WARNING\].*inspection failed'
        $findings[0].Message | Should -Match 'Exit code: 5'
    }

    It 'reports process-start failures' {
        Mock vssadmin.exe { throw 'Command not found' }

        $findings = @(HealthTest-VssWriters 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match '^\[WARNING\] Could not start'
        $findings[0].Message | Should -Match 'Command not found'
    }
}
