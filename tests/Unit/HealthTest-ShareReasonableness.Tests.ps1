Describe 'HealthTest-ShareReasonableness' {
    BeforeAll {
        . "$PSScriptRoot\..\..\health-tests\HealthTest-ShareReasonableness.ps1"
    }

    BeforeEach {
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock Get-CimInstance { [pscustomobject]@{ DomainRole = $script:domainRole } }
        Mock Test-IsRdsLicensingServer { $script:isRds }
        Mock Get-ItemProperty { [pscustomobject]@{ NullSessionPipes = $script:pipes } }
        Mock Get-SmbShare {
            [pscustomobject]@{
                Name = 'Docs'
                Path = 'C:\Docs'
                ShareType = 'FileSystemDirectory'
                FolderEnumerationMode = 'AccessBased'
                EncryptData = $true
            }
        }
        Mock Test-Path { $true } -ParameterFilter { $Path -eq 'C:\Docs' }
        Mock Get-SmbShareAccess {
            [pscustomobject]@{ AccountName = 'Everyone'; AccessRight = $script:right }
        }
        Mock Get-Acl {
            $account = $null
            if ($script:ntfsPrincipal) { $account = [System.Security.Principal.NTAccount]::new($script:ntfsPrincipal) }
            [pscustomobject]@{ Access = @(
                [pscustomobject]@{
                    IdentityReference = $account
                    FileSystemRights = $script:ntfsRight
                    IsInherited = $false
                }
            ) }
        }
    }

    It 'sets the summary correctly for <Case>' -ForEach @(
        @{ Case = 'broad read'; Config = @{ ShareRight = 'Read'; Ntfs = 'Everyone'; FsRight = 'Read' }; Expected = '\[WARNING\].*can read'; Pass = $false }
        @{ Case = 'broad write'; Config = @{ ShareRight = 'Change'; Ntfs = 'Everyone'; FsRight = 'Modify' }; Expected = '\[FAILURE\].*can write'; Pass = $false }
        @{ Case = 'unexpected null pipe'; Config = @{ Pipes = 'LegacyPipe' }; Expected = '\[NOTICE\].*LegacyPipe'; Pass = $false }
        @{ Case = 'exempt DC pipe'; Config = @{ Pipes = 'netlogon'; DomainRole = 4 }; Expected = '\[PASS\]'; Pass = $true }
        @{ Case = 'exempt RDS pipe'; Config = @{ Pipes = 'HydraLsPipe'; IsRds = $true }; Expected = '\[PASS\]'; Pass = $true }
        @{ Case = 'no effective access'; Config = @{ ShareRight = 'Read'; Ntfs = 'LocalSupport'; FsRight = 'Read' }; Expected = '\[PASS\] No effective access'; Pass = $true }
        @{ Case = 'account listing on a clean share'; Config = @{ Ntfs = 'LocalSupport' }; Expected = '\[INFO\] Accounts for share'; Pass = $true }
    ) {
        $script:right = $Config['ShareRight']
        $script:ntfsPrincipal = $Config['Ntfs']
        $script:ntfsRight = $Config['FsRight']
        $script:pipes = $Config['Pipes']
        $script:domainRole = $Config['DomainRole']
        $script:isRds = $Config['IsRds']
        if (-not $script:right) { Mock Get-SmbShareAccess {} }

        $findings = @(HealthTest-ShareReasonableness 3>&1)
        $messages = $findings.Message -join [Environment]::NewLine

        $messages | Should -Match $Expected
        ($messages -match '\[PASS\] No risks related to SMB shares were detected') | Should -Be $Pass
    }
}
