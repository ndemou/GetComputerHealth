Describe 'Invoke-GetComputerHealth update rerun handling' {
  BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ScriptPath = Join-Path $repoRoot 'Invoke-GetComputerHealth.ps1'
    $script:ScriptText = Get-Content -LiteralPath $script:ScriptPath -Raw
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
    $script:ScriptText | Should -Match 'RunWithoutElevation\s*=\s*\[bool\]\$RunWithoutElevation'
    $script:ScriptText | Should -Not -Match '@getHealthParams @PassThruArgs'
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
