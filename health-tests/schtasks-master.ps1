<#
Scheduled Task Master Cluster
#>

$script:ScheduledTaskFactsCache = $null

function Reset-ScheduledTaskFactsCache {
  [CmdletBinding()]
  param()

  $script:ScheduledTaskFactsCache = $null
}

function Get-ScheduledTaskDefaultNameIgnorePatterns {
  @(
    'OneDrive Per-Machine Standalone Update Task*',
    'OneDrive Reporting Task*',
    'OneDrive Standalone Update*',
    'Office Feature Updates*',
    'Firefox Background Update*',
    'Firefox Default Browser Agent*',
    'Office Actions Server*',
    'Clipboard User Service*',
    'Optimize Start Menu Cache Files-*',
    'User_Feed_Synchronization-*',
    'SoftLanding*'
  )
}

function Get-ScheduledTaskDefaultPathIgnoreRegex {
  @(
    '^\\Microsoft\\Windows\\(AppxDeploymentClient|Bluetooth|Clip|PushToInstall|SharedPC)\\',
    '^\\Microsoft\\Windows\\(InstallService|WaaSMedic|UpdateOrchestrator)\\',
    '^\\Microsoft\\Windows\\(PLA\\Server Manager Performance Monitor|File Classification Infrastructure\\Property Definition Sync)$',
    '^\\Microsoft\\Windows\\\.NET Framework\\\.NET Framework NGEN v4\.0\.30319.*$',
    '^\\Microsoft\\Windows\\Server Initial Configuration Task$'
  )
}

function Convert-ISODuration {
  param([string]$Iso)

  if (-not $Iso) { return $null }

  $match = [regex]::Match($Iso, '^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$')
  if (-not $match.Success) { return $Iso }

  $parts = New-Object System.Collections.Generic.List[string]
  if ($match.Groups[1].Value) {
    $number = [int]$match.Groups[1].Value
    $suffix = ''
    if ($number -ne 1) { $suffix = 's' }
    [void]$parts.Add("$number day$suffix")
  }
  if ($match.Groups[2].Value) {
    $number = [int]$match.Groups[2].Value
    $suffix = ''
    if ($number -ne 1) { $suffix = 's' }
    [void]$parts.Add("$number hour$suffix")
  }
  if ($match.Groups[3].Value) {
    $number = [int]$match.Groups[3].Value
    $suffix = ''
    if ($number -ne 1) { $suffix = 's' }
    [void]$parts.Add("$number minute$suffix")
  }
  if ($match.Groups[4].Value) {
    $number = [int]$match.Groups[4].Value
    $suffix = ''
    if ($number -ne 1) { $suffix = 's' }
    [void]$parts.Add("$number second$suffix")
  }

  if ($parts.Count -eq 0) { return $Iso }
  return ($parts -join ' ')
}

function Convert-TaskResultCode {
  param([int64]$Code)

  $unsignedCode = ConvertTo-ScheduledTaskUInt32 -Code $Code
  $hex = '0x{0:X8}' -f $unsignedCode
  switch ($Code) {
    0 { 'Success (0)' }
    2147750687 { "Operator/admin refused ($hex)" }
    2147942402 { "File not found ($hex)" }
    2147942403 { "Path not found ($hex)" }
    2147942405 { "Access denied ($hex)" }
    2147954402 { "Service not started ($hex)" }
    267008 { "Ready ($hex)" }
    267009 { "Running ($hex)" }
    267010 { "Disabled ($hex)" }
    267011 { "Not yet run ($hex)" }
    267012 { "No more runs ($hex)" }
    267013 { "Terminated ($hex)" }
    267014 { "No active triggers ($hex)" }
    2147946720 { "Either wrong password or win32 error 0x800710E0('The operator or administrator has refused the request')" }
    default {
      $win32 = $Code
      $numberStyle = [System.Globalization.NumberStyles]::HexNumber
      $win32FacilityMask = [uint32]::Parse('FFFF0000', $numberStyle)
      $win32Facility = [uint32]::Parse('80070000', $numberStyle)
      if ($null -ne $unsignedCode -and (($unsignedCode -band $win32FacilityMask) -eq $win32Facility)) {
        $win32 = $unsignedCode -band [uint32]::Parse('0000FFFF', $numberStyle)
      }

      $win32Message = ''
      try {
        $win32Message = (New-Object ComponentModel.Win32Exception ([int]$win32)).Message
      } catch {
        $win32Message = ''
      }

      if ($win32Message) {
        "Possible win32 error $hex('$win32Message')"
      } else {
        "Non standard code hex=$hex"
      }
    }
  }
}

function Get-ScheduledTaskPropertyValue {
  param(
    [AllowNull()][object]$InputObject,
    [Parameter(Mandatory=$true)][string]$Name
  )

  if ($null -eq $InputObject) { return $null }

  $property = $InputObject.PSObject.Properties[$Name]
  if ($property) { return $property.Value }

  return $null
}

function ConvertTo-ScheduledTaskSimpleText {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) { return '' }

  $text = [string]$Value
  $text = $text.Trim()
  $text = $text -replace '\s+', ' '
  return $text
}

function ConvertTo-ScheduledTaskFingerprintText {
  param([AllowNull()][object]$Value)

  $text = ConvertTo-ScheduledTaskSimpleText -Value $Value
  return $text.ToLowerInvariant()
}

function ConvertTo-ScheduledTaskListText {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) { return '' }
  if ($Value -is [string]) { return (ConvertTo-ScheduledTaskSimpleText -Value $Value) }

  $items = New-Object System.Collections.Generic.List[string]
  foreach ($item in @($Value)) {
    $text = ConvertTo-ScheduledTaskSimpleText -Value $item
    if (-not [string]::IsNullOrWhiteSpace($text)) {
      [void]$items.Add($text)
    }
  }

  return ($items -join ',')
}

function Normalize-ScheduledTaskPath {
  param([AllowNull()][string]$TaskPath)

  $path = ConvertTo-ScheduledTaskSimpleText -Value $TaskPath
  if ([string]::IsNullOrWhiteSpace($path)) { $path = '\' }
  $path = $path.Replace('/', '\')
  if (-not $path.StartsWith('\')) { $path = '\' + $path }
  if (-not $path.EndsWith('\')) { $path = $path + '\' }
  return $path
}

function Get-ScheduledTaskStableKey {
  param(
    [AllowNull()][string]$TaskPath,
    [AllowNull()][string]$TaskName
  )

  $path = Normalize-ScheduledTaskPath -TaskPath $TaskPath
  $name = ConvertTo-ScheduledTaskSimpleText -Value $TaskName
  return ($path + $name)
}

function Test-ScheduledTaskPrincipalPrivileged {
  [CmdletBinding()]
  param(
    [AllowNull()][string]$PrincipalUserId,
    [AllowNull()][string]$RunLevel
  )

  $runLevelText = ConvertTo-ScheduledTaskSimpleText -Value $RunLevel
  if ($runLevelText -match '(?i)^highest') { return $true }

  $principal = ConvertTo-ScheduledTaskSimpleText -Value $PrincipalUserId
  if ([string]::IsNullOrWhiteSpace($principal)) { return $true }

  $normalized = $principal.ToUpperInvariant()
  $normalized = $normalized -replace '/', '\'

  if ($normalized -in @('SYSTEM', 'NT AUTHORITY\SYSTEM')) { return $true }
  if ($normalized -in @('LOCAL SERVICE', 'NT AUTHORITY\LOCAL SERVICE')) { return $true }
  if ($normalized -in @('NETWORK SERVICE', 'NT AUTHORITY\NETWORK SERVICE')) { return $true }
  if ($normalized -eq 'S-1-5-18') { return $true }
  if ($normalized -eq 'S-1-5-19') { return $true }
  if ($normalized -eq 'S-1-5-20') { return $true }
  if ($normalized -eq 'S-1-5-32-544') { return $true }
  if ($normalized -match '(^|\\)ADMINISTRATORS$') { return $true }
  if ($normalized -match '(^|\\)DOMAIN ADMINS$') { return $true }
  if ($normalized -match '(^|\\)ENTERPRISE ADMINS$') { return $true }

  return $false
}

function Test-ScheduledTaskSystemPrincipal {
  param([AllowNull()][string]$PrincipalUserId)

  $principal = ConvertTo-ScheduledTaskSimpleText -Value $PrincipalUserId
  if ([string]::IsNullOrWhiteSpace($principal)) { return $false }

  return ($principal -match '^(?i)(NT AUTHORITY\\)?SYSTEM$')
}

function Test-ScheduledTaskBuiltInMicrosoft {
  [CmdletBinding()]
  param(
    [AllowNull()][string]$TaskPath,
    [AllowNull()][string]$Author
  )

  $path = Normalize-ScheduledTaskPath -TaskPath $TaskPath
  if ($path -like '\Microsoft\*') { return $true }

  $authorText = ConvertTo-ScheduledTaskSimpleText -Value $Author
  if ($authorText -match '(?i)\bMicrosoft\b') { return $true }

  return $false
}

function Test-ScheduledTaskTriggerEnabled {
  param([AllowNull()][object]$Trigger)

  if ($null -eq $Trigger) { return $false }

  $enabled = Get-ScheduledTaskPropertyValue -InputObject $Trigger -Name 'Enabled'
  if ($null -ne $enabled) { return [bool]$enabled }

  return $true
}

function Get-ScheduledTaskActionType {
  param([AllowNull()][object]$Action)

  $actionType = Get-ScheduledTaskPropertyValue -InputObject $Action -Name 'ActionType'
  if ($actionType) { return (ConvertTo-ScheduledTaskSimpleText -Value $actionType) }

  $cimClass = Get-ScheduledTaskPropertyValue -InputObject $Action -Name 'CimClass'
  if ($cimClass) {
    $className = Get-ScheduledTaskPropertyValue -InputObject $cimClass -Name 'CimClassName'
    if ($className) { return ((ConvertTo-ScheduledTaskSimpleText -Value $className) -replace '^MSFT_Task','') }
  }

  if ($null -ne $Action) {
    return (ConvertTo-ScheduledTaskSimpleText -Value ($Action.PSObject.TypeNames | Select-Object -First 1))
  }

  return ''
}

function Get-ScheduledTaskTriggerType {
  param([AllowNull()][object]$Trigger)

  $triggerType = Get-ScheduledTaskPropertyValue -InputObject $Trigger -Name 'TriggerType'
  if ($triggerType) { return (ConvertTo-ScheduledTaskSimpleText -Value $triggerType) }

  $cimClass = Get-ScheduledTaskPropertyValue -InputObject $Trigger -Name 'CimClass'
  if ($cimClass) {
    $className = Get-ScheduledTaskPropertyValue -InputObject $cimClass -Name 'CimClassName'
    if ($className) { return ((ConvertTo-ScheduledTaskSimpleText -Value $className) -replace '^MSFT_Task','') }
  }

  if ($null -ne $Trigger) {
    return (ConvertTo-ScheduledTaskSimpleText -Value ($Trigger.PSObject.TypeNames | Select-Object -First 1))
  }

  return ''
}

function ConvertTo-ScheduledTaskActionFact {
  param([AllowNull()][object]$Action)

  $type = Get-ScheduledTaskActionType -Action $Action
  $execute = ConvertTo-ScheduledTaskSimpleText -Value (Get-ScheduledTaskPropertyValue -InputObject $Action -Name 'Execute')
  $arguments = ConvertTo-ScheduledTaskSimpleText -Value (Get-ScheduledTaskPropertyValue -InputObject $Action -Name 'Arguments')
  $workingDirectory = ConvertTo-ScheduledTaskSimpleText -Value (Get-ScheduledTaskPropertyValue -InputObject $Action -Name 'WorkingDirectory')

  $fingerprintParts = New-Object System.Collections.Generic.List[string]
  [void]$fingerprintParts.Add('type=' + (ConvertTo-ScheduledTaskFingerprintText -Value $type))
  [void]$fingerprintParts.Add('execute=' + (ConvertTo-ScheduledTaskFingerprintText -Value $execute))
  [void]$fingerprintParts.Add('arguments=' + (ConvertTo-ScheduledTaskFingerprintText -Value $arguments))
  [void]$fingerprintParts.Add('workingdirectory=' + (ConvertTo-ScheduledTaskFingerprintText -Value $workingDirectory))

  [pscustomobject]@{
    Type = $type
    Execute = $execute
    Arguments = $arguments
    WorkingDirectory = $workingDirectory
    FingerprintText = ($fingerprintParts -join ';')
  }
}

function ConvertTo-ScheduledTaskTriggerFact {
  param([AllowNull()][object]$Trigger)

  $repetition = Get-ScheduledTaskPropertyValue -InputObject $Trigger -Name 'Repetition'
  $interval = ''
  $duration = ''
  $stopAtDurationEnd = ''
  if ($null -ne $repetition) {
    $interval = ConvertTo-ScheduledTaskSimpleText -Value (Get-ScheduledTaskPropertyValue -InputObject $repetition -Name 'Interval')
    $duration = ConvertTo-ScheduledTaskSimpleText -Value (Get-ScheduledTaskPropertyValue -InputObject $repetition -Name 'Duration')
    $stopAtDurationEnd = ConvertTo-ScheduledTaskSimpleText -Value (Get-ScheduledTaskPropertyValue -InputObject $repetition -Name 'StopAtDurationEnd')
  }

  $enabled = Test-ScheduledTaskTriggerEnabled -Trigger $Trigger
  $type = Get-ScheduledTaskTriggerType -Trigger $Trigger
  $startBoundary = ConvertTo-ScheduledTaskSimpleText -Value (Get-ScheduledTaskPropertyValue -InputObject $Trigger -Name 'StartBoundary')
  $endBoundary = ConvertTo-ScheduledTaskSimpleText -Value (Get-ScheduledTaskPropertyValue -InputObject $Trigger -Name 'EndBoundary')
  $randomDelay = ConvertTo-ScheduledTaskSimpleText -Value (Get-ScheduledTaskPropertyValue -InputObject $Trigger -Name 'RandomDelay')
  $executionTimeLimit = ConvertTo-ScheduledTaskSimpleText -Value (Get-ScheduledTaskPropertyValue -InputObject $Trigger -Name 'ExecutionTimeLimit')
  $daysOfWeek = ConvertTo-ScheduledTaskListText -Value (Get-ScheduledTaskPropertyValue -InputObject $Trigger -Name 'DaysOfWeek')
  $daysOfMonth = ConvertTo-ScheduledTaskListText -Value (Get-ScheduledTaskPropertyValue -InputObject $Trigger -Name 'DaysOfMonth')
  $monthsOfYear = ConvertTo-ScheduledTaskListText -Value (Get-ScheduledTaskPropertyValue -InputObject $Trigger -Name 'MonthsOfYear')

  $fingerprintParts = New-Object System.Collections.Generic.List[string]
  [void]$fingerprintParts.Add('type=' + (ConvertTo-ScheduledTaskFingerprintText -Value $type))
  [void]$fingerprintParts.Add('enabled=' + (ConvertTo-ScheduledTaskFingerprintText -Value $enabled))
  [void]$fingerprintParts.Add('start=' + (ConvertTo-ScheduledTaskFingerprintText -Value $startBoundary))
  [void]$fingerprintParts.Add('end=' + (ConvertTo-ScheduledTaskFingerprintText -Value $endBoundary))
  [void]$fingerprintParts.Add('interval=' + (ConvertTo-ScheduledTaskFingerprintText -Value $interval))
  [void]$fingerprintParts.Add('duration=' + (ConvertTo-ScheduledTaskFingerprintText -Value $duration))
  [void]$fingerprintParts.Add('stopatdurationend=' + (ConvertTo-ScheduledTaskFingerprintText -Value $stopAtDurationEnd))
  [void]$fingerprintParts.Add('randomdelay=' + (ConvertTo-ScheduledTaskFingerprintText -Value $randomDelay))
  [void]$fingerprintParts.Add('executiontimelimit=' + (ConvertTo-ScheduledTaskFingerprintText -Value $executionTimeLimit))
  [void]$fingerprintParts.Add('daysofweek=' + (ConvertTo-ScheduledTaskFingerprintText -Value $daysOfWeek))
  [void]$fingerprintParts.Add('daysofmonth=' + (ConvertTo-ScheduledTaskFingerprintText -Value $daysOfMonth))
  [void]$fingerprintParts.Add('monthsofyear=' + (ConvertTo-ScheduledTaskFingerprintText -Value $monthsOfYear))

  [pscustomobject]@{
    Type = $type
    Enabled = $enabled
    StartBoundary = $startBoundary
    EndBoundary = $endBoundary
    Interval = $interval
    Duration = $duration
    StopAtDurationEnd = $stopAtDurationEnd
    RandomDelay = $randomDelay
    ExecutionTimeLimit = $executionTimeLimit
    DaysOfWeek = $daysOfWeek
    DaysOfMonth = $daysOfMonth
    MonthsOfYear = $monthsOfYear
    FingerprintText = ($fingerprintParts -join ';')
  }
}

function ConvertTo-ScheduledTaskLastResultCode {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) { return $null }

  $text = ConvertTo-ScheduledTaskSimpleText -Value $Value
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  if ($text -eq 'N/A') { return $null }

  if ($text -match '(?i)^0x([0-9a-f]{1,8})$') {
    return [int64]([uint32]::Parse($matches[1], [System.Globalization.NumberStyles]::HexNumber))
  }

  if ($text -match '^-?\d+$') {
    return [int64]$text
  }

  return $null
}

function ConvertTo-ScheduledTaskUInt32 {
  param([AllowNull()][object]$Code)

  if ($null -eq $Code) { return $null }

  try {
    $code64 = [int64]$Code
    $unsigned64 = [uint64]($code64 -band 0xFFFFFFFFFFFFFFFF)
    return [uint32]($unsigned64 -band 0x00000000FFFFFFFF)
  } catch {
    return $null
  }
}

function Get-ScheduledTaskLastResultDescription {
  param(
    [AllowNull()][object]$Code,
    [AllowNull()][object]$UInt32Code,
    [bool]$IsBareWin32
  )

  $mapHresult = @{
    '0x40010004' = 'Process terminated externally'
    '0x80070001' = 'Incorrect function'
    '0x80070002' = 'File or path not found'
    '0x80070003' = 'Path not found'
    '0x80070005' = 'Access denied'
    '0x8007000A' = 'Invalid environment'
    '0x8007000B' = 'Bad EXE format or architecture mismatch'
    '0x80070070' = 'Disk full'
    '0x8007052E' = 'Logon failure (bad username/password)'
    '0x80070533' = 'Account disabled'
    '0x800705B4' = 'Operation timed out'
    '0x800706BA' = 'RPC server unavailable'
    '0x80040121' = 'Storage access denied'
    '0x80040154' = 'COM class not registered'
    '0x800401F5' = 'COM application not found'
    '0x8004130F' = 'Task engine execution error/timeout'
    '0x80004005' = 'Unspecified failure'
    '0x80090020' = 'Cryptographic/DPAPI failure'
    '0xC000006D' = 'Logon failure'
    '0xC000006A' = 'Wrong password'
    '0xC0000064' = 'Unknown user'
    '0xC0000072' = 'Account disabled'
    '0xC0000234' = 'Account locked out'
  }

  $mapWin32Bare = @{
    '1056' = 'Service already running'
    '1326' = 'Logon failure (bad username/password)'
    '1331' = 'Account disabled'
    '1909' = 'Account locked out'
  }

  if ($null -ne $UInt32Code) {
    $uint32Text = [string]$UInt32Code
    $hexText = '0x{0:X8}' -f $UInt32Code

    if ($IsBareWin32 -and $mapWin32Bare.ContainsKey($uint32Text)) {
      return $mapWin32Bare[$uint32Text]
    }

    if ($mapHresult.ContainsKey($hexText)) {
      return $mapHresult[$hexText]
    }
  }

  if ($null -ne $Code) {
    return (Convert-TaskResultCode ([int64]$Code))
  }

  return 'Unknown failure'
}

function Get-ScheduledTaskLastResultAnalysis {
  param([AllowNull()][object]$RawValue)

  $code = ConvertTo-ScheduledTaskLastResultCode -Value $RawValue
  $u32 = ConvertTo-ScheduledTaskUInt32 -Code $code
  $hex = ''
  if ($null -ne $u32) {
    $hex = '0x{0:X8}' -f $u32
  }

  $isBare = $false
  if ($null -ne $u32) {
    $isBare = ($u32 -in @(1056, 1326, 1331, 1909))
  }

  $severity = 'Error'
  if ($isBare) {
    $severity = 'Error'
  }
  elseif ($null -ne $u32) {
    $numberStyle = [System.Globalization.NumberStyles]::HexNumber
    $severityMask = [uint32]::Parse('C0000000', $numberStyle)
    $errorSeverity = [uint32]::Parse('80000000', $numberStyle)
    $warningSeverity = [uint32]::Parse('40000000', $numberStyle)
    $severityBits = ($u32 -band $severityMask)
    if ($severityBits -eq $errorSeverity) {
      $severity = 'Error'
    }
    elseif ($severityBits -eq $warningSeverity) {
      $severity = 'Warning'
    }
    else {
      $severity = 'Success'
    }
  }

  $isInformational = $false
  if ($null -ne $u32) {
    $numberStyle = [System.Globalization.NumberStyles]::HexNumber
    $successCode = [uint32]::Parse('00000000', $numberStyle)
    $successFlag = [uint32]::Parse('10000000', $numberStyle)
    $terminatedExternally = [uint32]::Parse('40010004', $numberStyle)
    $serviceAlreadyRunning = [uint32]1056
    $schedSuccessStart = [uint32]::Parse('00041300', $numberStyle)
    $schedSuccessEnd = [uint32]::Parse('000413FF', $numberStyle)
    if ($u32 -in ([uint32[]]($successCode, $successFlag, $terminatedExternally, $serviceAlreadyRunning))) {
      $isInformational = $true
    }
    elseif ($severity -eq 'Success') {
      $isInformational = $true
    }
    elseif ($u32 -ge $schedSuccessStart -and $u32 -le $schedSuccessEnd) {
      $isInformational = $true
    }
  }

  $description = Get-ScheduledTaskLastResultDescription -Code $code -UInt32Code $u32 -IsBareWin32:$isBare

  [pscustomobject]@{
    RawValue = $RawValue
    Code = $code
    UInt32Code = $u32
    Hex = $hex
    Severity = $severity
    Description = $description
    IsInformational = $isInformational
  }
}

function ConvertTo-ScheduledTaskExceptionInfo {
  param([AllowNull()][object]$ErrorRecord)

  $caughtException = $null
  $exceptionTypeName = 'unknown exception type'
  $exceptionMessage = 'No exception details were available.'
  $hexCode = 'unknown'

  if ($null -ne $ErrorRecord) {
    try { $caughtException = $ErrorRecord.Exception } catch {}
  }

  if ($null -ne $caughtException) {
    try {
      $typeName = $caughtException.GetType().Name
      if (-not [string]::IsNullOrWhiteSpace($typeName)) {
        $exceptionTypeName = $typeName
      }
    } catch {}

    try {
      if (-not [string]::IsNullOrWhiteSpace($caughtException.Message)) {
        $exceptionMessage = $caughtException.Message
      }
    } catch {}

    try {
      $hexCode = '0x{0:X8}' -f ([uint32]$caughtException.HResult)
    } catch {}
  }

  $kind = 'QueryFailure'
  switch ($hexCode) {
    '0x80070002' { $kind = 'DeletedDuringScan' }
    '0x8004130F' { $kind = 'CorruptXml' }
  }

  [pscustomobject]@{
    Kind = $kind
    HexCode = $hexCode
    Message = $exceptionMessage
    TypeName = $exceptionTypeName
  }
}

function Get-ScheduledTaskDefinitionFingerprintText {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)]$Fact)

  $parts = New-Object System.Collections.Generic.List[string]
  [void]$parts.Add('key=' + (ConvertTo-ScheduledTaskFingerprintText -Value $Fact.StableKey))
  [void]$parts.Add('principal=' + (ConvertTo-ScheduledTaskFingerprintText -Value $Fact.PrincipalUserId))
  [void]$parts.Add('runlevel=' + (ConvertTo-ScheduledTaskFingerprintText -Value $Fact.RunLevel))
  [void]$parts.Add('logontype=' + (ConvertTo-ScheduledTaskFingerprintText -Value $Fact.LogonType))
  [void]$parts.Add('hidden=' + (ConvertTo-ScheduledTaskFingerprintText -Value $Fact.Hidden))
  [void]$parts.Add('enabled=' + (ConvertTo-ScheduledTaskFingerprintText -Value $Fact.Enabled))

  foreach ($action in @($Fact.Actions)) {
    [void]$parts.Add('action=' + (ConvertTo-ScheduledTaskFingerprintText -Value $action.FingerprintText))
  }

  foreach ($trigger in @($Fact.Triggers)) {
    [void]$parts.Add('trigger=' + (ConvertTo-ScheduledTaskFingerprintText -Value $trigger.FingerprintText))
  }

  return ($parts -join '|')
}

function Get-ScheduledTaskShortHash {
  param([Parameter(Mandatory=$true)][string]$Text)

  $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
  $algorithm = [Security.Cryptography.HashAlgorithm]::Create('SHA256')
  try {
    $hash = -join ($algorithm.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    return $hash.Substring(0, 16)
  } finally {
    if ($algorithm) { $algorithm.Dispose() }
  }
}

function Get-ScheduledTaskDefinitionFingerprint {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)]$Fact)

  $text = Get-ScheduledTaskDefinitionFingerprintText -Fact $Fact
  return (Get-ScheduledTaskShortHash -Text $text)
}

function Get-ScheduledTaskFacts {
  [CmdletBinding()]
  param([switch]$Refresh)

  if ((-not $Refresh) -and ($null -ne $script:ScheduledTaskFactsCache)) {
    return @($script:ScheduledTaskFactsCache)
  }

  try {
    $tasks = @(Get-ScheduledTask -ErrorAction Stop)
  } catch {
    throw "Failed to enumerate scheduled tasks: $($_.Exception.Message)"
  }

  $facts = New-Object System.Collections.Generic.List[object]
  foreach ($task in $tasks) {
    $taskPath = Normalize-ScheduledTaskPath -TaskPath (Get-ScheduledTaskPropertyValue -InputObject $task -Name 'TaskPath')
    $taskName = ConvertTo-ScheduledTaskSimpleText -Value (Get-ScheduledTaskPropertyValue -InputObject $task -Name 'TaskName')
    $stableKey = Get-ScheduledTaskStableKey -TaskPath $taskPath -TaskName $taskName
    $settings = Get-ScheduledTaskPropertyValue -InputObject $task -Name 'Settings'
    $principal = Get-ScheduledTaskPropertyValue -InputObject $task -Name 'Principal'
    $state = ConvertTo-ScheduledTaskSimpleText -Value (Get-ScheduledTaskPropertyValue -InputObject $task -Name 'State')

    $settingsEnabled = Get-ScheduledTaskPropertyValue -InputObject $settings -Name 'Enabled'
    if ($null -ne $settingsEnabled) {
      $enabled = [bool]$settingsEnabled
    } else {
      $enabled = ($state -ne 'Disabled')
    }

    $hidden = $false
    $hiddenValue = Get-ScheduledTaskPropertyValue -InputObject $settings -Name 'Hidden'
    if ($null -ne $hiddenValue) { $hidden = [bool]$hiddenValue }

    $actions = New-Object System.Collections.Generic.List[object]
    foreach ($action in @((Get-ScheduledTaskPropertyValue -InputObject $task -Name 'Actions'))) {
      if ($null -ne $action) {
        [void]$actions.Add((ConvertTo-ScheduledTaskActionFact -Action $action))
      }
    }

    $triggers = New-Object System.Collections.Generic.List[object]
    $hasEnabledTrigger = $false
    foreach ($trigger in @((Get-ScheduledTaskPropertyValue -InputObject $task -Name 'Triggers'))) {
      if ($null -eq $trigger) { continue }
      $triggerFact = ConvertTo-ScheduledTaskTriggerFact -Trigger $trigger
      [void]$triggers.Add($triggerFact)
      if ($triggerFact.Enabled) { $hasEnabledTrigger = $true }
    }

    $info = $null
    $infoError = $null
    try {
      $info = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
    } catch {
      $infoError = ConvertTo-ScheduledTaskExceptionInfo -ErrorRecord $_
    }

    $description = ''
    $xmlError = $null
    try {
      $xmlText = Export-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
      if (-not [string]::IsNullOrWhiteSpace($xmlText)) {
        $xml = [xml]$xmlText
        $description = ConvertTo-ScheduledTaskSimpleText -Value $xml.Task.RegistrationInfo.Description
      }
    } catch {
      $xmlError = ConvertTo-ScheduledTaskExceptionInfo -ErrorRecord $_
    }

    $lastTaskResult = $null
    if ($null -ne $info) {
      $lastTaskResult = Get-ScheduledTaskPropertyValue -InputObject $info -Name 'LastTaskResult'
    }

    $lastResultAnalysis = Get-ScheduledTaskLastResultAnalysis -RawValue $lastTaskResult
    $lastRunTime = $null
    $nextRunTime = $null
    $numberOfMissedRuns = 0
    if ($null -ne $info) {
      $lastRunTime = Get-ScheduledTaskPropertyValue -InputObject $info -Name 'LastRunTime'
      $nextRunTime = Get-ScheduledTaskPropertyValue -InputObject $info -Name 'NextRunTime'
      $missedRunsValue = Get-ScheduledTaskPropertyValue -InputObject $info -Name 'NumberOfMissedRuns'
      if ($null -ne $missedRunsValue) {
        try { $numberOfMissedRuns = [int]$missedRunsValue } catch { $numberOfMissedRuns = 0 }
      }
    }

    $author = ConvertTo-ScheduledTaskSimpleText -Value (Get-ScheduledTaskPropertyValue -InputObject $task -Name 'Author')
    $principalUserId = ConvertTo-ScheduledTaskSimpleText -Value (Get-ScheduledTaskPropertyValue -InputObject $principal -Name 'UserId')
    $principalDisplayName = ConvertTo-ScheduledTaskSimpleText -Value (Get-ScheduledTaskPropertyValue -InputObject $principal -Name 'DisplayName')
    $runLevel = ConvertTo-ScheduledTaskSimpleText -Value (Get-ScheduledTaskPropertyValue -InputObject $principal -Name 'RunLevel')
    $logonType = ConvertTo-ScheduledTaskSimpleText -Value (Get-ScheduledTaskPropertyValue -InputObject $principal -Name 'LogonType')
    $actionFacts = @($actions.ToArray())
    $triggerFacts = @($triggers.ToArray())

    $fact = [pscustomobject]@{
      TaskPath = $taskPath
      TaskName = $taskName
      StableKey = $stableKey
      State = $state
      Enabled = $enabled
      Hidden = $hidden
      Author = $author
      Description = $description
      PrincipalUserId = $principalUserId
      PrincipalDisplayName = $principalDisplayName
      RunLevel = $runLevel
      LogonType = $logonType
      Actions = $actionFacts
      Triggers = $triggerFacts
      HasEnabledTrigger = $hasEnabledTrigger
      LastRunTime = $lastRunTime
      NextRunTime = $nextRunTime
      NumberOfMissedRuns = $numberOfMissedRuns
      LastTaskResult = $lastTaskResult
      LastResultCode = $lastResultAnalysis.Code
      LastResultHex = $lastResultAnalysis.Hex
      LastResultSeverity = $lastResultAnalysis.Severity
      LastResultDescription = $lastResultAnalysis.Description
      LastResultIsInformational = $lastResultAnalysis.IsInformational
      InfoQueryFailed = ($null -ne $infoError)
      InfoErrorKind = if ($infoError) { $infoError.Kind } else { '' }
      InfoErrorHexCode = if ($infoError) { $infoError.HexCode } else { '' }
      InfoErrorMessage = if ($infoError) { $infoError.Message } else { '' }
      XmlQueryFailed = ($null -ne $xmlError)
      XmlErrorKind = if ($xmlError) { $xmlError.Kind } else { '' }
      XmlErrorHexCode = if ($xmlError) { $xmlError.HexCode } else { '' }
      XmlErrorMessage = if ($xmlError) { $xmlError.Message } else { '' }
      IsPrivileged = (Test-ScheduledTaskPrincipalPrivileged -PrincipalUserId $principalUserId -RunLevel $runLevel)
      IsSystemPrincipal = (Test-ScheduledTaskSystemPrincipal -PrincipalUserId $principalUserId)
      IsMicrosoftBuiltIn = (Test-ScheduledTaskBuiltInMicrosoft -TaskPath $taskPath -Author $author)
      PolicyFingerprint = ''
    }

    $fact.PolicyFingerprint = Get-ScheduledTaskDefinitionFingerprint -Fact $fact
    [void]$facts.Add($fact)
  }

  $script:ScheduledTaskFactsCache = @($facts.ToArray())
  return @($script:ScheduledTaskFactsCache)
}

function Get-ScheduledTaskDeepInfo {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$TaskName,
    [string]$TaskPath
  )

  $targetKey = Get-ScheduledTaskStableKey -TaskPath $TaskPath -TaskName $TaskName
  $facts = @(Get-ScheduledTaskFacts)
  foreach ($fact in $facts) {
    if ($fact.StableKey -eq $targetKey -or ((-not $TaskPath) -and $fact.TaskName -eq $TaskName)) {
      [pscustomobject]@{
        PathPlusName = $fact.StableKey
        State = $fact.State
        Enabled = $fact.Enabled
        Actions = @($fact.Actions)
        LastTaskResult = "$($fact.LastTaskResult); $($fact.LastResultDescription)"
        Description = $fact.Description
        Author = $fact.Author
        RunAcntUserId = "$($fact.PrincipalUserId) $($fact.PrincipalDisplayName)".Trim()
        RunLevel = $fact.RunLevel
        RunLogonType = $fact.LogonType
        LastRunTime = $fact.LastRunTime
        NextRunTime = $fact.NextRunTime
        NumberOfMissedRuns = $fact.NumberOfMissedRuns
        Triggers = @($fact.Triggers)
      }
    }
  }
}

function Test-ScheduledTaskPathMatchesAnyRegex {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [AllowNull()][string[]]$Patterns
  )

  foreach ($pattern in @($Patterns)) {
    if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
    if ($Path -match $pattern) { return $true }
  }

  return $false
}

function Test-ScheduledTaskNameMatchesAnyPattern {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [AllowNull()][string[]]$Patterns
  )

  foreach ($pattern in @($Patterns)) {
    if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
    if ($Name -like $pattern) { return $true }
  }

  return $false
}

function Test-ScheduledTaskRequired {
  param(
    [Parameter(Mandatory=$true)]$Fact,
    [AllowNull()][string[]]$MustBeEnabled
  )

  foreach ($pattern in @($MustBeEnabled)) {
    if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
    if ($Fact.StableKey -eq $pattern) { return $true }
    if ($Fact.StableKey -match $pattern) { return $true }
  }

  return $false
}

function Test-ScheduledTaskIgnoredForOperationalChecks {
  param(
    [Parameter(Mandatory=$true)]$Fact,
    [AllowNull()][string[]]$NamePatterns,
    [AllowNull()][string[]]$PathRegex
  )

  if (Test-ScheduledTaskNameMatchesAnyPattern -Name $Fact.TaskName -Patterns $NamePatterns) {
    return $true
  }

  if (Test-ScheduledTaskPathMatchesAnyRegex -Path $Fact.StableKey -Patterns $PathRegex) {
    return $true
  }

  return $false
}

function Get-ScheduledTaskOperationalSeverity {
  param(
    [Parameter(Mandatory=$true)]$Fact,
    [Parameter(Mandatory=$true)][string]$IssueType,
    [bool]$Required
  )

  if ($Required) { return 'FAILURE' }

  if ($IssueType -eq 'LastResult') {
    if ($Fact.IsPrivileged -and $Fact.LastResultSeverity -eq 'Error') { return 'FAILURE' }
    if ($Fact.IsPrivileged) { return 'WARNING' }
    if ($Fact.LastResultSeverity -eq 'Error') { return 'WARNING' }
    return 'NOTICE'
  }

  if ($IssueType -eq 'ManyMissedRuns') { return 'WARNING' }
  if ($IssueType -eq 'FewMissedRuns') { return 'NOTICE' }
  if ($IssueType -eq 'QueryFailure') { return 'FAILURE' }
  if ($IssueType -eq 'CorruptXml') { return 'WARNING' }
  if ($Fact.IsPrivileged) { return 'WARNING' }

  return 'NOTICE'
}

function Test-ScheduledTaskLastResultReportable {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]$Fact,
    [bool]$Required,
    [bool]$IncludeBuiltIn
  )

  if ($Required) { return $true }
  if ($IncludeBuiltIn) { return $true }
  if (-not $Fact.IsMicrosoftBuiltIn) { return $true }

  return ($Fact.NumberOfMissedRuns -ge 5)
}

function Format-ScheduledTaskFactDetails {
  param([Parameter(Mandatory=$true)]$Fact)

  $lines = New-Object System.Collections.Generic.List[string]
  [void]$lines.Add('Task: ' + $Fact.StableKey)
  [void]$lines.Add('State: ' + $Fact.State)
  [void]$lines.Add('Enabled: ' + $Fact.Enabled)
  [void]$lines.Add('Hidden: ' + $Fact.Hidden)
  if ($Fact.Author) { [void]$lines.Add('Author: ' + $Fact.Author) }
  if ($Fact.PrincipalUserId) { [void]$lines.Add('Run as: ' + $Fact.PrincipalUserId) }
  if ($Fact.RunLevel) { [void]$lines.Add('Run level: ' + $Fact.RunLevel) }
  if ($Fact.LogonType) { [void]$lines.Add('Logon type: ' + $Fact.LogonType) }
  if ($Fact.Description) { [void]$lines.Add('Description: ' + $Fact.Description) }
  if ($null -ne $Fact.LastRunTime) { [void]$lines.Add('Last run time: ' + $Fact.LastRunTime) }
  if ($null -ne $Fact.NextRunTime) { [void]$lines.Add('Next run time: ' + $Fact.NextRunTime) }
  [void]$lines.Add('Missed runs: ' + $Fact.NumberOfMissedRuns)
  if ($Fact.LastResultHex) {
    [void]$lines.Add('Last result: ' + $Fact.LastResultHex + ' (' + $Fact.LastResultDescription + ')')
  }

  foreach ($action in @($Fact.Actions)) {
    $actionText = 'Action: ' + $action.Type
    if ($action.Execute) { $actionText = $actionText + ' Execute=' + $action.Execute }
    if ($action.Arguments) { $actionText = $actionText + ' Arguments=' + $action.Arguments }
    if ($action.WorkingDirectory) { $actionText = $actionText + ' WorkingDirectory=' + $action.WorkingDirectory }
    [void]$lines.Add($actionText)
  }

  foreach ($trigger in @($Fact.Triggers)) {
    $triggerText = 'Trigger: ' + $trigger.Type + ' Enabled=' + $trigger.Enabled
    if ($trigger.StartBoundary) { $triggerText = $triggerText + ' Start=' + $trigger.StartBoundary }
    if ($trigger.EndBoundary) { $triggerText = $triggerText + ' End=' + $trigger.EndBoundary }
    if ($trigger.Interval) { $triggerText = $triggerText + ' Interval=' + $trigger.Interval }
    [void]$lines.Add($triggerText)
  }

  return ($lines -join "`n")
}

function Format-ScheduledTaskDefinitionDetails {
  param([Parameter(Mandatory=$true)]$Fact)

  $lines = New-Object System.Collections.Generic.List[string]
  [void]$lines.Add('Task: ' + $Fact.StableKey)
  [void]$lines.Add('Fingerprint: ' + $Fact.PolicyFingerprint)
  [void]$lines.Add('Enabled: ' + $Fact.Enabled)
  [void]$lines.Add('Hidden: ' + $Fact.Hidden)
  if ($Fact.Author) { [void]$lines.Add('Author: ' + $Fact.Author) }
  if ($Fact.PrincipalUserId) { [void]$lines.Add('Run as: ' + $Fact.PrincipalUserId) }
  if ($Fact.RunLevel) { [void]$lines.Add('Run level: ' + $Fact.RunLevel) }
  if ($Fact.LogonType) { [void]$lines.Add('Logon type: ' + $Fact.LogonType) }
  if ($Fact.Description) { [void]$lines.Add('Description: ' + $Fact.Description) }

  foreach ($action in @($Fact.Actions)) {
    $actionText = 'Action: ' + $action.Type
    if ($action.Execute) { $actionText = $actionText + ' Execute=' + $action.Execute }
    if ($action.Arguments) { $actionText = $actionText + ' Arguments=' + $action.Arguments }
    if ($action.WorkingDirectory) { $actionText = $actionText + ' WorkingDirectory=' + $action.WorkingDirectory }
    [void]$lines.Add($actionText)
  }

  foreach ($trigger in @($Fact.Triggers)) {
    $triggerText = 'Trigger: ' + $trigger.Type + ' Enabled=' + $trigger.Enabled
    if ($trigger.StartBoundary) { $triggerText = $triggerText + ' Start=' + $trigger.StartBoundary }
    if ($trigger.EndBoundary) { $triggerText = $triggerText + ' End=' + $trigger.EndBoundary }
    if ($trigger.Interval) { $triggerText = $triggerText + ' Interval=' + $trigger.Interval }
    [void]$lines.Add($triggerText)
  }

  return ($lines -join "`n")
}

function HealthTest-ScheduledTasks {
<#
Description: Reviews scheduled tasks for failed results, disabled required tasks, missed runs, stale runs, and unreadable metadata.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-ScheduledTask, Get-ScheduledTaskInfo, Export-ScheduledTask.
#>
  [CmdletBinding()]
  param(
    [string[]]$MustBeEnabled = @(),
    [string[]]$Ignore = $(Get-ScheduledTaskDefaultPathIgnoreRegex),
    [string[]]$IgnoreTaskName = $(Get-ScheduledTaskDefaultNameIgnorePatterns),
    [switch]$IncludeHidden,
    [switch]$IncludeBuiltIn,
    [int]$StaleDays = 30
  )

  $hadIssue = $false

  try {
    $facts = @(Get-ScheduledTaskFacts)
  } catch {
    Write-Warning "[FAILURE] Failed to collect scheduled task facts: $($_.Exception.Message)"
    return
  }

  foreach ($fact in ($facts | Sort-Object StableKey)) {
    $isRequired = Test-ScheduledTaskRequired -Fact $fact -MustBeEnabled $MustBeEnabled
    $ignored = Test-ScheduledTaskIgnoredForOperationalChecks -Fact $fact -NamePatterns $IgnoreTaskName -PathRegex $Ignore

    if ((-not $IncludeHidden) -and $fact.Hidden -and (-not $isRequired)) {
      continue
    }

    if ($fact.InfoQueryFailed) {
      $hadIssue = $true
      if ($fact.InfoErrorKind -eq 'DeletedDuringScan') {
        Write-Warning "[NOTICE] Task '$($fact.StableKey)' was deleted while scheduled task metadata was being collected."
      }
      elseif ($fact.InfoErrorKind -eq 'CorruptXml') {
        Write-Warning "[WARNING] Task XML for '$($fact.StableKey)' is corrupted.`n$(Format-ScheduledTaskFactDetails -Fact $fact)"
      }
      else {
        Write-Warning "[FAILURE] Task '$($fact.StableKey)' failed Get-ScheduledTaskInfo with $($fact.InfoErrorHexCode) ($($fact.InfoErrorMessage)).`n$(Format-ScheduledTaskFactDetails -Fact $fact)"
      }
      continue
    }

    if ($fact.XmlQueryFailed) {
      $hadIssue = $true
      $level = Get-ScheduledTaskOperationalSeverity -Fact $fact -IssueType 'CorruptXml' -Required:$isRequired
      Write-Warning "[$level] Task XML for '$($fact.StableKey)' could not be read: $($fact.XmlErrorHexCode) ($($fact.XmlErrorMessage)).`n$(Format-ScheduledTaskFactDetails -Fact $fact)"
      continue
    }

    if ($ignored -and (-not $isRequired)) {
      continue
    }

    $isThirdPartyOrRequired = ((-not $fact.IsMicrosoftBuiltIn) -or $IncludeBuiltIn -or $isRequired)

    if ((-not $fact.Enabled) -or ($fact.State -eq 'Disabled')) {
      if ($isThirdPartyOrRequired) {
        $hadIssue = $true
        $level = Get-ScheduledTaskOperationalSeverity -Fact $fact -IssueType 'Disabled' -Required:$isRequired
        if ($isRequired -and $fact.IsSystemPrincipal) {
          Write-Warning "[$level] Required SYSTEM scheduled task is disabled: $($fact.StableKey)`n$(Format-ScheduledTaskFactDetails -Fact $fact)"
        } else {
          Write-Warning "[$level] Scheduled task is disabled: $($fact.StableKey)`n$(Format-ScheduledTaskFactDetails -Fact $fact)"
        }
      }
      continue
    }

    if (($null -ne $fact.LastResultCode) -and (-not $fact.LastResultIsInformational)) {
      if (Test-ScheduledTaskLastResultReportable -Fact $fact -Required:$isRequired -IncludeBuiltIn:$IncludeBuiltIn) {
        $hadIssue = $true
        $level = Get-ScheduledTaskOperationalSeverity -Fact $fact -IssueType 'LastResult' -Required:$isRequired
        Write-Warning "[$level] Scheduled task '$($fact.StableKey)' terminated with LastTaskResult=$($fact.LastResultHex) ($($fact.LastResultDescription)).`n$(Format-ScheduledTaskFactDetails -Fact $fact)"
      }
    }

    if ($fact.NumberOfMissedRuns -gt 0 -and $isThirdPartyOrRequired) {
      $hadIssue = $true
      if ($fact.NumberOfMissedRuns -ge 5) {
        $level = Get-ScheduledTaskOperationalSeverity -Fact $fact -IssueType 'ManyMissedRuns' -Required:$isRequired
      } else {
        $level = Get-ScheduledTaskOperationalSeverity -Fact $fact -IssueType 'FewMissedRuns' -Required:$isRequired
      }
      Write-Warning "[$level] Scheduled task missed $($fact.NumberOfMissedRuns) runs: $($fact.StableKey)`n$(Format-ScheduledTaskFactDetails -Fact $fact)"
    }

    if ($StaleDays -gt 0 -and $fact.HasEnabledTrigger -and $isThirdPartyOrRequired) {
      $lastRun = $fact.LastRunTime
      $isStale = $false
      $lastRunText = 'never'
      if ($null -eq $lastRun -or $lastRun -eq [datetime]::MinValue) {
        $isStale = $true
      } else {
        $lastRunDate = [datetime]$lastRun
        $lastRunText = $lastRunDate.ToString('yyyy-MM-dd')
        if (((Get-Date) - $lastRunDate).TotalDays -gt $StaleDays) {
          $isStale = $true
        }
      }

      if ($isStale) {
        $hadIssue = $true
        $level = Get-ScheduledTaskOperationalSeverity -Fact $fact -IssueType 'Stale' -Required:$isRequired
        Write-Warning "[$level] Scheduled task appears stale: $($fact.StableKey) LastRun=$lastRunText (> $StaleDays days or never).`n$(Format-ScheduledTaskFactDetails -Fact $fact)"
      }
    }
  }

  if (-not $hadIssue) {
    Write-Warning "[PASS] Scheduled tasks healthy"
  }
}

function HealthTest-ListScheduledTasks {
<#
Description: Lists scheduled task definitions with fingerprints for actions, triggers, identity, privilege, and enabled state.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Tags: Policy
Uses: Get-ScheduledTask, Get-ScheduledTaskInfo, Export-ScheduledTask.

Policy identity: stable task key plus fingerprint of normalized actions, principal, run level, logon type, triggers, hidden state, and enabled state. Last run time, next run time, missed runs, and last result are not included.
Policy baseline version: 2
#>
  [CmdletBinding()]
  param()

  try {
    $facts = @(Get-ScheduledTaskFacts)
  } catch {
    Write-Warning "[FAILURE] Failed to collect scheduled task definitions: $($_.Exception.Message)"
    return
  }

  $seen = 0
  foreach ($fact in ($facts | Sort-Object StableKey)) {
    $seen += 1
    $level = 'NOTICE'
    if ($fact.IsPrivileged) { $level = 'WARNING' }

    Write-Warning "[$level] Found scheduled task: $($fact.StableKey) fingerprint=$($fact.PolicyFingerprint)`n$(Format-ScheduledTaskDefinitionDetails -Fact $fact)"
  }

  if ($seen -eq 0) {
    Write-Warning "[PASS] No scheduled tasks discovered."
  }
}
