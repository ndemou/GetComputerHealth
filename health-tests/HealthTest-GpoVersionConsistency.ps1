# HostRequirement: DC

function HealthTest-GpoVersionConsistency{
<#
Description: Checks whether each GPO has matching AD and SYSVOL version numbers.
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-GPO.
#>
    $dom=(Get-CimInstance Win32_ComputerSystem).Domain
    $base="\\$dom\SYSVOL\$dom\Policies"
    $bad=$false
    foreach($g in Get-GPO -All){
      $ini="$base\{$($g.Id)}\gpt.ini"
      $gptVer = if(Test-Path $ini){ [int]((Get-Content $ini | where {$_ -match '^Version='}) -replace 'Version=','') } else { -1 }
      if($gptVer -lt 0){ $bad=$true; Write-Warning "[FAILURE] GPO missing GPT: $($g.DisplayName)"; continue }
      $uGpt=$gptVer -shr 16; $cGpt=$gptVer -band 0xFFFF
      if($uGpt -ne $g.User.DSVersion -or $cGpt -ne $g.Computer.DSVersion){
        $bad=$true
        Write-Warning "[FAILURE] GPO GPT/AD version mismatch: '$($g.DisplayName)' User AD=$($g.User.DSVersion) GPT=$uGpt; Computer AD=$($g.Computer.DSVersion) GPT=$cGpt"
      }
    }
  if(-not $bad){ Write-Warning "[PASS] All GPOs have matching GPT/GPC versions" }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-GpoVersionConsistency
}
