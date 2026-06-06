Describe 'HealthTest-ListLocalAdmins source' {
  BeforeAll {
    $scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'health-tests\win-os-hyg.ps1'
    $scriptText = Get-Content -LiteralPath $scriptPath -Raw
  }

  It 'renames the function and marks it as Policy' {
    $scriptText | Should -Match 'function HealthTest-ListLocalAdmins \{'
    $scriptText | Should -Match '(?ms)function HealthTest-ListLocalAdmins \{.*?Tags: Policy'
  }

  It 'removes the built-in and allow-list exceptions' {
    $scriptText | Should -Not -Match 'HealthTest-LocalAdminsBaseline'
    $scriptText | Should -Not -Match '\$Allowed\s*='
    $scriptText | Should -Not -Match 'BUILTIN\\Administrators'
    $scriptText | Should -Not -Match 'NT AUTHORITY\\SYSTEM'
    $scriptText | Should -Not -Match 'Domain Admins'
    $scriptText | Should -Not -Match 'Enterprise Admins'
    $scriptText | Should -Not -Match 'ObjectSid'
    $scriptText | Should -Not -Match 'Unexpected Local Administrator'
    $scriptText | Should -Match 'Local Administrator group member:'
  }
}
