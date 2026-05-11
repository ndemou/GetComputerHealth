function HealthTest-DhcpDnsCredential{
<#
Description: Verifies that DHCP dynamic DNS update credentials are configured and resolve to a valid AD account.
AppliesTo: Server
Scope: Computer
Category: Security & Stability Risks
Impact: High(Network)
Uses: Get-DhcpServerDnsCredential, Get-ADUser.
#>
  [CmdletBinding()] param([int]$MaxPwdAgeDays=365)
  $cred=Get-DhcpServerDnsCredential -ErrorAction SilentlyContinue
  if(-not $cred -or -not $cred.UserName){ Write-Warning "[FAILURE] No DHCP DNS update credentials configured"; return }
  $u=Get-ADUser -Identity $cred.UserName -Properties Enabled,pwdLastSet
  $age=[int]((Get-Date) - [DateTime]::FromFileTime($u.pwdLastSet)).TotalDays
  if(-not $u.Enabled){ Write-Warning "[FAILURE] DHCP DNS credential account is disabled: $($cred.UserName)"; return }
  if($age -gt $MaxPwdAgeDays){ Write-Warning "[FAILURE] DHCP DNS credential password age too high ($age days > $MaxPwdAgeDays): $($cred.UserName)" } else { Write-Warning "[PASS] DHCP DNS credential healthy (Enabled, pwd age $age days <= $MaxPwdAgeDays)" }
}
