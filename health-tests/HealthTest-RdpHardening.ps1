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
  $isDomainJoined = $false
  try {
    $domainRole = [int](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).DomainRole
    $isServer = $domainRole -ge 2
    $isDomainJoined = $domainRole -in @(1, 3, 4, 5)
  } catch {}

  if ($nla -eq 1 -and $certBound) {
    Write-Warning "[PASS] RDP hardened: NLA enabled and a certificate is bound"
  } else {
    $commentLines = @(
      "Current state: NLA=$nla; CertBound=$(if($certBound){$true}else{$false})."
    )

    if ($nla -ne 1) {
      $commentLines += 'Impact: RDP reaches a later stage of connection setup before authenticating the user.'

      if ($isDomainJoined) {
        $commentLines += (
          'Related domain policy path: Computer Configuration\Policies\Administrative Templates\Windows Components\' +
          'Remote Desktop Services\Remote Desktop Session Host\Security\Require user authentication for remote ' +
          'connections by using Network Level Authentication.'
        )
      } else {
        $commentLines += "Related registry path: '$k\UserAuthentication'."
      }
    }

    if (-not $certBound) {
      $commentLines += (
        'Impact: Users may receive certificate warnings, increasing the risk that they accept a spoofed RDP endpoint.'
      )

      if ($isDomainJoined) {
        $commentLines += (
          'Related domain policy path: Computer Configuration\Policies\Administrative Templates\Windows Components\' +
          'Remote Desktop Services\Remote Desktop Session Host\Security\Server authentication certificate template.'
        )
      } else {
        $commentLines += "Related registry path: '$k\SSLCertificateSHA1Hash'."
      }
    }

    if ($isServer) {
      $level = 'WARNING'
    } else {
      $level = 'NOTICE'
    }

    if ($isServer) {
      $commentLines += 'This exposure is more significant on a server or domain controller.'
    }

    Write-Warning (
      "[$level] RDP is not hardened (NLA and/or TLS certificate binding missing)`n" +
      ($commentLines -join "`n")
    )
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-RdpHardening
}
