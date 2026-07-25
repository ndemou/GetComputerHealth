# HostRequirement: All

if (-not (Get-Command -Name 'Get-PolicyListShortHash' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helpers-for-healthtests.ps1')
}

if (-not (Get-Command -Name 'Normalize-PolicyListText' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helpers-for-healthtests.ps1')
}

function HealthTest-ListShares {
<#
Description: Lists SMB shares.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Tags: Policy
Uses: None.

Policy identity: normalized share name and normalized shared path. Share runtime use, connection count, and service state are not included.
Policy baseline version: 2
#>
    $shares = @(Get-CimInstance -ClassName Win32_Share | Select-Object Name, Path, Type, Description)
    if ($shares.Count -gt 0) {
        foreach ($share in $shares) {
            $identityText = 'name=' + (Normalize-PolicyListText $share.Name) + '|path=' + (Normalize-PolicyListText $share.Path)
            $policyId = Get-PolicyListShortHash -Text $identityText
            Write-Warning "[WARNING] Found SMB share: $($share.Name) fingerprint=$policyId`nPath: $($share.Path)`nType: $($share.Type)`nDescription: $($share.Description)`nIdentity: $identityText"
        }
    } else {
        Write-Warning "[PASS] No SMB shares discovered."
    }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-ListShares
}
