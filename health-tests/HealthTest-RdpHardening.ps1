# HostRequirement: All

function HealthTest-RdpHardening {
<#
Description: Checks whether RDP is hardened with NLA enabled and a TLS certificate bound.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Network)
Tags: Essential
Uses: None.
#>
  $k = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'

  $bag  = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
  $nla  = if ($bag -and $bag.PSObject.Properties['UserAuthentication'])     { $bag.PSObject.Properties['UserAuthentication'].Value }     else { $null }
  $cert = if ($bag -and $bag.PSObject.Properties['SSLCertificateSHA1Hash']) { $bag.PSObject.Properties['SSLCertificateSHA1Hash'].Value } else { $null }

  $certBound = ($null -ne $cert) -and ($cert.Trim() -ne '')

  $isServer = $false
  try { $isServer = ((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).DomainRole -ge 2) } catch {}

  if ($nla -eq 1 -and $certBound) {
    Write-Warning "[PASS] RDP hardened: NLA enabled and a certificate is bound"
  } else {
    $sev = "Severity: Medium. Risk: Users may click through name-mismatch warnings; increases MITM risk on first-connect or via spoofing." + $(if($isServer){ " On a DC this is sensitive." } else { "" })
    $rdpState = "NLA=$nla; CertBound=$(if($certBound){$true}else{$false})"
    if ($isServer) {
      Write-Warning "[WARNING] RDP is not hardened (NLA and/or TLS certificate binding missing)`n$rdpState`n$sev"
    } else {
      Write-Warning "[NOTICE] RDP is not hardened (NLA and/or TLS certificate binding missing)`n$rdpState`n$sev"
    }
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-RdpHardening
}
