function HealthTest-DhcpDnsCredential{
<#
.SYNOPSIS
Checks Dhcp Dns Credential

.DESCRIPTION
AppliesTo: DomainJoined AND Server
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Get-DhcpServerDnsCredential.
FalsePositives: None.
#>
  [CmdletBinding()] param([int]$MaxPwdAgeDays=365)
  $cred=Get-DhcpServerDnsCredential -ErrorAction SilentlyContinue
  if(-not $cred -or -not $cred.UserName){ Write-Warning "[failure] No DHCP DNS update credentials configured"; return }
  $u=Get-ADUser -Identity $cred.UserName -Properties Enabled,pwdLastSet
  $age=[int]((Get-Date) - [DateTime]::FromFileTime($u.pwdLastSet)).TotalDays
  if(-not $u.Enabled){ Write-Warning "[failure] DHCP DNS credential account is disabled: $($cred.UserName)"; return }
  if($age -gt $MaxPwdAgeDays){ Write-Warning "[failure] DHCP DNS credential password age too high ($age days > $MaxPwdAgeDays): $($cred.UserName)" } else { Write-Warning "[pass] DHCP DNS credential healthy (Enabled, pwd age $age days <= $MaxPwdAgeDays)" }
}
