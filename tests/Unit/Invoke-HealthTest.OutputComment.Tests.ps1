Describe 'Invoke-HealthTest output stream comment capture' {
  BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:GetComputerHealthScript = Join-Path $script:RepoRoot 'Get-ComputerHealth.ps1'

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:GetComputerHealthScript, [ref]$tokens, [ref]$parseErrors)

    foreach ($functionName in @('Convert-TextToLogRecord', 'Convert-WarningLikeObjectToLogRecord', 'Invoke-HealthTest')) {
      $funcAst = $ast.Find({
          param($node)
          $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -eq $functionName
        }, $true)

      $funcAst | Should -Not -BeNullOrEmpty
      . ([scriptblock]::Create($funcAst.Extent.Text))
    }
  }

  BeforeEach {
    $script:Logged = @()
    $script:DebugMessages = @()
    $script:NoticeMessages = @()
    $script:FailureMessages = @()
    $script:ExcludeTests = @()

    function Get-HealthTestTagsMetadata {
      param([string]$FunctionName)
      [pscustomobject]@{
        TestName = ($FunctionName -replace '^HealthTest-', '')
        Tags = @()
      }
    }

    function Log-Debug {
      param([string]$Message, [string]$Comment = '')
      $script:DebugMessages += [pscustomobject]@{
        Message = $Message
        Comment = $Comment
      }
    }

    function Log-Notice {
      param([string]$Message, [string]$Comment = '')
      $script:NoticeMessages += [pscustomobject]@{
        Message = $Message
        Comment = $Comment
      }
    }

    function Log-Failure {
      param([string]$Message, [string]$Comment = '', [string]$Emitter = '')
      $script:FailureMessages += [pscustomobject]@{
        Message = $Message
        Comment = $Comment
        Emitter = $Emitter
      }
    }

    function Log-Msg {
      param(
        [string]$Level,
        [string]$Msg,
        [string]$Comment = '',
        [string]$Emitter = '',
        [switch]$Suppressed
      )

      $record = [pscustomobject]@{
        Level = $Level
        Msg = $Msg
        Comment = $Comment
        Emitter = $Emitter
        Suppressed = [bool]$Suppressed
      }
      $script:Logged += $record
      $record
    }
  }

  It 'adds collected output stream text to the last warning-backed record comment' {
    function HealthTest-CommentCaptureA {
      Write-Warning "[NOTICE] First message"
      Write-Warning "[WARNING] Final message`nExisting comment"
      Write-Output "detail one"
      Write-Output "detail two"
    }

    $records = @(Invoke-HealthTest -FunctionName 'HealthTest-CommentCaptureA')

    $records | Should -HaveCount 2
    $records[0].Msg | Should -Be 'First message'
    $records[0].Comment | Should -Be ''
    $records[1].Msg | Should -Be 'Final message'
    $records[1].Comment | Should -Be "Existing comment`ndetail one`ndetail two"
    @($script:DebugMessages | Where-Object { $_.Message -eq 'Starting test HealthTest-CommentCaptureA' }).Count | Should -Be 1
    @($script:DebugMessages | Where-Object { $_.Message -eq 'detail one' -or $_.Message -eq 'detail two' }).Count | Should -Be 0
  }

  It 'falls back to debug conversion when no warning-backed record exists' {
    function HealthTest-CommentCaptureB {
      Write-Output "orphan detail"
    }

    $records = @(Invoke-HealthTest -FunctionName 'HealthTest-CommentCaptureB')

    $records.Count | Should -Be 0
    @($script:DebugMessages | Where-Object { $_.Message -eq 'Starting test HealthTest-CommentCaptureB' }).Count | Should -Be 1
    @($script:DebugMessages | Where-Object { $_.Message -eq 'orphan detail' }).Count | Should -Be 1
  }
}
