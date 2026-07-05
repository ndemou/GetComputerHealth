$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Describe 'Resolve-ExecutablePath' {
  BeforeAll {
    . (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'health-tests\srvc-exe-resolve.ps1')
  }

  $hasNotepad = Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\notepad.exe') -PathType Leaf
  $hasNetsh = Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\netsh.exe') -PathType Leaf

  $testCases = @(
    @{
      Name = 'Quotes: Double Quotes + Env'
      CaseInput = "`"%WINDIR%\System32\notepad.exe`""
      CaseExpected = if ($hasNotepad) { (Get-Item -LiteralPath (Join-Path $env:WINDIR 'System32\notepad.exe')).FullName } else { $null }
      CaseWorkDir = { param($root) $root }
    },
    @{
      Name = 'Quotes: Single Quotes + Env'
      CaseInput = "'%WINDIR%\System32\notepad.exe'"
      CaseExpected = if ($hasNotepad) { (Get-Item -LiteralPath (Join-Path $env:WINDIR 'System32\notepad.exe')).FullName } else { $null }
      CaseWorkDir = { param($root) $root }
    },
    @{
      Name = 'Absolute: Exact Match'
      CaseInput = { param($root) (Join-Path $root 'rootTool.exe') }
      CaseExpected = { param($root) (Join-Path $root 'rootTool.exe') }
      CaseWorkDir = { param($root) $root }
    },
    @{
      Name = 'Absolute: Missing Extension (.exe probe)'
      CaseInput = { param($root) (Join-Path $root 'rootTool') }
      CaseExpected = { param($root) (Join-Path $root 'rootTool.exe') }
      CaseWorkDir = { param($root) $root }
    },
    @{
      Name = 'Absolute: Missing Extension (.bat probe)'
      CaseInput = { param($root) (Join-Path $root 'script') }
      CaseExpected = { param($root) (Join-Path $root 'script.bat') }
      CaseWorkDir = { param($root) $root }
    },
    @{
      Name = 'PATH: Command Search (rootTool)'
      CaseInput = 'rootTool'
      CaseExpected = { param($root) (Join-Path $root 'rootTool.exe') }
      CaseWorkDir = { param($root) $env:USERPROFILE }
    },
    @{
      Name = 'PATH: Command with Spaces'
      CaseInput = 'space tool'
      CaseExpected = { param($root) (Join-Path $root 'space tool.exe') }
      CaseWorkDir = { param($root) $env:USERPROFILE }
    },
    @{
      Name = 'System32/Sysnative fallback: netsh'
      CaseInput = 'netsh'
      CaseExpected = if ($hasNetsh) { (Get-Item -LiteralPath (Join-Path $env:WINDIR 'System32\netsh.exe')).FullName } else { $null }
      CaseWorkDir = { param($root) $env:USERPROFILE }
      CaseBefore = {
        $script:SavedPathForNetshTest = $env:PATH
        $env:PATH = ($env:PATH -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -notin @((Join-Path $env:WINDIR 'System32'), (Join-Path $env:WINDIR 'Sysnative')) }) -join ';'
      }
      CaseAfter = {
        $env:PATH = $script:SavedPathForNetshTest
        Remove-Variable SavedPathForNetshTest -Scope Script -ErrorAction SilentlyContinue
      }
    },
    @{
      Name = 'Wildcards literal: tool[1].exe exact absolute'
      CaseInput = { param($root) (Join-Path $root 'tool[1].exe') }
      CaseExpected = { param($root) (Join-Path $root 'tool[1].exe') }
      CaseWorkDir = { param($root) $root }
    },
    @{
      Name = 'Wildcards literal: tool[1] (absolute, missing ext -> .exe probe)'
      CaseInput = { param($root) (Join-Path $root 'tool[1]') }
      CaseExpected = { param($root) (Join-Path $root 'tool[1].exe') }
      CaseWorkDir = { param($root) $root }
    },
    @{
      Name = 'Wildcards literal: tool*.exe should NOT expand'
      CaseInput = { param($root) (Join-Path $root 'tool*.exe') }
      CaseExpected = $null
      CaseWorkDir = { param($root) $root }
    },
    @{
      Name = 'Illegal chars: rooted path returns null'
      CaseInput = 'C:\Bad|Name\tool.exe'
      CaseExpected = $null
      CaseWorkDir = { param($root) $root }
    },
    @{
      Name = 'Illegal chars: relative path returns null'
      CaseInput = '.\Bad|Name\tool.exe'
      CaseExpected = $null
      CaseWorkDir = { param($root) $root }
    },
    @{
      Name = 'Failure: Non-existent command'
      CaseInput = 'ghost_file_xyz'
      CaseExpected = $null
      CaseWorkDir = { param($root) $root }
    }
  )

  It '<Name>' -ForEach $testCases {
    param($Name, $CaseInput, $CaseExpected, $CaseWorkDir, $CaseBefore, $CaseAfter)

    $tempRoot = $null
    $originalLocation = $null
    $originalPath = $null

    if ($CaseBefore) { & $CaseBefore }
    try {
      $root = Join-Path $env:TEMP ("ResolveExeTest_" + [guid]::NewGuid().ToString())
      $dirItem = New-Item -ItemType Directory -Path $root -Force
      $tempRoot = $dirItem.FullName
      $subDir = Join-Path $tempRoot 'SubFolder'
      New-Item -ItemType Directory -Path $subDir -Force | Out-Null

      @(
        'rootTool.exe',
        'script.bat',
        'space tool.exe',
        'SubFolder\deep.com',
        'tool[1].exe'
      ) | ForEach-Object {
        New-Item -ItemType File -Path (Join-Path $tempRoot $_) -Force | Out-Null
      }

      $originalLocation = Get-Location
      $originalPath = $env:PATH
      $env:PATH = "$tempRoot;$env:PATH"

      $workDir = if ($CaseWorkDir -is [scriptblock]) { & $CaseWorkDir $tempRoot } else { $CaseWorkDir }
      Set-Location $workDir

      $inputValue = if ($CaseInput -is [scriptblock]) { & $CaseInput $tempRoot } else { $CaseInput }
      $expectedValue = if ($CaseExpected -is [scriptblock]) { & $CaseExpected $tempRoot } else { $CaseExpected }

      $result = $null
      $threw = $false
      try {
        $result = Resolve-ExecutablePath $inputValue
      } catch {
        $threw = $true
      }

      $threw | Should -Be $false
      if ($null -eq $expectedValue) {
        $result | Should -Be $null
      } else {
        $result.ToString().ToLowerInvariant() | Should -Be $expectedValue.ToString().ToLowerInvariant()
      }
    } finally {
      try { Set-Location $originalLocation } catch {}
      if ($null -ne $originalPath) {
        $env:PATH = $originalPath
      }
      if ($tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
      }
      if ($CaseAfter) { & $CaseAfter }
    }
  }
}

Describe 'Resolve-ServiceExecutable' {
  BeforeAll {
    . (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'health-tests\srvc-exe-resolve.ps1')
    $script:ResolveServiceExecutableRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  }

  BeforeEach {
    $script:ResolveServiceExecutableRoot = Join-Path $script:ResolveServiceExecutableRepoRoot ('temp\ResolveServiceExecutableTests_' + [guid]::NewGuid().ToString())
    $script:ServiceDir = Join-Path $script:ResolveServiceExecutableRoot 'Program Files\Vendor App'
    $script:PayloadDir = Join-Path $script:ResolveServiceExecutableRoot 'Program Files\Vendor App\Payload'

    New-Item -ItemType Directory -Path $script:ServiceDir -Force | Out-Null
    New-Item -ItemType Directory -Path $script:PayloadDir -Force | Out-Null

    $script:ServiceExePath = Join-Path $script:ServiceDir 'Service.exe'
    $script:PayloadDllPath = Join-Path $script:PayloadDir 'Payload.dll'
    $script:DriverSysPath = Join-Path $script:ServiceDir 'Driver.sys'

    New-Item -ItemType File -Path $script:ServiceExePath -Force | Out-Null
    New-Item -ItemType File -Path $script:PayloadDllPath -Force | Out-Null
    New-Item -ItemType File -Path $script:DriverSysPath -Force | Out-Null
  }

  AfterEach {
    if (Get-Variable -Name ResolveServiceExecutableRoot -Scope Script -ErrorAction SilentlyContinue) {
      Remove-Item -LiteralPath $script:ResolveServiceExecutableRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Variable -Name ResolveServiceExecutableRoot -Scope Script -ErrorAction SilentlyContinue
    }
  }

  It 'resolves a quoted executable path with service arguments' {
    $quote = [char]34
    $commandLine = $quote + $script:ServiceExePath + $quote + ' --service'

    $result = Resolve-ServiceExecutable -LaunchCommand $commandLine -ServiceName 'QuotedVendorSvc'

    (Get-Item -LiteralPath $result.LauncherExe).FullName.ToLowerInvariant() | Should -Be (Get-Item -LiteralPath $script:ServiceExePath).FullName.ToLowerInvariant()
    $result.LauncherArgs | Should -Be '--service'
    $result.PayloadType | Should -Be 'Exe'
    (Get-Item -LiteralPath $result.PayloadPath).FullName.ToLowerInvariant() | Should -Be (Get-Item -LiteralPath $script:ServiceExePath).FullName.ToLowerInvariant()
    $result.Warnings.Count | Should -Be 0
  }

  It 'resolves an unquoted executable path with spaces without warning' {
    $commandLine = $script:ServiceExePath + ' --service'

    $result = Resolve-ServiceExecutable -LaunchCommand $commandLine -ServiceName 'UnquotedVendorSvc'

    (Get-Item -LiteralPath $result.LauncherExe).FullName.ToLowerInvariant() | Should -Be (Get-Item -LiteralPath $script:ServiceExePath).FullName.ToLowerInvariant()
    $result.LauncherArgs | Should -Be '--service'
    $result.PayloadType | Should -Be 'Exe'
    $result.Warnings.Count | Should -Be 0
  }

  It 'returns Unknown payload and a warning when the launcher cannot be resolved' {
    $missingPath = Join-Path $script:ServiceDir 'Missing.exe'
    $commandLine = $missingPath + ' --service'

    $result = Resolve-ServiceExecutable -LaunchCommand $commandLine -ServiceName 'MissingVendorSvc'

    $result.LauncherExe | Should -Be $null
    $result.PayloadType | Should -Be 'Unknown'
    $result.PayloadPath | Should -Be $null
    $result.Warnings | Should -Contain 'Launcher executable could not be resolved from LaunchCommand.'
  }

  It 'resolves a rundll32 payload DLL and entry point' {
    $quote = [char]34
    $rundll32 = Join-Path $env:WINDIR 'System32\rundll32.exe'
    $commandLine = $quote + $rundll32 + $quote + ' ' + $quote + $script:PayloadDllPath + ',ServiceMain' + $quote

    $result = Resolve-ServiceExecutable -LaunchCommand $commandLine -ServiceName 'RundllVendorSvc'

    $result.PayloadType | Should -Be 'DllViaRundll32'
    (Get-Item -LiteralPath $result.PayloadPath).FullName.ToLowerInvariant() | Should -Be (Get-Item -LiteralPath $script:PayloadDllPath).FullName.ToLowerInvariant()
    $result.PayloadDetails.DllToken.ToLowerInvariant() | Should -Be $script:PayloadDllPath.ToLowerInvariant()
    $result.PayloadDetails.EntryPoint | Should -Be 'ServiceMain'
  }

  It 'resolves an svchost payload DLL from Parameters\ServiceDll' {
    Mock Get-ItemProperty {
      [pscustomobject]@{
        Type = 16
      }
    } -ParameterFilter {
      $Path -eq 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\SvchostVendorSvc' -and
      $Name -eq 'Type'
    }

    Mock Get-ItemProperty {
      [pscustomobject]@{
        ServiceDll = $script:PayloadDllPath
      }
    } -ParameterFilter {
      $Path -eq 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\SvchostVendorSvc\Parameters' -and
      $Name -eq 'ServiceDll'
    }

    $svchost = Join-Path $env:WINDIR 'System32\svchost.exe'
    $commandLine = $svchost + ' -k LocalService -p'

    $result = Resolve-ServiceExecutable -LaunchCommand $commandLine -ServiceName 'SvchostVendorSvc'

    $result.PayloadType | Should -Be 'DllViaSvchost'
    (Get-Item -LiteralPath $result.PayloadPath).FullName.ToLowerInvariant() | Should -Be (Get-Item -LiteralPath $script:PayloadDllPath).FullName.ToLowerInvariant()
    $result.PayloadDetails.ServiceDll.ToLowerInvariant() | Should -Be $script:PayloadDllPath.ToLowerInvariant()
  }

  It 'classifies driver-style services as DriverSys' {
    Mock Get-ItemProperty {
      [pscustomobject]@{
        Type = 1
      }
    } -ParameterFilter {
      $Path -eq 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\DriverVendorSvc' -and
      $Name -eq 'Type'
    }

    $result = Resolve-ServiceExecutable -LaunchCommand $script:DriverSysPath -ServiceName 'DriverVendorSvc'

    $result.PayloadType | Should -Be 'DriverSys'
    (Get-Item -LiteralPath $result.PayloadPath).FullName.ToLowerInvariant() | Should -Be (Get-Item -LiteralPath $script:DriverSysPath).FullName.ToLowerInvariant()
  }
}

Describe 'HealthTest-Services' {
  BeforeAll {
    . (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'health-tests\srvc-exe-resolve.ps1')
  }

  It 'emits NOTICE when an auto-start service is stopped but last exited normally' {
    Mock Get-CimInstance {
      @(
        [pscustomobject]@{
          Name = 'FOO'
          DisplayName = 'Foo Service'
          State = 'Stopped'
          StartMode = 'Auto'
          DelayedAutoStart = $false
          ExitCode = 0
        }
      )
    } -ParameterFilter { $ClassName -eq 'Win32_Service' -and $Filter -eq "StartMode='Auto' and State!='Running'" }

    Mock Write-Warning {}
    Mock Get-ServiceVendors { @() }

    HealthTest-Services

    Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
      $Message -eq "[NOTICE] Service 'FOO' which is set to automatically start, is not running, but its last execution terminated with ExitCode=0(The operation completed successfully.).`nDisplay name: Foo Service, StartMode=Auto, DelayedAutoStart=False, last ExitCode=0(The operation completed successfully.)."
    }
  }

  It 'keeps FAILURE when an auto-start service is stopped and last exited abnormally' {
    Mock Get-CimInstance {
      @(
        [pscustomobject]@{
          Name = 'BAR'
          DisplayName = 'Bar Service'
          State = 'Stopped'
          StartMode = 'Auto'
          DelayedAutoStart = $true
          ExitCode = 5
        }
      )
    } -ParameterFilter { $ClassName -eq 'Win32_Service' -and $Filter -eq "StartMode='Auto' and State!='Running'" }

    Mock Write-Warning {}
    Mock Get-ServiceVendors { @() }

    HealthTest-Services

    Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
      $Message -eq "[FAILURE] Service 'BAR' which is set to automatically start is not running; alarmingly its last execution terminated abnormally: ExitCode=5(Access is denied.).`nDisplay name: Bar Service, StartMode=Auto, DelayedAutoStart=True, last ExitCode=5(Access is denied.)."
    }
  }

  It 'reports broken service executable or payload resolution' {
    Mock Get-CimInstance {
      @()
    } -ParameterFilter { $ClassName -eq 'Win32_Service' -and $Filter -eq "StartMode='Auto' and State!='Running'" }

    Mock Get-ServiceVendors {
      @(
        [pscustomobject]@{
          ServiceName = 'BrokenSvc'
          ExceptionsThrown = "Service BrokenSvc points to missing executable. Exe='' PathName='C:\Broken\BrokenSvc.exe'."
        }
      )
    }

    Mock Write-Warning {}

    HealthTest-Services

    Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
      $Message -eq "[FAILURE] Service 'BrokenSvc' has a broken or unresolved executable/payload path.`nError(s): Service BrokenSvc points to missing executable. Exe='' PathName='C:\Broken\BrokenSvc.exe'."
    }
  }
}

Describe 'Service policy identity' {
  BeforeAll {
    . (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'health-tests\srvc-exe-resolve.ps1')
  }

  It 'uses vendor identity for signed payloads' {
    $service = [pscustomobject]@{
      Vendor = 'Microsoft Corporation'
      ExeSHA256 = '1111'
      CodeIdentityType = 'Vendor'
      CodeIdentityValue = 'Microsoft Corporation'
    }

    Get-ServiceCodeIdentityText -Service $service | Should -Be 'vendor:microsoft corporation'
  }

  It 'uses payload hash identity for unsigned payloads' {
    $service = [pscustomobject]@{
      Vendor = '(Unsigned)'
      ExeSHA256 = 'ABCDEF012345'
      CodeIdentityType = 'Hash'
      CodeIdentityValue = 'ABCDEF012345'
    }

    Get-ServiceCodeIdentityText -Service $service | Should -Be 'hash:abcdef012345'
  }

  It 'changes the policy fingerprint when the payload path changes' {
    $first = Get-ServicePolicyFingerprint -NormalizedServiceName 'ExampleSvc' -PayloadPath 'C:\Program Files\Example\svc.exe' -CodeIdentityText 'vendor:example inc.'
    $second = Get-ServicePolicyFingerprint -NormalizedServiceName 'ExampleSvc' -PayloadPath 'C:\Program Files\Example\svc2.exe' -CodeIdentityText 'vendor:example inc.'

    $first | Should -Not -Be $second
  }

  It 'changes the policy fingerprint when vendor or hash identity changes' {
    $first = Get-ServicePolicyFingerprint -NormalizedServiceName 'ExampleSvc' -PayloadPath 'C:\Program Files\Example\svc.exe' -CodeIdentityText 'vendor:example inc.'
    $second = Get-ServicePolicyFingerprint -NormalizedServiceName 'ExampleSvc' -PayloadPath 'C:\Program Files\Example\svc.exe' -CodeIdentityText 'hash:abcdef012345'

    $first | Should -Not -Be $second
  }

  It 'normalizes per-user service instance names for policy reporting' {
    Normalize-ServicePolicyName -ServiceName 'ChromeUserSvc_147c46f' -IsPerUserServiceInstance $true | Should -Be 'ChromeUserSvc_*'
  }
}

Describe 'HealthTest-ListServices' {
  BeforeAll {
    . (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'health-tests\srvc-exe-resolve.ps1')
  }

  It 'reports Microsoft services instead of filtering them out' {
    Mock Get-CimInstance {
      [pscustomobject]@{
        DomainRole = 1
      }
    } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }

    Mock Get-ServiceVendors {
      @(
        [pscustomobject]@{
          ServiceName = 'WinDefend'
          DisplayName = 'Microsoft Defender Antivirus Service'
          Vendor = 'Microsoft Corporation'
          ExePath = 'C:\Windows\System32\MsMpEng.exe'
          ExeSHA256 = $null
          ExceptionsThrown = ''
        }
      )
    }

    Mock Write-Warning {}

    HealthTest-ListServices

    Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
      $Message -match "^\[NOTICE\] Found service: Vendor='Microsoft Corporation' Name='WinDefend' fingerprint=[0-9a-f]{16}" -and
      $Message -match "Executable: 'C:\\Windows\\System32\\MsMpEng[.]exe'[.]" -and
      $Message -match "Policy identity: vendor:microsoft corporation[.]"
    }
  }

  It 'does not emit hygiene failure for service-vendor resolution problems' {
    Mock Get-CimInstance {
      [pscustomobject]@{
        DomainRole = 1
      }
    } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }

    Mock Get-ServiceVendors {
      @(
        [pscustomobject]@{
          ServiceName = 'BrokenSvc'
          DisplayName = 'Broken Service'
          Vendor = $null
          ExePath = 'C:\Broken\BrokenSvc.exe'
          ExeSHA256 = $null
          ExceptionsThrown = 'Service BrokenSvc points to missing executable.'
        }
      )
    }

    Mock Write-Warning {}

    HealthTest-ListServices

    Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
      $Message -match "^\[WARNING\] Found service: Vendor='' Name='BrokenSvc' fingerprint=[0-9a-f]{16}" -and
      $Message -match "Executable: 'C:\\Broken\\BrokenSvc[.]exe'[.]" -and
      $Message -match "Policy identity: unknown:[.]"
    }
  }

  It 'collapses per-user Microsoft service instances to one base-service notice' {
    Mock Get-CimInstance {
      [pscustomobject]@{
        DomainRole = 1
      }
    } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }

    Mock Test-Path { $true } -ParameterFilter {
      $LiteralPath -eq 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\WpnUserService'
    }

    Mock Get-ServiceVendors {
      @(
        [pscustomobject]@{
          ServiceName = 'WpnUserService'
          DisplayName = 'Windows Push Notifications User Service'
          Vendor = 'Microsoft Windows'
          ExePath = 'C:\WINDOWS\System32\WpnUserService.dll'
          ExeSHA256 = $null
          ServiceType = 'Share Process'
          ExceptionsThrown = ''
        },
        [pscustomobject]@{
          ServiceName = 'WpnUserService_147c46f'
          DisplayName = 'Windows Push Notifications User Service_147c46f'
          Vendor = 'Microsoft Windows'
          ExePath = 'C:\WINDOWS\System32\WpnUserService.dll'
          ExeSHA256 = $null
          ServiceType = 'User Share Process'
          ExceptionsThrown = ''
        },
        [pscustomobject]@{
          ServiceName = 'WpnUserService_8ab1234'
          DisplayName = 'Windows Push Notifications User Service_8ab1234'
          Vendor = 'Microsoft Windows'
          ExePath = 'C:\WINDOWS\System32\WpnUserService.dll'
          ExeSHA256 = $null
          ServiceType = 'User Share Process'
          ExceptionsThrown = ''
        }
      )
    }

    Mock Write-Warning {}

    HealthTest-ListServices

    Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
      $Message -match "^\[NOTICE\] Found service: Vendor='Microsoft Windows' Name='WpnUserService_[*]' [(]Per-user service of base service 'WpnUserService'[)] fingerprint=[0-9a-f]{16}" -and
      $Message -match "Executable: 'C:\\WINDOWS\\System32\\WpnUserService[.]dll'[.]" -and
      $Message -match "Policy identity: vendor:microsoft windows[.]" -and
      $Message -match "Full service name: 'WpnUserService_147c46f'[.]"
    }
  }

  It 'does not collapse suffixed services when the base executable differs and type is not user-instance' {
    Mock Get-CimInstance {
      [pscustomobject]@{
        DomainRole = 1
      }
    } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }

    Mock Test-Path { $true } -ParameterFilter {
      $LiteralPath -eq 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\ExampleSvc'
    }

    Mock Get-ServiceVendors {
      @(
        [pscustomobject]@{
          ServiceName = 'ExampleSvc'
          DisplayName = 'Example Base Service'
          Vendor = 'Microsoft Windows'
          ExePath = 'C:\Windows\System32\example-base.dll'
          ExeSHA256 = $null
          ServiceType = 'Share Process'
          ExceptionsThrown = ''
        },
        [pscustomobject]@{
          ServiceName = 'ExampleSvc_147c46f'
          DisplayName = 'Example Instance Service'
          Vendor = 'Microsoft Windows'
          ExePath = 'C:\Windows\System32\example-instance.dll'
          ExeSHA256 = $null
          ServiceType = 'Share Process'
          ExceptionsThrown = ''
        }
      )
    }

    Mock Write-Warning {}

    HealthTest-ListServices

    Should -Invoke Write-Warning -Times 2 -Exactly
    Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
      $Message -match "^\[NOTICE\] Found service: Vendor='Microsoft Windows' Name='ExampleSvc_147c46f' fingerprint=[0-9a-f]{16}" -and
      $Message -match "Executable: 'C:\\Windows\\System32\\example-instance[.]dll'[.]" -and
      $Message -match "Policy identity: vendor:microsoft windows[.]"
    }
  }

  <#
  It 'collapses suffixed services when service type marks a user-instance' {
    Mock Get-CimInstance {
      [pscustomobject]@{
        DomainRole = 1
      }
    } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }

    Mock Test-Path { $true } -ParameterFilter {
      $LiteralPath -eq 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\TokenBrokerSvc'
    }

    Mock Get-ServiceVendors {
      @(
        [pscustomobject]@{
          ServiceName = 'TokenBrokerSvc'
          DisplayName = 'Web Account Manager'
          Vendor = 'Microsoft Windows'
          ExePath = 'C:\Windows\System32\tokenbroker.dll'
          ExeSHA256 = $null
          ServiceType = 'Share Process'
          ExceptionsThrown = ''
        },
        [pscustomobject]@{
          ServiceName = 'TokenBrokerSvc_147c46f'
          DisplayName = 'Web Account Manager_147c46f'
          Vendor = 'Microsoft Windows'
          ExePath = 'C:\Windows\System32\different-user-host.dll'
          ExeSHA256 = $null
          ServiceType = 'User Own Process'
          ExceptionsThrown = ''
        }
      )
    }

    Mock Write-Warning {}

    HealthTest-ListServices

    Should -Invoke Write-Warning -Times 2 -Exactly
    Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
      $Message -eq "[NOTICE] Found service: Vendor='Microsoft Windows' Name='TokenBrokerSvc_*' (Per-user service of base service 'TokenBrokerSvc')`nAdmin must verify if service is legit and needed. Service Description: 'Web Account Manager_147c46f'`nExecutable: 'C:\Windows\System32\different-user-host.dll'.`nFull service name: 'TokenBrokerSvc_147c46f'."
    }
  }
  #>

  It 'uses star-name in the headline and full name in details for non-Microsoft per-user services' {
    Mock Get-CimInstance {
      [pscustomobject]@{
        DomainRole = 1
      }
    } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }

    Mock Test-Path { $true } -ParameterFilter {
      $LiteralPath -eq 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\ChromeUserSvc'
    }

    Mock Get-ServiceVendors {
      @(
        [pscustomobject]@{
          ServiceName = 'ChromeUserSvc'
          DisplayName = 'Chrome Base Service'
          Vendor = 'Google LLC'
          ExePath = 'C:\Program Files\Google\Chrome\chrome-user-service.exe'
          ExeSHA256 = $null
          ServiceType = 'Share Process'
          ExceptionsThrown = ''
        },
        [pscustomobject]@{
          ServiceName = 'ChromeUserSvc_147c46f'
          DisplayName = 'Chrome User Service_147c46f'
          Vendor = 'Google LLC'
          ExePath = 'C:\Program Files\Google\Chrome\chrome-user-service.exe'
          ExeSHA256 = $null
          ServiceType = 'User Own Process'
          ExceptionsThrown = ''
        }
      )
    }

    Mock Write-Warning {}

    HealthTest-ListServices

    Should -Invoke Write-Warning -Times 2 -Exactly
    Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
      $Message -match "^\[NOTICE\] Found service: Vendor='Google LLC' Name='ChromeUserSvc_[*]' [(]Per-user service of base service 'ChromeUserSvc'[)] fingerprint=[0-9a-f]{16}" -and
      $Message -match "Executable: 'C:\\Program Files\\Google\\Chrome\\chrome-user-service[.]exe'[.]" -and
      $Message -match "Policy identity: vendor:google llc[.]" -and
      $Message -match "Full service name: 'ChromeUserSvc_147c46f'[.]"
    }
  }

  It 'collapses per-user Microsoft services when only the base registry entry exists but the executable matches' {
    Mock Get-CimInstance {
      [pscustomobject]@{
        DomainRole = 1
      }
    } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }

    Mock Test-Path { $true } -ParameterFilter {
      $LiteralPath -eq 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\WpnUserService'
    }

    Mock Get-ItemProperty {
      [pscustomobject]@{
        ImagePath = '%SystemRoot%\System32\svchost.exe -k UnistackSvcGroup'
      }
    } -ParameterFilter {
      $Path -eq 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\WpnUserService' -and
      $Name -eq 'ImagePath'
    }

    Mock Resolve-ServiceExecutable {
      [pscustomobject]@{
        PayloadPath = 'C:\WINDOWS\System32\WpnUserService.dll'
      }
    } -ParameterFilter {
      $ServiceName -eq 'WpnUserService'
    }

    Mock Get-ServiceVendors {
      @(
        [pscustomobject]@{
          ServiceName = 'WpnUserService_147c46f'
          DisplayName = 'Windows Push Notifications User Service_147c46f'
          Vendor = 'Microsoft Windows'
          ExePath = 'C:\WINDOWS\System32\WpnUserService.dll'
          ExeSHA256 = $null
          ServiceType = 'Share Process'
          ExceptionsThrown = ''
        }
      )
    }

    Mock Write-Warning {}

    HealthTest-ListServices

    Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
      $Message -match "^\[NOTICE\] Found service: Vendor='Microsoft Windows' Name='WpnUserService_[*]' [(]Per-user service of base service 'WpnUserService'[)] fingerprint=[0-9a-f]{16}" -and
      $Message -match "Executable: 'C:\\WINDOWS\\System32\\WpnUserService[.]dll'[.]" -and
      $Message -match "Policy identity: vendor:microsoft windows[.]" -and
      $Message -match "Full service name: 'WpnUserService_147c46f'[.]"
    }
  }
}
