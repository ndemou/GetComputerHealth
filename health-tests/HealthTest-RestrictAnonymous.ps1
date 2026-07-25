# HostRequirement: All

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

  if($pass){
    Write-Warning "[PASS] Anonymous access hardening (baseline met)`n$details"
  } else {
    Write-Warning "[FAILURE] Anonymous access hardening not at baseline`n$details. Recommendation: Set RestrictAnonymousSAM=1 and EveryoneIncludesAnonymous=0 via GPO."
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-RestrictAnonymous
}
