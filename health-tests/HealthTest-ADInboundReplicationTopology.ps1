# HostRequirement: DC

function HealthTest-ADInboundReplicationTopology{
<#
Description: Verifies that each domain controller has inbound AD replication partners and connection objects.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-ADDomainController, Get-ADReplicationPartnerMetadata, Get-ADObject.
#>
  $dcs = Get-ADDomainController -Filter *
  $anyFail = $false
  foreach($dc in $dcs){
    $meta = Get-ADReplicationPartnerMetadata -Target $dc.HostName -Scope Server -ErrorAction SilentlyContinue
    $metaCount = 0
    if ($meta) { $metaCount = (@($meta) | Measure-Object).Count }

    $q = @{
      SearchBase  = $dc.NTDSSettingsObjectDN
      SearchScope = 'OneLevel'
      LDAPFilter  = '(objectClass=nTDSConnection)'
      Properties  = 'enabledConnection'
      ErrorAction = 'SilentlyContinue'
    }
    $objs = Get-ADObject @q

    $enabledCount = 0
    foreach($o in @($objs)){
      $isEnabled = $true
      if ($null -ne $o.enabledConnection) { $isEnabled = [bool]$o.enabledConnection }
      if ($isEnabled) { $enabledCount++ }
    }

    if($metaCount -eq 0 -and $enabledCount -eq 0){
      $anyFail = $true
      $details = "PartnerMetadata=$metaCount; EnabledConnectionObjects=$enabledCount; NTDS=$($dc.NTDSSettingsObjectDN)"
      Write-Warning ("[FAILURE] No inbound replication detected for $($dc.HostName)" + "`n" + $details)
      continue
    }
    if($metaCount -eq 0 -and $enabledCount -gt 0){
      Write-Warning ("[NOTICE] Inbound connection objects exist but partner metadata returned none for {0}. Recheck with: repadmin /showrepl {0}" -f $dc.HostName)
    }
    if($metaCount -gt 0 -and $enabledCount -eq 0){
      Write-Warning "[NOTICE] Inbound partners reported by $($dc.HostName) but no enabled nTDSConnection objects under NTDS Settings. Possible permission/cache/KCC timing; investigate ISTG/KCC."
    }
  }
  if(-not $anyFail){ Write-Warning "[PASS] Inbound replication present for all DCs (partner metadata OK, NTDS container cross-check performed)" }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-ADInboundReplicationTopology
}
