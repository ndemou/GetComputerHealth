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

  It 'places the internal rerun marker before forwarded invocation arguments' {
    $script:ScriptText | Should -Match '\$rerunArgs = @\(\)\s+# Put the internal rerun marker first[\s\S]*?\$rerunArgs \+= ''-AlreadyReranAfterUpdate''[\s\S]*?Convert-BoundParametersToInvocationArguments'
  }

  It 'invokes the local health-check block with named parameters so empty arrays cannot shift argument positions' {
    $script:ScriptText | Should -Match '\$localHealthCheckParams = @\{[\s\S]*?IpsOfAllDcs\s*=\s*\$IpsOfAllDcs[\s\S]*?PassThruArgs\s*=\s*\$PassThruArgs[\s\S]*?\}\s*\$output = & \$healthCheckBlock @localHealthCheckParams'
  }

  It 'checks the remote embedded version before copying and running the updater' {
    $script:ScriptText | Should -Match '\$remoteEmbeddedVersion = Invoke-Command -Session \$session -ScriptBlock \{'
    $script:ScriptText | Should -Match '\$skipTargetUpdate = \$NoUpdate'
    $script:ScriptText | Should -Match '\$pushTargetUpdate = \$false'
    $script:ScriptText | Should -Match '\(\[string\]\$remoteEmbeddedVersion\)\.Trim\(\) -eq \$localEmbeddedVersion'
    $script:ScriptText | Should -Match 'elseif \(\(-not \$skipTargetUpdate\) -and \$controllerCanPushUpdate\) \{'
    $script:ScriptText | Should -Match 'if \(-not \$skipTargetUpdate\) \{[\s\S]*?Copy-Item -Path \$localUpdaterPath -Destination \$remoteUpdaterPath -ToSession \$session -Force'
    $script:ScriptText | Should -Match 'if \(\(-not \$skipTargetUpdate\) -and \$pushTargetUpdate -and \$localReleaseZip\) \{'
    $script:ScriptText | Should -Match 'Invoke-Command -Session \$session -ScriptBlock \$healthCheckBlock -ArgumentList .* \$skipTargetUpdate, \$RunWithoutElevation, \$IpsOfAllDcs, \$pushTargetUpdate, \$remoteZipPath'
  }

  It 'uses a local zip for remote push only when the zip version matches the controller version' {
    $script:ScriptText | Should -Match '\$localReleaseZipEmbeddedVersion = Get-UpdateZipEmbeddedVersion -ZipPath \$localReleaseZip -FallbackVersion \$localEmbeddedVersion'
    $script:ScriptText | Should -Match '\$controllerCanPushUpdate = \$true'
    $script:ScriptText | Should -Match 'Local update zip.*does not match the controller''s Get-ComputerHealth version'
  }
}
