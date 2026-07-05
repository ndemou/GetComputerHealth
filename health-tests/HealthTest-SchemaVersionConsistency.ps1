<#
Standalone file for HealthTest-SchemaVersionConsistency.
Generated during the repo-wide health-test split.
#>
# HostRequirement: DC

function HealthTest-SchemaVersionConsistency{
<#
Description: Checks whether all domain controllers report the same AD schema version.
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Uses: Get-ADRootDSE, Get-ADDomainController, Get-ADObject.
#>
  $schemaNC=(Get-ADRootDSE).schemaNamingContext
  $vers=@{}; $errs=@()
  foreach($dc in (Get-ADDomainController -Filter *)){
    try{
      $ov=(Get-ADObject -Identity $schemaNC -Server $dc.HostName -Properties objectVersion -ErrorAction Stop).objectVersion
      if($null -eq $ov -or "$ov" -eq ''){
        $msg="$($dc.HostName): objectVersion missing"; $errs+=$msg; Write-Warning "[FAILURE] $msg"; continue
      }
      $ov=[int]("$ov".Trim()); $vers[$dc.HostName]=$ov
    }catch{
      $msg="$($dc.HostName): $($_.Exception.Message)"; $errs+=$msg; Write-Warning "[FAILURE] $msg"
    }
  }

  if($vers.Count -eq 0){
    Write-Warning ("[FAILURE] AD schema version consistency`nNo schema versions retrieved. Errors: " + ($errs -join ' | '))
    return
  }

  # Force array so .Count and [0] are always valid even when only one element
  $distinct = @($vers.Values | Sort-Object -Unique)
  $distinctCount = $distinct.Count

  $perDc = ($vers.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; '

  $det = if ($distinctCount -eq 1) {
    "SchemaVersion=$($distinct[0]); $perDc"
  } else {
    "Mismatch: "+($distinct -join ', ')+" | "+$perDc
  }

  if($errs){ $det += " | Errors: "+($errs -join ' | ') }

  $pass = ($distinctCount -eq 1 -and $errs.Count -eq 0)

  if($pass){
    Write-Warning "[PASS] AD schema version consistent across DCs ($det)"
  } else {
    Write-Warning "[FAILURE] AD schema version consistent across DCs`n$det"
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-SchemaVersionConsistency
}
