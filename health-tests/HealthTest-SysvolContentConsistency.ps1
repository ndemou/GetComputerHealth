<#
Standalone file for HealthTest-SysvolContentConsistency.
Generated during the repo-wide health-test split.
#>
# HostRequirement: DC

function HealthTest-SysvolContentConsistency{
<#
Description: Checks whether SYSVOL policy content is present and consistent across domain controllers.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: Get-ADDomainController.
#>

    $dom=(Get-CimInstance Win32_ComputerSystem).Domain
    $dcs=Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName

    $sigs = foreach($dc in $dcs){
      $p="\\$dc\SYSVOL\$dom\Policies"
      if(-not (Test-Path -LiteralPath $p)){
        Write-Warning "[FAILURE] SYSVOL Policies path missing on ${dc}: $p"
        [pscustomobject]@{DC=$dc;Sig='<missing>'}
        continue
      }
      $files = Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue
      $count = ($files | Measure-Object).Count
      [uint64]$total=0; foreach($f in $files){ $total += [uint64]$f.Length }
      [pscustomobject]@{DC=$dc;Sig=('' + $count + '|' + $total).Trim()}
    }

    # Compute uniqueness without Group-Object
    $uniqueSigs = @($sigs | Select-Object -ExpandProperty Sig -Unique)
    $hasMissing = $uniqueSigs -contains '<missing>'
    $allSame    = ($uniqueSigs.Count -eq 1) -and -not $hasMissing
    $map        = ($sigs | ForEach-Object { "$($_.DC)=$($_.Sig)" }) -join ' | '

    # Debug: show what PowerShell *thinks* are distinct values and their bytes
    write-verbose "`nDEBUG: Distinct Sig values ($uniqueSigs.Count):"
    $uniqueSigs | ForEach-Object {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($_)
      write-verbose "  '$_'  bytes=[$([System.BitConverter]::ToString($bytes))]"
    }

    if($allSame) {
      Write-Warning "[PASS] SYSVOL policy tree manifests match across all DCs"
    } elseif($hasMissing) {
      Write-Warning "[FAILURE] At least one DC lacks SYSVOL\Policies`n$map"
    } else {
      Write-Warning "[FAILURE] SYSVOL policy manifests are not consistent across DCs`n$map"
    }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-SysvolContentConsistency
}
