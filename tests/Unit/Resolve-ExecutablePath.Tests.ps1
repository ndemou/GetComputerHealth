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

Describe 'HealthTest-AutoStartServicesRunning' {
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

    HealthTest-AutoStartServicesRunning

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

    HealthTest-AutoStartServicesRunning

    Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
      $Message -eq "[FAILURE] Service 'BAR' which is set to automatically start is not running; alarmingly its last execution terminated abnormally: ExitCode=5(Access is denied.).`nDisplay name: Bar Service, StartMode=Auto, DelayedAutoStart=True, last ExitCode=5(Access is denied.)."
    }
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
      $Message -eq "[NOTICE] Found Microsoft service: Vendor='Microsoft Corporation' Name='WinDefend'`nAdmin must verify if service is legit and needed. Service Description: 'Microsoft Defender Antivirus Service'`nExecutable: 'C:\Windows\System32\MsMpEng.exe'."
    }
  }

  It 'uses FAILURE only for serious service-vendor resolution problems' {
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
      $Message -eq "[FAILURE] Either something's wrong with service 'BrokenSvc' or there's a bug in Get-ServiceVendors.`nError(s): Service BrokenSvc points to missing executable."
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
      $Message -eq "[NOTICE] Found Microsoft service: Vendor='Microsoft Windows' Name='WpnUserService_*' (Per-user service of base service 'WpnUserService')`nAdmin must verify if service is legit and needed. Service Description: 'Windows Push Notifications User Service'`nExecutable: 'C:\WINDOWS\System32\WpnUserService.dll'.`nFull service name: 'WpnUserService_147c46f'."
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
      $Message -eq "[NOTICE] Found Microsoft service: Vendor='Microsoft Windows' Name='ExampleSvc_147c46f'`nAdmin must verify if service is legit and needed. Service Description: 'Example Instance Service'`nExecutable: 'C:\Windows\System32\example-instance.dll'."
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
      $Message -eq "[NOTICE] Found Microsoft service: Vendor='Microsoft Windows' Name='TokenBrokerSvc_*' (Per-user service of base service 'TokenBrokerSvc')`nAdmin must verify if service is legit and needed. Service Description: 'Web Account Manager_147c46f'`nExecutable: 'C:\Windows\System32\different-user-host.dll'.`nFull service name: 'TokenBrokerSvc_147c46f'."
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
      $Message -eq "[NOTICE] Found service from a common workstation vendor: Vendor='Google LLC' Name='ChromeUserSvc_*' (Per-user service of base service 'ChromeUserSvc')`nAdmin must verify if service is legit and needed. Service Description: 'Chrome User Service_147c46f'`nExecutable: 'C:\Program Files\Google\Chrome\chrome-user-service.exe'.`nFull service name: 'ChromeUserSvc_147c46f'."
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
      $Message -eq "[NOTICE] Found Microsoft service: Vendor='Microsoft Windows' Name='WpnUserService_*' (Per-user service of base service 'WpnUserService')`nAdmin must verify if service is legit and needed. Service Description: 'Windows Push Notifications User Service_147c46f'`nExecutable: 'C:\WINDOWS\System32\WpnUserService.dll'.`nFull service name: 'WpnUserService_147c46f'."
    }
  }
}
