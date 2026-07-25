# HostRequirement: All

function HealthTest-SchanelBaseline{
<#
Description: Checks whether Schannel disables legacy protocols and keeps TLS 1.2 enabled.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Tags: Essential
Uses: None.
#>
  $base='HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols'
  function Get-EffState($proto,$role){
    $key=(Join-Path (Join-Path $base $proto) $role)
    $enabled=$null; $disabledByDefault=$null; $src='OS default'; $state='Enabled'
    if(Test-Path $key){
      try{
        $p=Get-ItemProperty -Path $key -ErrorAction Stop
        if($p.PSObject.Properties.Name -contains 'Enabled'){ $enabled=[uint32]$p.Enabled }
        if($p.PSObject.Properties.Name -contains 'DisabledByDefault'){ $disabledByDefault=[uint32]$p.DisabledByDefault }
      }catch{}
    }
    if($enabled -ne $null){
      if($enabled -eq 0){ $state='Disabled'; $src='Enabled=0' } else { $state='Enabled'; $src='Enabled=1/FFFF' }
    } else {
      if($disabledByDefault -ne $null -and $disabledByDefault -eq 1){ $state='Disabled'; $src='DisabledByDefault=1' } else { $state='Enabled'; $src='OS default' }
    }
    [pscustomobject]@{ Protocol=$proto; Role=$role; CurrentState=$state; Source=$src; EnabledRaw=$enabled; DisabledByDefaultRaw=$disabledByDefault; Key=$key }
  }

  $items=@()
  $items += Get-EffState 'SSL 3.0' 'Server'
  $items += Get-EffState 'TLS 1.0' 'Server'
  $items += Get-EffState 'TLS 1.1' 'Server'
  $items += Get-EffState 'TLS 1.2' 'Server'

  $should=@{
    'SSL 3.0'='Disabled'
    'TLS 1.0'='Disabled'
    'TLS 1.1'='Disabled'
    'TLS 1.2'='Enabled'
  }

  $bad=@()
  foreach($it in $items){
    $want=$should[$it.Protocol]
    if($it.CurrentState -ne $want){ $bad += $it }
  }

  $det=""
  foreach($it in $items){
    $e=$it.EnabledRaw; if($null -eq $e){ $e='<absent>' }
    $d=$it.DisabledByDefaultRaw; if($null -eq $d){ $d='<absent>' }
    $det += "    {0}\Server: Current={1}; Source={2}; Enabled={3}; DisabledByDefault={4}`n" -f $it.Protocol,$it.CurrentState,$it.Source,$e,$d
  }

  if($bad.Count -eq 0){
    Write-Warning "[PASS] Schannel baseline OK (SSL3/TLS1.0/TLS1.1 disabled, TLS1.2 enabled)"
  } else {
    $why="Inbound services that rely on Schannel may negotiate legacy TLS/SSL protocols if they remain enabled. E.g. IIS web server, RDP/RDS, AD DS/LDAPS, WinRM/ADWS(Remote PowerShell), encrypted SQL, OWA and other exchange componets, .Net apps & PowerShell scripts, RRAS/SSTP VPN."
    $comment = ($why + "`nDetected mismatches:`n"+($bad | ForEach-Object { "  - {0}: Current={1}, Recommended={2}" -f $_.Protocol,$_.CurrentState,$should[$_.Protocol] } | Out-String) + "`nRegistry snapshot:`n"+$det)
    Write-Warning ("[WARNING] Schannel baseline not hardened" + "`n" + $comment)
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-SchanelBaseline
}
