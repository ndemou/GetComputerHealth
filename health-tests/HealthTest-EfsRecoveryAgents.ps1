# HostRequirement: DomainJoined

function HealthTest-EfsRecoveryAgents{
<#
Description: Checks whether EFS recovery agents are configured.
AppliesTo: DomainJoined
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Tags: Essential
Uses: certutil.exe.
#>
  $out=& certutil -recoveryagent 2>&1
  $has=($out | Select-String -Pattern 'Recovery Agent' -SimpleMatch)
  if($has){ Write-Warning "[PASS] EFS Data Recovery Agents are configured"} else { Write-Warning "[NOTICE] No EFS Data Recovery Agents configured.`n*IF* EFS (NTFS file encryption) is used, there's no domain recovery agent to decrypt data if the user's key is lost." }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-EfsRecoveryAgents
}
