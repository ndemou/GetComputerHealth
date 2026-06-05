Describe 'Invoke-GetComputerHealth update rerun handling' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ScriptPath = Join-Path $repoRoot 'Invoke-GetComputerHealth.ps1'
    $script:ScriptText = Get-Content -LiteralPath $script:ScriptPath -Raw

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$tokens, [ref]$parseErrors)

    foreach ($functionName in @(
        'Assert-NoInvokeGetComputerHealthOnlyPassThruArguments'
      )) {
      $funcAst = $ast.Find({
          param($node)
          $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -eq $functionName
        }, $true)

      if ($null -eq $funcAst) {
        throw "Function not found in ${script:ScriptPath}: $functionName"
      }

      . ([scriptblock]::Create($funcAst.Extent.Text))
    }
  }

  It 'allows ordinary pass-through arguments to be forwarded to Get-ComputerHealth' {
    {
      Assert-NoInvokeGetComputerHealthOnlyPassThruArguments -Arguments @(
        '-OnlyTheseTests',
        'HealthTest-Sample',
        '-OutputObjects'
      ) -DestinationScriptPath 'Get-ComputerHealth.ps1'
    } | Should -Not -Throw
  }

  It 'fails loudly before forwarding an internal rerun marker to Get-ComputerHealth' {
    {
      Assert-NoInvokeGetComputerHealthOnlyPassThruArguments -Arguments @(
        '-OnlyTheseTests',
        'HealthTest-Sample',
        '-AlreadyReranAfterUpdate'
      ) -DestinationScriptPath 'C:\IT\Get-ComputerHealth\bin\Get-ComputerHealth.ps1'
    } | Should -Throw '*Internal Invoke-GetComputerHealth.ps1 argument*was about to be forwarded to C:\IT\Get-ComputerHealth\bin\Get-ComputerHealth.ps1*argument-binding bug*'
  }

  It 'stops the original invocation after handing off to the update rerun' {
    $script:ScriptText | Should -Match 'Invoke-SelfAfterUpdate -BoundParameters \$PSBoundParameters -PassThruArgs \$PassThruArgs\s+return'
  }
}
