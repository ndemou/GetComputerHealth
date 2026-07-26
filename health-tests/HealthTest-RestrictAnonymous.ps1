# HostRequirement: All

if (-not (Get-Command -Name 'Test-IsDomainJoinedComputer' -CommandType Function -ErrorAction SilentlyContinue)) {
  . (Join-Path -Path $PSScriptRoot -ChildPath 'helpers-for-healthtests.ps1')
}

function HealthTest-RestrictAnonymous {
<#
Description: Checks whether anonymous access hardening settings meet the baseline.
AppliesTo: All
Scope: Computer
Category: Security & Stability Risks
Impact: Medium(Time)
Tags: Essential
Uses: None.
#>
  $p  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
  $ra = (Get-ItemProperty $p -Name restrictanonymous      -ErrorAction SilentlyContinue).restrictanonymous
  $rs = (Get-ItemProperty $p -Name restrictanonymoussam   -ErrorAction SilentlyContinue).restrictanonymoussam
  $ea = (Get-ItemProperty $p -Name EveryoneIncludesAnonymous -ErrorAction SilentlyContinue).EveryoneIncludesAnonymous

  $pass = ($rs -eq 1 -and $ea -eq 0)
  $details="RestrictAnonymous=$ra; RestrictAnonymousSAM=$rs; EveryoneIncludesAnonymous=$ea"
  $isDomainJoined = Test-IsDomainJoinedComputer

  if($pass){
    Write-Warning "[PASS] Anonymous access hardening (baseline met)`n$details"
  } else {
    $commentLines = @(
      "$details.",
      'Recommended hardening: Set RestrictAnonymousSAM=1 and EveryoneIncludesAnonymous=0.'
    )

    if ($isDomainJoined) {
      $commentLines += (
        'Related domain policy path: Computer Configuration\Policies\Windows Settings\Security Settings\Local Policies\' +
        'Security Options\Network access: Do not allow anonymous enumeration of SAM accounts.'
      )
      $commentLines += (
        'Related domain policy path: Computer Configuration\Policies\Windows Settings\Security Settings\Local Policies\' +
        'Security Options\Network access: Let Everyone permissions apply to anonymous users.'
      )
    } else {
      $commentLines += "Related registry path: '$p\RestrictAnonymousSAM'."
      $commentLines += "Related registry path: '$p\EveryoneIncludesAnonymous'."
    }

    Write-Warning (
      "[FAILURE] Anonymous access hardening not at baseline`n" +
      ($commentLines -join "`n")
    )
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-RestrictAnonymous
}
