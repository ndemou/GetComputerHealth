# HostRequirement: All

if (-not (Get-Command -Name 'Get-ServiceVendors' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helper-regarding-service-and-executable-resolution.ps1')
}

function HealthTest-Services {
<#
Description: Reviews service operational health, including auto-start services that are not running, abnormal service exit codes, and broken service payload paths.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Tags: Essential
Uses: Win32_Service, Get-ServiceVendors.
#>
  $hadIssue = $false

  function Get-ServiceExitCodeMessage {
      param([int]$ExitCode)

      $known = $null
      switch ($ExitCode) {
          0    { $known = 'The operation completed successfully.'; break }
          1077 { $known = 'No attempts to start the service have been made since the last boot.'; break }
          1    { $known = 'Incorrect function.'; break }
          2    { $known = 'The system cannot find the file specified.'; break }
          3    { $known = 'The system cannot find the path specified.'; break }
          5    { $known = 'Access is denied.'; break }
          13   { $known = 'The data is invalid.'; break }
          14   { $known = 'Not enough storage is available to complete this operation.'; break }
          87   { $known = 'The parameter is incorrect.'; break }
          1053 { $known = 'The service did not respond to the start or control request in a timely fashion.'; break }
          1058 { $known = 'The service cannot be started because it is disabled or has no enabled devices associated with it.'; break }
          1067 { $known = 'The process terminated unexpectedly.'; break }
          1068 { $known = 'A dependency service or group failed to start.'; break }
          1075 { $known = 'The dependency service does not exist or has been marked for deletion.'; break }
          1114 { $known = 'A dynamic link library (DLL) initialization routine failed.'; break }
      }

      if ($known) { return $known }

      try {
          $msg = (New-Object ComponentModel.Win32Exception ([int]$ExitCode)).Message
          if (-not [string]::IsNullOrWhiteSpace($msg)) {
              return $msg
          }
      } catch {}

      "Unknown Windows service exit code."
  }

    <#
    SERVICES_THAT_ARE_OFTEN_STOPPED

    edgeupdate: Microsoft Edge Update Service
    InventorySvc: Inventory and Compatibility Appraisal service
    MapsBroker: Downloaded Maps Manager
    sppsvc: Software Protection
    gupdate: Google Update Service
    dmwappushservice: Device Management Wireless Application Protocol (WAP) Push message Routing Service
    gpsvc: Group Policy Client
    AppXSvc: AppX Deployment Service (for installing/updating .appx Microsoft Store apps)
    TrustedInstaller: windows updates service
    #>
    $SERVICES_THAT_ARE_OFTEN_STOPPED=@('edgeupdate', 'InventorySvc', 'MapsBroker', 'sppsvc',
        'gupdate', 'dmwappushservice', 'RemoteRegistry', 'StateRepository', 'gpsvc', 'AppXSvc',
        'TrustedInstaller')
    # The regex below is more powerful but more difficult to update correctly.
    $SERVICES_THAT_ARE_OFTEN_STOPPED_REGEX = '^(GoogleUpdaterInternalService[0-9.]+|GoogleUpdaterService[0-9.]+)$'

    $not_started_services = (Get-CimInstance Win32_Service -Filter "StartMode='Auto' and State!='Running'" |
        select Name,DisplayName,State,StartMode,DelayedAutoStart,ExitCode)

    if ($not_started_services) {
        $not_started_services | %{
            # TODO: consider exitcode 1077 practicly equivalent to 0 (no problem)
            # 1077 = No attempts to start the service have been made since the last boot.
            $exitCodeMeaning = Get-ServiceExitCodeMessage $_.ExitCode
            $serviceInListOfOftenStoped = (
                ($_.name -in $SERVICES_THAT_ARE_OFTEN_STOPPED) -or
                ($_.name -match $SERVICES_THAT_ARE_OFTEN_STOPPED_REGEX)
            )
            if ($serviceInListOfOftenStoped -and ($_.ExitCode -in (0,1077))) {
                    $hadIssue = $true
                    Write-Warning "[info] This service is stoped but its last execution terminated NORMALY and it's one of the services that are often stopped: Service '$($_.Name)', StartMode=$($_.StartMode), DelayedAutoStart=$($_.DelayedAutoStart), last ExitCode=$($_.ExitCode)($exitCodeMeaning)."} else {
                if ($_.ExitCode  -in (0,1077)) {
                    # Use NOTICE here, even though it is noisier than INFO, because a service
                    # that stays stopped after restart should remain visible instead of being suppressed.
                    $hadIssue = $true
                    Write-Warning "[NOTICE] Service '$($_.Name)' which is set to automatically start, is not running, but its last execution terminated with ExitCode=$($_.ExitCode)($exitCodeMeaning).`nDisplay name: $($_.DisplayName), StartMode=$($_.StartMode), DelayedAutoStart=$($_.DelayedAutoStart), last ExitCode=$($_.ExitCode)($exitCodeMeaning)."
                } else {
                    $hadIssue = $true
                    Write-Warning "[FAILURE] Service '$($_.Name)' which is set to automatically start is not running; alarmingly its last execution terminated abnormally: ExitCode=$($_.ExitCode)($exitCodeMeaning).`nDisplay name: $($_.DisplayName), StartMode=$($_.StartMode), DelayedAutoStart=$($_.DelayedAutoStart), last ExitCode=$($_.ExitCode)($exitCodeMeaning)."
                }
            }
        }
    }

    try {
        $services = @(Get-ServiceVendors)
        foreach ($service in $services) {
            if ([string]::IsNullOrWhiteSpace([string]$service.ExceptionsThrown)) { continue }

            $hadIssue = $true
            Write-Warning "[FAILURE] Service '$($service.ServiceName)' has a broken or unresolved executable/payload path.`nError(s): $($service.ExceptionsThrown)"
        }
    } catch {
        $hadIssue = $true
        Write-Warning "[FAILURE] Could not inspect service executable/payload paths: $($_.Exception.Message)"
    }

    if (-not $hadIssue) {
        Write-Warning "[PASS] Services healthy: all auto-start services are running and service payload paths resolved."
    }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-Services
}
