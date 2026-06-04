<#
.SYNOPSIS
Collects sample Hyper-V replication data from one host for debugging.

.DESCRIPTION
Captures the exact VM and VM replication properties that
`HealthTest-HyperVReplicationHealth` depends on, including raw values and
.NET types for the candidate "last successful replication time" fields.

Writes both JSON and CLIXML so the sample can be inspected manually and also
round-tripped later with PowerShell type information preserved.

.PARAMETER VmName
Optional VM name filter. When omitted, collects all VMs returned by `Get-VM`.

.PARAMETER OutputPath
Optional base output path without extension. Defaults to:
`.\temp\hyperv-replication-sample-<timestamp>`

.EXAMPLE
.\scripts\diagnostics\Collect-HyperVReplicationSample.ps1

.EXAMPLE
.\scripts\diagnostics\Collect-HyperVReplicationSample.ps1 -VmName SRV1
#>

[CmdletBinding()]
param(
  [string[]]$VmName,
  [string]$OutputPath
)

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$tempDir = Join-Path $repoRoot 'temp'
if (-not (Test-Path -LiteralPath $tempDir -PathType Container)) {
  New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $timestamp = Get-Date -Format 'yyyy-MM-dd_HH.mm.ss'
  $OutputPath = Join-Path $tempDir ("hyperv-replication-sample-{0}" -f $timestamp)
}

if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
  throw "Get-VM is not available. Run this on a Hyper-V host with the Hyper-V PowerShell module installed."
}

if (-not (Get-Command Get-VMReplication -ErrorAction SilentlyContinue)) {
  throw "Get-VMReplication is not available. Run this on a Hyper-V host with the Hyper-V PowerShell module installed."
}

function Get-TypeNameOrNull {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value) { return $null }
  return $Value.GetType().FullName
}

function Get-PropertySnapshot {
  param([AllowNull()][object]$Object)

  if ($null -eq $Object) { return @() }

  foreach ($prop in $Object.PSObject.Properties) {
    [pscustomobject]@{
      Name = $prop.Name
      Type = Get-TypeNameOrNull -Value $prop.Value
      Value = if ($null -eq $prop.Value) { $null } else { [string]$prop.Value }
    }
  }
}

function Get-ObjectPropertyValue {
  param(
    [AllowNull()][object]$Object,
    [Parameter(Mandatory)][string]$PropertyName
  )

  if ($null -eq $Object) { return $null }
  $prop = $Object.PSObject.Properties[$PropertyName]
  if (-not $prop) { return $null }
  return $prop.Value
}

$vms = if ($VmName -and $VmName.Count -gt 0) {
  foreach ($name in $VmName) { Get-VM -Name $name -ErrorAction Stop }
} else {
  @(Get-VM)
}

$sample = [pscustomobject]@{
  CollectedAt = (Get-Date).ToString('o')
  Host = [pscustomobject]@{
    ComputerName = $env:COMPUTERNAME
    UserDomain = $env:USERDOMAIN
    UserDnsDomain = $env:USERDNSDOMAIN
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    Culture = [System.Globalization.CultureInfo]::CurrentCulture.Name
    UICulture = [System.Globalization.CultureInfo]::CurrentUICulture.Name
  }
  Vms = @(
    foreach ($vm in $vms) {
      $replicationInfo = $null
      $replicationError = $null

      try {
        if ([string]$vm.ReplicationMode -in @('Primary', 'Replica')) {
          $replicationInfo = Get-VMReplication -VMName $vm.Name -ErrorAction Stop
        }
      }
      catch {
        $replicationError = $_.Exception.Message
      }

      [pscustomobject]@{
        Vm = [pscustomobject]@{
          Name = [string]$vm.Name
          Type = $vm.GetType().FullName
          State = [string]$vm.State
          ReplicationMode = [string]$vm.ReplicationMode
          ReplicationHealth = [string]$vm.ReplicationHealth
          ReplicationState = [string]$vm.ReplicationState
          SelectedProperties = Get-PropertySnapshot -Object ([pscustomobject]@{
              Name = $vm.Name
              State = $vm.State
              ReplicationMode = $vm.ReplicationMode
              ReplicationHealth = $vm.ReplicationHealth
              ReplicationState = $vm.ReplicationState
            })
        }
        ReplicationQueryError = $replicationError
        Replication = if ($replicationInfo) {
          $lastReplicationTime = Get-ObjectPropertyValue -Object $replicationInfo -PropertyName 'LastReplicationTime'
          $lastSuccessfulReplicationTime = Get-ObjectPropertyValue -Object $replicationInfo -PropertyName 'LastSuccessfulReplicationTime'
          $lastSuccessfulReplication = Get-ObjectPropertyValue -Object $replicationInfo -PropertyName 'LastSuccessfulReplication'
          $lastReplicatedTime = Get-ObjectPropertyValue -Object $replicationInfo -PropertyName 'LastReplicatedTime'

          [pscustomobject]@{
            Type = $replicationInfo.GetType().FullName
            CandidateTimes = [pscustomobject]@{
              LastReplicationTime = $lastReplicationTime
              LastReplicationTimeType = Get-TypeNameOrNull -Value $lastReplicationTime
              LastSuccessfulReplicationTime = $lastSuccessfulReplicationTime
              LastSuccessfulReplicationTimeType = Get-TypeNameOrNull -Value $lastSuccessfulReplicationTime
              LastSuccessfulReplication = $lastSuccessfulReplication
              LastSuccessfulReplicationType = Get-TypeNameOrNull -Value $lastSuccessfulReplication
              LastReplicatedTime = $lastReplicatedTime
              LastReplicatedTimeType = Get-TypeNameOrNull -Value $lastReplicatedTime
            }
            AllProperties = Get-PropertySnapshot -Object $replicationInfo
          }
        } else {
          $null
        }
      }
    }
  )
}

$jsonPath = $OutputPath + '.json'
$clixmlPath = $OutputPath + '.clixml'

$sample | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
$sample | Export-Clixml -LiteralPath $clixmlPath

Write-Host ("Saved Hyper-V replication sample JSON:   {0}" -f $jsonPath)
Write-Host ("Saved Hyper-V replication sample CLIXML: {0}" -f $clixmlPath)
