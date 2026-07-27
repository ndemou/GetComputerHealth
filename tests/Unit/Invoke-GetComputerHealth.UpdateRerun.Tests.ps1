Describe 'Invoke-GetComputerHealth update rerun handling' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ScriptPath = Join-Path $repoRoot 'Invoke-GetComputerHealth.ps1'
    $script:ScriptText = Get-Content -LiteralPath $script:ScriptPath -Raw

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
      $script:ScriptPath,
      [ref]$tokens,
      [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
      throw ($parseErrors | Out-String)
    }

    $childParameterFunction = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-ChildHealthInvocationParameters'
      }, $true)
    if (-not $childParameterFunction) {
      throw 'Get-ChildHealthInvocationParameters was not found.'
    }

    . ([scriptblock]::Create($childParameterFunction.Extent.Text))
  }

  It 'no longer accepts trailing free-form pass-through arguments' {
    $script:ScriptText | Should -Not -Match 'ValueFromRemainingArguments'
    $script:ScriptText | Should -Not -Match '\$PassThruArgs'
  }

  It 'stops the original invocation after handing off to the update rerun' {
    $script:ScriptText | Should -Match 'Invoke-SelfAfterUpdate -BoundParameters \$PSBoundParameters\s+return'
  }

  It 'builds rerun parameters from declared wrapper parameters only' {
    $script:ScriptText | Should -Match 'function Get-InvokeGetComputerHealthRerunParameters'
    $script:ScriptText | Should -Match '\$rerunParams = @\{\}'
    $script:ScriptText | Should -Match 'if \(\$entry\.Key -eq ''AlreadyReranAfterUpdate''\) \{ continue \}'
    $script:ScriptText | Should -Match '\$rerunParams\[''AlreadyReranAfterUpdate''\] = \$true'
    $script:ScriptText | Should -Match '& \$PSCommandPath @rerunParams'
  }

  It 'uses a dedicated child-parameter helper instead of forwarding arbitrary wrapper arguments' {
    $script:ScriptText | Should -Match 'function Get-ChildHealthInvocationParameters'
    $script:ScriptText | Should -Match 'IpsOfAllDcs\s*=\s*@\(\$IpsOfAllDcs\)'
    $script:ScriptText | Should -Match 'OnlyTheseTests\s*=\s*@\(\$OnlyTheseTests\)'
    $script:ScriptText | Should -Match 'ExcludeTests\s*=\s*@\(\$ExcludeTests\)'
    $script:ScriptText | Should -Match 'SuppressSigs\s*=\s*@\(\$WhitelistSigs\)'
    $script:ScriptText | Should -Match 'RunWithoutElevation\s*=\s*\[bool\]\$RunWithoutElevation'
    $script:ScriptText | Should -Match 'if \(\$IReallyWantToRunTestsThatChangeState\) \{\s*\$childParams\[''IReallyWantToRunTestsThatChangeState''\] = \$true'
    @([regex]::Matches($script:ScriptText, 'Get-ChildHealthInvocationParameters[^\r\n]+-IReallyWantToRunTestsThatChangeState:\$IReallyWantToRunTestsThatChangeState')).Count | Should -Be 2
    $script:ScriptText | Should -Not -Match '@getHealthParams @PassThruArgs'
  }

  It 'declares list-like wrapper arguments as string arrays' {
    $script:ScriptText | Should -Match '\[string\[\]\]\$WhitelistSigs\s*=\s*@\(\)'
    $script:ScriptText | Should -Match '\[string\[\]\]\$OnlyTheseTests\s*=\s*@\(\)'
    $script:ScriptText | Should -Match '\[string\[\]\]\$ExcludeTests\s*=\s*@\(\)'
  }

  It 'omits the guarded switch from child parameters by default' {
    $childParameters = Get-ChildHealthInvocationParameters

    $childParameters.ContainsKey('IReallyWantToRunTestsThatChangeState') | Should -BeFalse
  }

  It 'adds the guarded switch to child parameters only after explicit opt-in' {
    $childParameters = Get-ChildHealthInvocationParameters -IReallyWantToRunTestsThatChangeState

    $childParameters['IReallyWantToRunTestsThatChangeState'] | Should -BeTrue
  }

  It 'invokes the local health-check block with a single payload object' {
    $script:ScriptText | Should -Match '\$localExecutionPayload = @\{[\s\S]*?WrapperState = @\{[\s\S]*?PushUpdate\s*=\s*\[bool\]\$PushUpdate[\s\S]*?ChildHealthParams = \$localChildHealthParams[\s\S]*?\}'
    $script:ScriptText | Should -Match '\$output = & \$healthCheckBlock -Payload \$localExecutionPayload'
  }

  It 'checks the remote embedded version before copying and running the updater' {
    $script:ScriptText | Should -Match '\$remoteEmbeddedVersion = Invoke-Command -Session \$session -ScriptBlock \{'
    $script:ScriptText | Should -Match '\$skipTargetUpdate = \$NoUpdate'
    $script:ScriptText | Should -Match '\$pushTargetUpdate = \$false'
    $script:ScriptText | Should -Match '\(\[string\]\$remoteEmbeddedVersion\)\.Trim\(\) -eq \$localEmbeddedVersion'
    $script:ScriptText | Should -Match 'elseif \(\(-not \$skipTargetUpdate\) -and \$controllerCanPushUpdate\) \{'
    $script:ScriptText | Should -Match 'if \(-not \$skipTargetUpdate\) \{[\s\S]*?Copy-Item -Path \$localUpdaterPath -Destination \$remoteUpdaterPath -ToSession \$session -Force'
    $script:ScriptText | Should -Match 'if \(\(-not \$skipTargetUpdate\) -and \$pushTargetUpdate -and \$localReleaseZip\) \{'
  }

  It 'uses a single payload object for remote execution and invokes the child script only via named splatting' {
    $script:ScriptText | Should -Match '\$remoteExecutionPayload = @\{[\s\S]*?WrapperState = @\{[\s\S]*?PushUpdate\s*=\s*\$pushTargetUpdate[\s\S]*?ChildHealthParams = \$remoteChildHealthParams[\s\S]*?\}'
    $script:ScriptText | Should -Match 'Invoke-Command -Session \$session -ScriptBlock \$healthCheckBlock -ArgumentList \$remoteExecutionPayload'
    $script:ScriptText | Should -Match '\$healthOutput = & \$getHealthScriptPath @childHealthParams 2>&1'
  }

  It 'uses a local zip for remote push only when the zip version matches the controller version' {
    $script:ScriptText | Should -Match '\$localReleaseZipEmbeddedVersion = Get-UpdateZipEmbeddedVersion -ZipPath \$localReleaseZip -FallbackVersion \$localEmbeddedVersion'
    $script:ScriptText | Should -Match '\$controllerCanPushUpdate = \$true'
    $script:ScriptText | Should -Match 'Local update zip.*does not match the controller''s Get-ComputerHealth version'
  }
}
