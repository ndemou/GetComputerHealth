<#
Standalone file for HealthTest-DuplicateSpn.
Generated during the repo-wide health-test split.
#>
# HostRequirement: DC

function HealthTest-DuplicateSpn{
<#
Description: Checks for duplicate Service Principal Names in Active Directory.
AppliesTo: DC
Scope: Forest
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: Get-ADObject.
#>
  $objs = Get-ADObject -LDAPFilter "(servicePrincipalName=*)" -Properties servicePrincipalName,sAMAccountName,distinguishedName -ErrorAction Stop
  if(-not $objs){ Write-Warning "[PASS] No objects with SPN found"; return }

  $map = @{}
  foreach($o in $objs){
    $acct = if($o.sAMAccountName){ $o.sAMAccountName } else { $o.distinguishedName }
    foreach($spn in @($o.servicePrincipalName)){
      if([string]::IsNullOrEmpty($spn)){ continue }
      if($map.ContainsKey($spn)){ $map[$spn] += $acct } else { $map[$spn] = @($acct) }
    }
  }

  $dupsFound=$false
  foreach($spn in $map.Keys){
    $owners = @($map[$spn] | Sort-Object -Unique)
    if($owners.Count -gt 1){
      $dupsFound=$true
      Write-Warning ("[FAILURE] Duplicate SPN detected`n$spn -> " + ($owners -join ', '))
    }
  }
  if(-not $dupsFound){ Write-Warning "[PASS] No duplicate SPNs detected" }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-DuplicateSpn
}
