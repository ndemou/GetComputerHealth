# HostRequirement: All

if (-not (Get-Command -Name 'Get-PropValue' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helpers-for-healthtests.ps1')
}

function Get-SoftwareLicensing {
<#
.SYNOPSIS
Retrieves Windows software licensing product status for the local or remote host.

.DESCRIPTION
Queries `SoftwareLicensingProduct` over CIM, normalizes key properties,
and returns friendly licensing status fields for reporting.
#>

    [CmdletBinding()]
    param([string]$ComputerName = $env:COMPUTERNAME)

    function Convert-LicenseStatus {
        param([int]$code)
        switch ($code) {
            0 {'Unlicensed'}
            1 {'Licensed'}
            2 {'OOB Grace'}
            3 {'OOT Grace'}
            4 {'Non-Genuine Grace'}
            5 {'Notification'}
            6 {'Extended Grace'}
            default {"Unknown ($code)"}
        }
    }

    if ($ComputerName -eq $env:COMPUTERNAME) {
        $products = Get-CimInstance -ClassName SoftwareLicensingProduct -ErrorAction Stop |
                Where-Object { $_.PartialProductKey -and $_.LicenseStatus -ne $null }
    } else {
        $products = Get-CimInstance -ClassName SoftwareLicensingProduct -ComputerName $ComputerName -ErrorAction Stop |
                Where-Object { $_.PartialProductKey -and $_.LicenseStatus -ne $null }
    }

    $objects = foreach($p in $products){
        $statusText = Convert-LicenseStatus -code ([int]$p.LicenseStatus)

        $channel = $null
        if ($p.Description) {
            $m = [regex]::Match($p.Description, '(?i)\b([A-Z0-9_]+)\s+channel\b')
            if ($m.Success) { $channel = $m.Groups[1].Value }
        }

        [pscustomobject][ordered]@{
            ComputerName         = $ComputerName
            ProductName          = $p.Name
            LicenseFamily        = Get-PropValue $p 'LicenseFamily'
            ApplicationId        = $p.ApplicationId
            ProductSkuId         = Get-PropValue $p 'ProductSkuId'
            PartialProductKey    = Get-PropValue $p 'PartialProductKey'
            LicenseStatus        = [int]$p.LicenseStatus
            LicenseStatusText    = $statusText
            IsLicensed           = [bool]($p.LicenseStatus -eq 1)
            GracePeriodRemaining = Get-PropValue $p 'GracePeriodRemaining'
            Description          = $p.Description
            Channel              = $channel
        }
    }

    $objects | Sort-Object ProductName, LicenseStatus
}

function HealthTest-SoftwareLicensing{
<#
Description: Checks Windows software licensing state and activation status.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: Get-SoftwareLicensing.
#>

    Get-SoftwareLicensing | %{
        # ($_ | Format-List * -Force | Out-String).Trim()|write-host -f green
        Write-BasedOnTestResult "Is $($_.ProductName) Licensed?" -Test $_.IsLicensed -comment "$_"
    }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-SoftwareLicensing
}
