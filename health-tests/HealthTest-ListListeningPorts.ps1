# HostRequirement: All

if (-not (Get-Command -Name 'Get-PolicyListShortHash' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helpers-for-healthtests.ps1')
}

if (-not (Get-Command -Name 'Normalize-PolicyListText' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helpers-for-healthtests.ps1')
}

if (-not (Get-Command -Name 'Get-ExeVendor' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helper-regarding-service-and-executable-resolution.ps1')
}

if (-not (Get-Command -Name 'Resolve-ExecutablePath' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helper-regarding-service-and-executable-resolution.ps1')
}

function Get-ListeningPortAddressScope {
  [CmdletBinding()]
  param([AllowNull()][string]$LocalAddress)

  if ([string]::IsNullOrWhiteSpace($LocalAddress)) { return 'unknown' }
  if ($LocalAddress -in @('0.0.0.0', '::', '*')) { return 'any' }
  if ($LocalAddress -in @('127.0.0.1', '::1')) { return 'loopback' }
  return 'specific'
}

function Get-ListeningPortVendorText {
  [CmdletBinding()]
  param([AllowNull()][object]$VendorResult)

  if ($null -eq $VendorResult) { return '' }
  if ($VendorResult.PSObject.Properties.Name -contains 'Vendor') {
    return [string]$VendorResult.Vendor
  }

  return [string]$VendorResult
}

function HealthTest-ListListeningPorts {
<#
Description: Lists externally reachable TCP listening ports with process and publisher context.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Time), Medium(Network)
Tags: Policy
Uses: Get-NetTCPConnection, Resolve-ExecutablePath, Get-ExeVendor.

Policy identity: protocol, local port, address scope, process name, normalized executable path, and signed publisher/vendor when available. PID, concrete local IP address, and runtime connection state are not included.
Policy baseline version: 2
#>
    [CmdletBinding()] param(
        [int]$DynamicStart = 49152,
        [int]$DynamicEnd = 65535,
        [switch]$IncludeDynamic,
        [switch]$IncludeLoopback
    )

    $allListening = @(Get-NetTCPConnection -State Listen)
    $factsByIdentity = @{}

    foreach ($connection in $allListening) {
        $port = [int]$connection.LocalPort
        if ((-not $IncludeDynamic) -and $port -ge $DynamicStart -and $port -le $DynamicEnd) { continue }

        $addressScope = Get-ListeningPortAddressScope -LocalAddress ([string]$connection.LocalAddress)
        if ((-not $IncludeLoopback) -and $addressScope -eq 'loopback') { continue }

        $procId = [int]$connection.OwningProcess
        $processName = ''
        $processPath = ''
        $vendorText = ''

        if ($procId -eq 4) {
            $processName = 'System'
            $vendorText = 'Microsoft Windows'
            $processPath = 'pid4-system'
        }
        else {
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($proc) {
                $processName = [string]$proc.ProcessName
                if ($proc.Path) {
                    $processPath = [string]$proc.Path
                } else {
                    $resolveCommand = Get-Command -Name Resolve-ExecutablePath -ErrorAction SilentlyContinue
                    if ($resolveCommand) {
                        $resolved = Resolve-ExecutablePath $proc.ProcessName
                        if ($resolved) { $processPath = [string]$resolved }
                    }
                }

                if (-not [string]::IsNullOrWhiteSpace($processPath)) {
                    try {
                        $vendorText = Get-ListeningPortVendorText -VendorResult (Get-ExeVendor -Exe $processPath)
                    } catch {}
                }
            }
            else {
                $processName = 'pid-not-found'
            }
        }

        $identityText = 'protocol=tcp|port=' + $port + '|scope=' + (Normalize-PolicyListText $addressScope) + '|process=' + (Normalize-PolicyListText $processName) + '|path=' + (Normalize-PolicyListText $processPath) + '|vendor=' + (Normalize-PolicyListText $vendorText)
        if (-not $factsByIdentity.ContainsKey($identityText)) {
            $factsByIdentity[$identityText] = [pscustomobject]@{
                Port = $port
                AddressScope = $addressScope
                ProcessId = $procId
                ProcessName = $processName
                ProcessPath = $processPath
                Vendor = $vendorText
                LocalAddresses = New-Object System.Collections.Generic.List[string]
                IdentityText = $identityText
            }
        }

        $localAddress = [string]$connection.LocalAddress
        if (-not $factsByIdentity[$identityText].LocalAddresses.Contains($localAddress)) {
            [void]$factsByIdentity[$identityText].LocalAddresses.Add($localAddress)
        }
    }

    if ($factsByIdentity.Count -eq 0) {
        Write-Warning "[PASS] No externally reachable TCP listening ports discovered outside the ignored dynamic range."
        return
    }

    foreach ($fact in ($factsByIdentity.Values | Sort-Object Port, ProcessName, ProcessPath)) {
        $policyId = Get-PolicyListShortHash -Text $fact.IdentityText
        $level = 'WARNING'
        if ($fact.Vendor -match '(?i)\bmicrosoft\b') { $level = 'NOTICE' }

        Write-Warning "[$level] Found TCP listening port: $($fact.Port) fingerprint=$policyId`nProcess: $($fact.ProcessName) PID=$($fact.ProcessId)`nExecutable: $($fact.ProcessPath)`nVendor: $($fact.Vendor)`nAddress scope: $($fact.AddressScope)`nLocal addresses: $((@($fact.LocalAddresses) | Sort-Object) -join ', ')`nIdentity: $($fact.IdentityText)"
    }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-ListListeningPorts
}
