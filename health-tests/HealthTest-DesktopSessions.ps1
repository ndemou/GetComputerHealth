<#
Standalone file for HealthTest-DesktopSessions.
Generated during the repo-wide health-test split.
#>
# HostRequirement: All

function Get-LiveSessionInfo {
<#
.SYNOPSIS
Gets live/current Desktop Sessions details.

.OUTPUTS
Produces one psCustomObject for each matching session:
  ComputerName      : Computer that was queried.
  SessionId         : Session ID.
  State             : Current session state.
  SessionName       : Session name reported by the host.
  UserName          : Session user name, if available.
  Domain            : Session domain, if available.
  UserPrincipal     : Domain\user when both are known; otherwise user.
  ClientName        : Client computer name, if available.
  ClientAddress     : Client IP address, if available.
  Protocol          : Connection protocol description, if available.
  ClientBuild       : Client build number, if available.
  ClientDisplay     : Client display summary, if available.
  ClientDirectory   : Client install path, if available.
  LogonTime         : Session logon time, if available.
  ConnectTime       : Last connect time, if available.
  DisconnectTime    : Last disconnect time, if available.
  LastInputTime     : Last observed user input time, if available.
  SnapshotTime      : Time of the timing snapshot, if available.
  IdleTime          : Time since last input, if available.
  SessionAge        : Time since logon, if available.
  ConnectedDuration : Time since connect for connected sessions, if
                      available.
  DisconnectedTime  : Time since disconnect for disconnected sessions,
                      if available.
  ProcessCount      : Number of processes observed in the session.
  CPUPercent        : Approximate percentage of total logical CPU
                      capacity used by the session over the sample.
  MemoryMB          : Approximate private working-set memory in MiB
                      attributed to the session.
  IO_MBps           : Approximate combined process read/write
                      throughput in MiB per second over the sample.

.DESCRIPTION
Queries the current session table of the target computer and returns
zero or more matching sessions.

Intended for live state:
who owns the session now, whether it is active or disconnected, where
the client came from, how long it has been idle or disconnected and
what CPU, Memory, IO-Bandwidth it consumes.

By default, CPU and process-I/O information are sampled for about one
second before results are returned. Memory is gathered near the end of
that sample.

CPU and process-I/O usage are measured over the period specified by
SampleSeconds. Consequently, the function waits for that period before
returning results (see -FastDontSampleProcessCpuIo).

Memory usage is captured near the end of the sampling period.

The function is intended to provide session-level information similar to
the Users tab in Windows Task Manager, but it does not use Task Manager's
internal data-collection mechanisms.

The returned measurements are approximations based on public Windows APIs
and performance counters. They are suitable for monitoring and comparison,
but should not be treated as exact reproductions of Task Manager's values.

If SessionId is omitted, all sessions are considered. If SessionId is
specified, only matching sessions are returned. Unknown session IDs
result in no output for those IDs.

A terminating error is raised if the target cannot be opened for
session queries or if session enumeration fails.

.PARAMETER ComputerName
Target computer to query.

Use a remote computer name to query that host. Values that refer to
the local computer are treated as a local query.

.PARAMETER SessionId
Limits results to the specified session IDs.

When set, only sessions whose ID is in this list are returned;
otherwise all sessions are returned.

.PARAMETER FastDontSampleProcessCpuIo
Skips the CPU and process-I/O sampling step.

When set, ProcessCount, CPUPercent, and IO_MBps are returned as null.
MemoryMB is still populated.
#>
  [CmdletBinding()]
  param(
    [string]$ComputerName = $env:COMPUTERNAME,
    [int[]]$SessionId,
    [switch]$FastDontSampleProcessCpuIo
  )

  if (-not ('Toula.WtsEx.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace Toula.WtsEx
{
    public enum WTS_CONNECTSTATE_CLASS
    {
        WTSActive,
        WTSConnected,
        WTSConnectQuery,
        WTSShadow,
        WTSDisconnected,
        WTSIdle,
        WTSListen,
        WTSReset,
        WTSDown,
        WTSInit
    }

    public enum WTS_INFO_CLASS
    {
        WTSInitialProgram,
        WTSApplicationName,
        WTSWorkingDirectory,
        WTSOEMId,
        WTSSessionId,
        WTSUserName,
        WTSWinStationName,
        WTSDomainName,
        WTSConnectState,
        WTSClientBuildNumber,
        WTSClientName,
        WTSClientDirectory,
        WTSClientProductId,
        WTSClientHardwareId,
        WTSClientAddress,
        WTSClientDisplay,
        WTSClientProtocolType,
        WTSIdleTime,
        WTSLogonTime,
        WTSIncomingBytes,
        WTSOutgoingBytes,
        WTSIncomingFrames,
        WTSOutgoingFrames,
        WTSClientInfo,
        WTSSessionInfo,
        WTSSessionInfoEx,
        WTSConfigInfo,
        WTSValidationInfo,
        WTSSessionAddressV4,
        WTSIsRemoteSession
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WTS_SESSION_INFO
    {
        public Int32 SessionID;
        public IntPtr pWinStationName;
        public WTS_CONNECTSTATE_CLASS State;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WTS_CLIENT_ADDRESS
    {
        public Int32 AddressFamily;

        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 20)]
        public byte[] Address;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WTS_CLIENT_DISPLAY
    {
        public Int32 HorizontalResolution;
        public Int32 VerticalResolution;
        public Int32 ColorDepth;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WTSINFOEX_LEVEL1_W
    {
        public UInt32 SessionId;
        public WTS_CONNECTSTATE_CLASS SessionState;
        public Int32 SessionFlags;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 33)]
        public string WinStationName;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 21)]
        public string UserName;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 18)]
        public string DomainName;

        public Int64 LogonTime;
        public Int64 ConnectTime;
        public Int64 DisconnectTime;
        public Int64 LastInputTime;
        public Int64 CurrentTime;
        public UInt32 IncomingBytes;
        public UInt32 OutgoingBytes;
        public UInt32 IncomingFrames;
        public UInt32 OutgoingFrames;
        public UInt32 IncomingCompressedBytes;
        public UInt32 OutgoingCompressedBytes;
    }

    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
    public struct WTSINFOEX_LEVEL_W
    {
        [FieldOffset(0)]
        public WTSINFOEX_LEVEL1_W WTSInfoExLevel1;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WTSINFOEXW
    {
        public UInt32 Level;
        public WTSINFOEX_LEVEL_W Data;
    }

    public static class NativeMethods
    {
        [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "WTSOpenServerW")]
        public static extern IntPtr WTSOpenServer(string pServerName);

        [DllImport("wtsapi32.dll", SetLastError = true)]
        public static extern void WTSCloseServer(IntPtr hServer);

        [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "WTSEnumerateSessionsW")]
        public static extern bool WTSEnumerateSessions(
            IntPtr hServer,
            int Reserved,
            int Version,
            out IntPtr ppSessionInfo,
            out int pCount
        );

        [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "WTSQuerySessionInformationW")]
        public static extern bool WTSQuerySessionInformation(
            IntPtr hServer,
            int sessionId,
            WTS_INFO_CLASS wtsInfoClass,
            out IntPtr ppBuffer,
            out int pBytesReturned
        );

        [DllImport("wtsapi32.dll")]
        public static extern void WTSFreeMemory(IntPtr pMemory);
    }
}
"@
  }

  function Get-WtsServerHandle {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or
        $Name -eq '.' -or
        $Name -eq 'localhost' -or
        $Name -ieq $env:COMPUTERNAME) {
      return [IntPtr]::Zero
    }
    $handle = [Toula.WtsEx.NativeMethods]::WTSOpenServer($Name)
    if ($handle -eq [IntPtr]::Zero) {
      throw "Failed to open WTS server handle for '$Name'."
    }
    return $handle
  }

  function Convert-PtrToStringUni {
    param([IntPtr]$Ptr)
    if ($Ptr -eq [IntPtr]::Zero) { return $null }
    [Runtime.InteropServices.Marshal]::PtrToStringUni($Ptr)
  }

  function Convert-WtsFileTimeToLocal {
    param([long]$Value)
    if ($Value -le 0) { return $null }
    try { [DateTime]::FromFileTimeUtc($Value).ToLocalTime() } catch { $null }
  }

  function Get-WtsString {
    param(
      [IntPtr]$Server,
      [int]$Id,
      [Toula.WtsEx.WTS_INFO_CLASS]$InfoClass
    )
    $buf = [IntPtr]::Zero
    $bytes = 0
    try {
      if (-not [Toula.WtsEx.NativeMethods]::WTSQuerySessionInformation($Server, $Id, $InfoClass, [ref]$buf, [ref]$bytes)) {
        return $null
      }
      if ($buf -eq [IntPtr]::Zero -or $bytes -le 1) {
        return $null
      }
      $s = [Runtime.InteropServices.Marshal]::PtrToStringUni($buf)
      if ([string]::IsNullOrWhiteSpace($s)) { return $null }
      $s
    }
    finally {
      if ($buf -ne [IntPtr]::Zero) {
        [Toula.WtsEx.NativeMethods]::WTSFreeMemory($buf)
      }
    }
  }

  function Get-WtsUInt16 {
    param(
      [IntPtr]$Server,
      [int]$Id,
      [Toula.WtsEx.WTS_INFO_CLASS]$InfoClass
    )
    $buf = [IntPtr]::Zero
    $bytes = 0
    try {
      if (-not [Toula.WtsEx.NativeMethods]::WTSQuerySessionInformation($Server, $Id, $InfoClass, [ref]$buf, [ref]$bytes)) {
        return $null
      }
      if ($buf -eq [IntPtr]::Zero -or $bytes -lt 2) {
        return $null
      }
      [Runtime.InteropServices.Marshal]::ReadInt16($buf)
    }
    finally {
      if ($buf -ne [IntPtr]::Zero) {
        [Toula.WtsEx.NativeMethods]::WTSFreeMemory($buf)
      }
    }
  }

  function Get-WtsUInt32 {
    param(
      [IntPtr]$Server,
      [int]$Id,
      [Toula.WtsEx.WTS_INFO_CLASS]$InfoClass
    )
    $buf = [IntPtr]::Zero
    $bytes = 0
    try {
      if (-not [Toula.WtsEx.NativeMethods]::WTSQuerySessionInformation($Server, $Id, $InfoClass, [ref]$buf, [ref]$bytes)) {
        return $null
      }
      if ($buf -eq [IntPtr]::Zero -or $bytes -lt 4) {
        return $null
      }
      [Runtime.InteropServices.Marshal]::ReadInt32($buf)
    }
    finally {
      if ($buf -ne [IntPtr]::Zero) {
        [Toula.WtsEx.NativeMethods]::WTSFreeMemory($buf)
      }
    }
  }

  function Get-WtsClientAddressText {
    param(
      [IntPtr]$Server,
      [int]$Id
    )
    $buf = [IntPtr]::Zero
    $bytes = 0
    try {
      if (-not [Toula.WtsEx.NativeMethods]::WTSQuerySessionInformation($Server, $Id, [Toula.WtsEx.WTS_INFO_CLASS]::WTSClientAddress, [ref]$buf, [ref]$bytes)) {
        return $null
      }
      if ($buf -eq [IntPtr]::Zero) {
        return $null
      }
      $addr = [Runtime.InteropServices.Marshal]::PtrToStructure($buf, [type][Toula.WtsEx.WTS_CLIENT_ADDRESS])
      if ($null -eq $addr.Address -or $addr.Address.Length -lt 6) {
        return $null
      }
      if ($addr.AddressFamily -eq 2) {
        return [string]::Join('.', @($addr.Address[2], $addr.Address[3], $addr.Address[4], $addr.Address[5]))
      }
      if ($addr.AddressFamily -eq 23 -and $addr.Address.Length -ge 18) {
        try { return ([Net.IPAddress]::new([byte[]]$addr.Address[2..17])).ToString() } catch { return $null }
      }
      $null
    }
    finally {
      if ($buf -ne [IntPtr]::Zero) {
        [Toula.WtsEx.NativeMethods]::WTSFreeMemory($buf)
      }
    }
  }

  function Get-WtsClientDisplayText {
    param(
      [IntPtr]$Server,
      [int]$Id
    )
    $buf = [IntPtr]::Zero
    $bytes = 0
    try {
      if (-not [Toula.WtsEx.NativeMethods]::WTSQuerySessionInformation($Server, $Id, [Toula.WtsEx.WTS_INFO_CLASS]::WTSClientDisplay, [ref]$buf, [ref]$bytes)) {
        return $null
      }
      if ($buf -eq [IntPtr]::Zero) {
        return $null
      }
      $display = [Runtime.InteropServices.Marshal]::PtrToStructure($buf, [type][Toula.WtsEx.WTS_CLIENT_DISPLAY])
      if ($display.HorizontalResolution -gt 0 -and $display.VerticalResolution -gt 0) {
        return "$($display.HorizontalResolution)x$($display.VerticalResolution)x$($display.ColorDepth)"
      }
      $null
    }
    finally {
      if ($buf -ne [IntPtr]::Zero) {
        [Toula.WtsEx.NativeMethods]::WTSFreeMemory($buf)
      }
    }
  }

  function Get-WtsSessionTiming {
    param(
      [IntPtr]$Server,
      [int]$Id
    )

    $buf = [IntPtr]::Zero
    $bytes = 0

    try {
      if (-not [Toula.WtsEx.NativeMethods]::WTSQuerySessionInformation(
        $Server,
        $Id,
        [Toula.WtsEx.WTS_INFO_CLASS]::WTSSessionInfoEx,
        [ref]$buf,
        [ref]$bytes
      )) {
        return $null
      }

      if ($buf -eq [IntPtr]::Zero) {
        return $null
      }

      $info = [Runtime.InteropServices.Marshal]::PtrToStructure($buf, [type][Toula.WtsEx.WTSINFOEXW])
      if ($info.Level -ne 1) {
        return $null
      }

      $x = $info.Data.WTSInfoExLevel1

      $logonTime = Convert-WtsFileTimeToLocal $x.LogonTime
      $connectTime = Convert-WtsFileTimeToLocal $x.ConnectTime
      $disconnectTime = Convert-WtsFileTimeToLocal $x.DisconnectTime
      $lastInputTime = Convert-WtsFileTimeToLocal $x.LastInputTime
      $snapshotTime = Convert-WtsFileTimeToLocal $x.CurrentTime

      $idleTime = $null
      if ($snapshotTime -and $lastInputTime -and $snapshotTime -ge $lastInputTime) {
        $idleTime = $snapshotTime - $lastInputTime
      }

      $sessionAge = $null
      if ($snapshotTime -and $logonTime -and $snapshotTime -ge $logonTime) {
        $sessionAge = $snapshotTime - $logonTime
      }

      $connectedDuration = $null
      if ($snapshotTime -and $connectTime -and $snapshotTime -ge $connectTime -and
          ($x.SessionState -eq [Toula.WtsEx.WTS_CONNECTSTATE_CLASS]::WTSActive -or
           $x.SessionState -eq [Toula.WtsEx.WTS_CONNECTSTATE_CLASS]::WTSConnected -or
           $x.SessionState -eq [Toula.WtsEx.WTS_CONNECTSTATE_CLASS]::WTSShadow)) {
        $connectedDuration = $snapshotTime - $connectTime
      }

      $disconnectedTime = $null
      if ($snapshotTime -and $disconnectTime -and $snapshotTime -ge $disconnectTime -and
          $x.SessionState -eq [Toula.WtsEx.WTS_CONNECTSTATE_CLASS]::WTSDisconnected) {
        $disconnectedTime = $snapshotTime - $disconnectTime
      }

      [pscustomobject]@{
        LogonTime         = $logonTime
        ConnectTime       = $connectTime
        DisconnectTime    = $disconnectTime
        LastInputTime     = $lastInputTime
        SnapshotTime      = $snapshotTime
        IdleTime          = $idleTime
        SessionAge        = $sessionAge
        ConnectedDuration = $connectedDuration
        DisconnectedTime  = $disconnectedTime
      }
    }
    finally {
      if ($buf -ne [IntPtr]::Zero) {
        [Toula.WtsEx.NativeMethods]::WTSFreeMemory($buf)
      }
    }
  }

  function Convert-WtsProtocol {
    param([Nullable[int]]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -eq 0) { return 'ConsoleOrUnknown' }
    if ($Value -eq 2) { return 'RDP' }
    "Other($Value)"
  }

  function Test-IsLocalComputerName {
    param([string]$Name)
    [string]::IsNullOrWhiteSpace($Name) -or
      $Name -eq '.' -or
      $Name -eq 'localhost' -or
      $Name -ieq $env:COMPUTERNAME
  }

  function Get-CimInstanceForSessionQueryTarget {
    param(
      [Parameter(Mandatory)][string]$ClassName,
      [string[]]$Property,
      [System.Management.Automation.ActionPreference]$CimErrorAction = [System.Management.Automation.ActionPreference]::Stop
    )

    if (Test-IsLocalComputerName -Name $ComputerName) {
      Get-CimInstance -ClassName $ClassName -Property $Property -ErrorAction $CimErrorAction
      return
    }

    Get-CimInstance -ComputerName $ComputerName -ClassName $ClassName -Property $Property -ErrorAction $CimErrorAction
  }

  $server = Get-WtsServerHandle -Name $ComputerName
  $sessionsPtr = [IntPtr]::Zero
  $count = 0

  try {
    if (-not [Toula.WtsEx.NativeMethods]::WTSEnumerateSessions($server, 0, 1, [ref]$sessionsPtr, [ref]$count)) {
      throw "WTSEnumerateSessions failed for '$ComputerName'."
    }

    $usageBySession = @{}
    $logicalProcessorCount = 1

    $afterProcessProperties = @(
      'ProcessId',
      'SessionId',
      'WorkingSetSize'
    )

    if (-not $FastDontSampleProcessCpuIo) {
      $logicalProcessorCount = @(
        Get-CimInstanceForSessionQueryTarget `
          -ClassName Win32_Processor `
          -Property NumberOfLogicalProcessors `
          -CimErrorAction Stop
      ).NumberOfLogicalProcessors |
        Measure-Object -Sum |
        Select-Object -ExpandProperty Sum

      if (-not $logicalProcessorCount) {
        $logicalProcessorCount = 1
      }

      $before = @{}

      Get-CimInstanceForSessionQueryTarget `
        -ClassName Win32_Process `
        -Property @(
          'ProcessId',
          'SessionId',
          'KernelModeTime',
          'UserModeTime',
          'ReadTransferCount',
          'WriteTransferCount'
        ) `
        -CimErrorAction Stop |
        ForEach-Object {
          $before[[uint32]$_.ProcessId] = [pscustomobject]@{
            SessionId = [int]$_.SessionId
            Processor100ns = (
              [uint64]$_.KernelModeTime +
              [uint64]$_.UserModeTime
            )
            IoBytes = (
              [uint64]$_.ReadTransferCount +
              [uint64]$_.WriteTransferCount
            )
          }
        }

      Start-Sleep -Seconds 1

      $afterProcessProperties += @(
        'KernelModeTime',
        'UserModeTime',
        'ReadTransferCount',
        'WriteTransferCount'
      )
    }

    $afterProcesses = @(
      Get-CimInstanceForSessionQueryTarget `
        -ClassName Win32_Process `
        -Property $afterProcessProperties `
        -CimErrorAction Stop
    )

    $privateWorkingSets = @{}

    Get-CimInstanceForSessionQueryTarget `
      -ClassName Win32_PerfFormattedData_PerfProc_Process `
      -Property IDProcess, WorkingSetPrivate `
      -CimErrorAction SilentlyContinue |
      ForEach-Object {
        $processId = [uint32]$_.IDProcess

        if ($processId -ne 0) {
          $privateWorkingSets[$processId] = [uint64]$_.WorkingSetPrivate
        }
      }

    foreach ($process in $afterProcesses) {
      $processId = [uint32]$process.ProcessId
      $processSessionId = [int]$process.SessionId

      if (-not $usageBySession.ContainsKey($processSessionId)) {
        $usageBySession[$processSessionId] = [pscustomobject]@{
          ProcessCount      = 0
          Processor100ns    = [uint64]0
          PrivateWorkingSet = [uint64]0
          IoBytes           = [uint64]0
        }
      }

      $usage = $usageBySession[$processSessionId]
      $usage.ProcessCount++

      if ($privateWorkingSets.ContainsKey($processId)) {
        $usage.PrivateWorkingSet += [uint64]$privateWorkingSets[$processId]
      }
      else {
        $usage.PrivateWorkingSet += [uint64]$process.WorkingSetSize
      }

      if ($FastDontSampleProcessCpuIo) {
        continue
      }

      if (-not $before.ContainsKey($processId)) {
        continue
      }

      $old = $before[$processId]

      if ($old.SessionId -ne $processSessionId) {
        continue
      }

      $newProcessorTime = (
        [uint64]$process.KernelModeTime +
        [uint64]$process.UserModeTime
      )

      $newIoBytes = (
        [uint64]$process.ReadTransferCount +
        [uint64]$process.WriteTransferCount
      )

      if ($newProcessorTime -ge $old.Processor100ns) {
        $usage.Processor100ns += $newProcessorTime - $old.Processor100ns
      }

      if ($newIoBytes -ge $old.IoBytes) {
        $usage.IoBytes += $newIoBytes - $old.IoBytes
      }
    }

    $structSize = [Runtime.InteropServices.Marshal]::SizeOf([type][Toula.WtsEx.WTS_SESSION_INFO])

    for ($i = 0; $i -lt $count; $i++) {
      $current = [IntPtr]($sessionsPtr.ToInt64() + ($i * $structSize))
      $session = [Runtime.InteropServices.Marshal]::PtrToStructure($current, [type][Toula.WtsEx.WTS_SESSION_INFO])

      if ($SessionId -and ($SessionId -notcontains $session.SessionID)) {
        continue
      }

      $sessionName = Convert-PtrToStringUni $session.pWinStationName
      if ([string]::IsNullOrWhiteSpace($sessionName)) { $sessionName = $null }

      $user = Get-WtsString -Server $server -Id $session.SessionID -InfoClass ([Toula.WtsEx.WTS_INFO_CLASS]::WTSUserName)
      $domain = Get-WtsString -Server $server -Id $session.SessionID -InfoClass ([Toula.WtsEx.WTS_INFO_CLASS]::WTSDomainName)
      $clientName = Get-WtsString -Server $server -Id $session.SessionID -InfoClass ([Toula.WtsEx.WTS_INFO_CLASS]::WTSClientName)
      $clientAddress = Get-WtsClientAddressText -Server $server -Id $session.SessionID
      $protocolRaw = Get-WtsUInt16 -Server $server -Id $session.SessionID -InfoClass ([Toula.WtsEx.WTS_INFO_CLASS]::WTSClientProtocolType)
      $clientBuild = Get-WtsUInt32 -Server $server -Id $session.SessionID -InfoClass ([Toula.WtsEx.WTS_INFO_CLASS]::WTSClientBuildNumber)
      $clientDirectory = Get-WtsString -Server $server -Id $session.SessionID -InfoClass ([Toula.WtsEx.WTS_INFO_CLASS]::WTSClientDirectory)
      $clientDisplay = Get-WtsClientDisplayText -Server $server -Id $session.SessionID
      $timing = Get-WtsSessionTiming -Server $server -Id $session.SessionID
      $usage = $usageBySession[[int]$session.SessionID]

      if (-not $usage) {
        $usage = [pscustomobject]@{
          ProcessCount      = 0
          Processor100ns    = [uint64]0
          PrivateWorkingSet = [uint64]0
          IoBytes           = [uint64]0
        }
      }

      $processCount = $null
      $cpuPercent = $null
      $ioMBps = $null

      if (-not $FastDontSampleProcessCpuIo) {
        $processCount = [int]$usage.ProcessCount
        $cpuPercent = [math]::Round(
          (
            $usage.Processor100ns /
            (10000000.0 * $logicalProcessorCount)
          ) * 100,
          1
        )
        $ioMBps = [math]::Round(
          $usage.IoBytes / 1MB,
          3
        )
      }

      [pscustomobject]@{
        ComputerName      = $ComputerName
        SessionId         = $session.SessionID
        State             = [string]$session.State
        SessionName       = $sessionName
        UserName          = $user
        Domain            = $domain
        UserPrincipal     = if ($user) { if ($domain) { "$domain\$user" } else { $user } } else { $null }
        ClientName        = $clientName
        ClientAddress     = $clientAddress
        Protocol          = Convert-WtsProtocol -Value $protocolRaw
        ClientBuild       = $clientBuild
        ClientDisplay     = $clientDisplay
        ClientDirectory   = $clientDirectory
        LogonTime         = if ($timing) { $timing.LogonTime } else { $null }
        ConnectTime       = if ($timing) { $timing.ConnectTime } else { $null }
        DisconnectTime    = if ($timing) { $timing.DisconnectTime } else { $null }
        LastInputTime     = if ($timing) { $timing.LastInputTime } else { $null }
        SnapshotTime      = if ($timing) { $timing.SnapshotTime } else { $null }
        IdleTime          = if ($timing) { $timing.IdleTime } else { $null }
        SessionAge        = if ($timing) { $timing.SessionAge } else { $null }
        ConnectedDuration = if ($timing) { $timing.ConnectedDuration } else { $null }
        DisconnectedTime  = if ($timing) { $timing.DisconnectedTime } else { $null }
        ProcessCount      = $processCount
        CPUPercent        = $cpuPercent
        MemoryMB          = [math]::Round(
          $usage.PrivateWorkingSet / 1MB,
          1
        )
        IO_MBps           = $ioMBps
      }
    }
  }
  finally {
    if ($sessionsPtr -ne [IntPtr]::Zero) {
      [Toula.WtsEx.NativeMethods]::WTSFreeMemory($sessionsPtr)
    }
    if ($server -ne [IntPtr]::Zero) {
      [Toula.WtsEx.NativeMethods]::WTSCloseServer($server)
    }
  }
}

function HealthTest-DesktopSessions {
<#
Description: Checks for idle or disconnected RDP sessions older than the allowed threshold.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Get-LiveSessionInfo.
#>
    [CmdletBinding()]
    param(
        [TimeSpan]$Threshold = ([TimeSpan]::FromHours(8))
    )

    $issueFound = $false
    $availableRamMB = $null

    try {
        $os = Get-CimInstance Win32_OperatingSystem -Property FreePhysicalMemory -ErrorAction Stop
        $availableRamMB = [double]$os.FreePhysicalMemory / 1024
    }
    catch {
    }

    $sessions = @(Get-LiveSessionInfo)

    foreach ($session in $sessions) {
        if (-not $session) { continue }
        if ([string]::IsNullOrWhiteSpace($session.UserName)) { continue }

        $who = $session.UserPrincipal
        if ([string]::IsNullOrWhiteSpace($who)) { $who = $session.UserName }

        $detailLines = @()
        $detailLines += "State: $($session.State)"
        if ($session.SessionName)      { $detailLines += "SessionName: $($session.SessionName)" }
        if ($session.LogonTime)        { $detailLines += "LogonTime: $($session.LogonTime)" }
        if ($session.LastInputTime)    { $detailLines += "LastInputTime: $($session.LastInputTime)" }
        if ($session.IdleTime)         { $detailLines += "IdleTime: $($session.IdleTime)" }
        if ($session.ClientName)       { $detailLines += "ClientName: $($session.ClientName)" }
        if ($session.ClientAddress)    { $detailLines += "ClientAddress: $($session.ClientAddress)" }
        if ($session.Protocol)         { $detailLines += "Protocol: $($session.Protocol)" }
        $detailLines += "ProcessCount: $(if ($null -ne $session.ProcessCount) { $session.ProcessCount } else { '(not sampled)' })"
        $detailLines += "CPUPercent: $(if ($null -ne $session.CPUPercent) { "$($session.CPUPercent)%" } else { '(not sampled)' })"
        $detailLines += "MemoryMB: $(if ($null -ne $session.MemoryMB) { $session.MemoryMB } else { '(unknown)' })"
        $detailLines += "IO_MBps: $(if ($null -ne $session.IO_MBps) { $session.IO_MBps } else { '(not sampled)' })"

        $details = $detailLines -join "`n"

        if ($session.State -eq 'WTSDisconnected' -and
            $null -ne $availableRamMB -and
            $availableRamMB -gt 0 -and
            $null -ne $session.MemoryMB -and
            [double]$session.MemoryMB -gt ($availableRamMB * 0.2)) {
            $issueFound = $true
            Write-Warning ("[WARNING] User $who has a disconnected session materially impacting RAM availability" + $(if ($details) { "`n$details" } else { '' }))
        }

        if ($session.State -eq 'WTSDisconnected' -and
            $null -ne $session.CPUPercent -and
            [double]$session.CPUPercent -gt 20) {
            $issueFound = $true
            Write-Warning ("[WARNING] User $who has a disconnected session with considerable CPU usage" + $(if ($details) { "`n$details" } else { '' }))
        }

        $problemType = $null
        $problemAge = $null

        if ($session.State -eq 'WTSDisconnected' -and $session.DisconnectedTime -ge $Threshold) {
            $problemType = 'disconnected'
            $problemAge = $session.DisconnectedTime
        }
        elseif ($session.IdleTime -ge $Threshold) {
            $problemType = 'idle'
            $problemAge = $session.IdleTime
        }

        if (-not $problemType) { continue }

        $issueFound = $true

        $issueSynopsis = "User $who has a $problemType session for more than $([int]$Threshold.TotalHours) hours"
        Write-Warning ("[NOTICE] $issueSynopsis" + $(if ($details) { "`n$details" } else { '' }))
    }

    if (-not $issueFound) {
        Write-Warning "[pass] No Desktop Session isues founds (stales sesssions, or disconnected sessions consuming considerable resources)"
    }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-DesktopSessions
}
