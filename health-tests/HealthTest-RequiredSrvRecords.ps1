<#
Standalone file for HealthTest-RequiredSrvRecords.
Generated during the repo-wide health-test split.
#>
# HostRequirement: DomainJoined

function HealthTest-RequiredSrvRecords{
<#
Description: Checks whether required AD DNS SRV records resolve successfully.
AppliesTo: DomainJoined
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Tags: Essential
Uses: Resolve-DnsName.
#>
  $dom=(Get-CimInstance Win32_ComputerSystem).Domain
  $labels=@("_ldap._tcp.dc._msdcs.$dom","_kerberos._tcp.$dom","_kerberos._udp.$dom")
  $missing=$false
  foreach($q in $labels){
    try{ $r=Resolve-DnsName -Type SRV $q -ErrorAction Stop }catch{$r=$null}
    if(-not $r){ $missing=$true; Write-Warning "[FAILURE] Required SRV record missing: $q" }
  }
  if(-not $missing){ Write-Warning "[PASS] Required AD SRV records present" }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-RequiredSrvRecords
}
