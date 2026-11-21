Describe 'HealthTest-PreWin2000Group' {
    BeforeAll {
        . "$PSScriptRoot\..\..\health-tests\HealthTest-PreWin2000Group.ps1"

        function Get-ADGroup {
            [CmdletBinding()]
            param([string]$Identity)
            [pscustomobject]@{ Name = $Identity }
        }
        function Get-ADGroupMember {
            [CmdletBinding()]
            param($Identity, [switch]$Recursive)
            $script:members
            if ($script:memberError) { Write-Error $script:memberError }
        }
    }

    BeforeEach {
        $script:members = @()
        $script:memberError = $null
    }

    It 'passes after a successful empty recursive read' {
        Mock Get-ADGroupMember {}
        $findings = @(HealthTest-PreWin2000Group 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match '^\[PASS\].*has no members'
        Should -Invoke Get-ADGroupMember -Times 1 -Exactly -ParameterFilter { $Recursive }
    }

    It 'reports each returned member' {
        $script:members = @(
            [pscustomobject]@{ SamAccountName = 'MemberA' }
            [pscustomobject]@{ SamAccountName = 'MemberB' }
        )

        $findings = @(HealthTest-PreWin2000Group 3>&1)

        $findings | Should -HaveCount 2
        $findings[0].Message | Should -Match '^\[FAILURE\].*MemberA'
        $findings[1].Message | Should -Match '^\[FAILURE\].*MemberB'
    }

    It 'identifies a failed <Operation> query' -ForEach @(
        @{ Operation = 'Get-ADGroup' }
        @{ Operation = 'Get-ADGroupMember' }
    ) {
        Mock $Operation { throw 'AD query failed' }

        $findings = @(HealthTest-PreWin2000Group 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match '^\[WARNING\] Could not check.*membership'
        $findings[0].Message | Should -Match "$Operation.*AD query failed"
        $findings[0].Message | Should -Not -Match 'has no members'
    }

    It 'promotes a nonterminating membership error' {
        $script:memberError = 'Directory unavailable'

        $findings = @(HealthTest-PreWin2000Group 3>&1)

        $findings | Should -HaveCount 1
        $findings[0].Message | Should -Match '^\[WARNING\]'
        $findings[0].Message | Should -Match 'Get-ADGroupMember -Recursive: Directory unavailable'
    }
}
