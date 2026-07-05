<#
Standalone file for HealthTest-LocalAcntRequirePass.
Generated during the repo-wide health-test split.
#>
# HostRequirement: All

function HealthTest-LocalAcntRequirePass {
<#
Description: Checks whether local accounts require passwords.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Tags: Essential
Uses: None.
#>
    $ok = $true
    $no_req_pass_accounts=Get-CimInstance -Class Win32_UserAccount -Filter `
        "LocalAccount=True AND Disabled=False AND PasswordRequired=False"
    if ($no_req_pass_accounts) {
        $no_req_pass_accounts | %{
            try {$account_name = $_.name} catch {$account_name="(FAILED_TO_GET_NAME)"}
            $ok = $false
            $comment =  "Make sure the account password is set and then run this command:`n& cmd /c 'net user `"$($_.name)`" /passwordreq:yes'"
            Write-Warning "[FAILURE] This local account has the property PasswordRequired set to false: $account_name`n$comment"
        }
    }
    if ($ok) {Write-Warning "[PASS] All local accounts have PasswordRequired True"}
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-LocalAcntRequirePass
}
