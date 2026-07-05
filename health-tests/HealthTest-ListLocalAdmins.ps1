<#
Standalone file for HealthTest-ListLocalAdmins.
Generated during the repo-wide health-test split.
#>
# HostRequirement: All

function HealthTest-ListLocalAdmins {
<#
Description: Lists members of the local Administrators group.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Tags: Policy
Uses: None.

Policy identity: normalized account authority and account name as reported for the local Administrators group. Lookup timestamps and transient ADSI object paths are not included.
Policy baseline version: 1
#>
    $pass = $true

    $grp = [ADSI]"WinNT://$env:COMPUTERNAME/Administrators,group"
    $members = @(@($grp.psbase.Invoke('Members')) | ForEach-Object { [ADSI]$_ })

    foreach ($m in $members) {
        $name = $m.InvokeGet('Name')
        $path = [string]$m.Path

        $dom  = ''
        $acct = $name

        if ($path -match '^WinNT://([^/]+)/([^/,]+)(?:,.*)?$') {
            $dom  = $Matches[1]
            $acct = $Matches[2]
        }

        $full = if ($dom) { "$dom\$acct" } else { $acct }
        Write-Warning "[WARNING] Local Administrator group member: $full"
        $pass = $false
    }
    if ($pass) {
        Write-Warning "[PASS] No accounts in Local Administrators"
    }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-ListLocalAdmins
}
