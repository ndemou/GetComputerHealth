Describe 'HealthTest-ListRoleFeatures source' {
  BeforeAll {
    $scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'health-tests\OnlyIfHostIs-Server.ps1'
    $scriptText = Get-Content -LiteralPath $scriptPath -Raw
  }

  It 'renames the function and marks it as Policy' {
    $scriptText | Should -Match 'function HealthTest-ListRoleFeatures \{'
    $scriptText | Should -Match '(?ms)function HealthTest-ListRoleFeatures \{.*?Tags: Policy'
  }

  It 'removes disallowed-role filtering and reports installed roles as warnings' {
    $scriptText | Should -Not -Match 'HealthTest-InstalledRolesFeatures'
    $scriptText | Should -Not -Match '\$DisallowedRoles\s*='
    $scriptText | Should -Not -Match 'Unintended role/feature installed:'
    $scriptText | Should -Not -Match '\[FAILURE\] Unintended role/feature installed:'
    $scriptText | Should -Match 'Installed role/feature:'
  }
}
