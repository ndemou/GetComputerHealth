# HostRequirement: DC

function HealthTest-DisabledGpoLinksAtDomainRoot{
<#
Description: Checks for disabled or non-enforced GPO links at the domain root.
AppliesTo: DC
Scope: Domain
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: Get-GPO, Get-ADDomain.
#>

  if(-not (Get-Command Get-GPO -ErrorAction SilentlyContinue)){
    Write-Warning "[WARNING] GroupPolicy cmdlets not available; install RSAT/GPMC (GroupPolicy module)."; return
  }

  $root=$null
  if(Get-Command Get-ADDomain -ErrorAction SilentlyContinue){
    try{ $root=(Get-ADDomain).DistinguishedName }catch{}
  }
  if(-not $root){
    try{
      $dns=(Get-CimInstance Win32_ComputerSystem).Domain
      if(-not $dns -or $dns -eq 'WORKGROUP'){ throw "Not on a domain" }
      $root=($dns -split '\.')|ForEach-Object{"DC=$_"} -join ','
    }catch{
      Write-Warning "[WARNING] Cannot resolve domain root DN (need AD or machine joined to a domain)."; return
    }
  }

  $parseFailures=0
  $links=@()
  foreach($g in (Get-GPO -All -ErrorAction Stop)){
    try{
      $xml=[xml](Get-GPOReport -Guid $g.Id -ReportType Xml -ErrorAction Stop)
      foreach($lnk in @($xml.GPO.LinksTo.LinkTo)){
        if($lnk.SOMPath -eq $root){
          $links += [pscustomobject]@{
            DisplayName=$xml.GPO.Name
            Enabled= if($lnk.Enabled -eq 'true'){1}else{0}
            Enforced=if($lnk.NoOverride -eq 'true'){1}else{0}
            Order=[int]$lnk.Order
          }
        }
      }
    }catch{
      $parseFailures++
      $msg=($_.Exception.Message -replace '\s+',' ').Trim()
      Write-Warning "[WARNING] Failed to parse GPO report; skipping GPO: $($g.DisplayName) ($($g.Id)) - $msg"
    }
  }

  if($parseFailures -gt 0){
    Write-Warning "[WARNING] One or more GPO reports could not be read/parsed ($parseFailures). Results may be incomplete."}

  if(-not $links){
    Write-Warning "[PASS] No GPO links found at the domain root ($root)."; return
  }

  $flagged=$false
  foreach($l in $links){
    if($l.Enabled -eq 0){ $flagged=$true; Write-Warning "[WARNING] Domain-root GPO link is disabled: $($l.DisplayName)"}
    if($l.Enforced -eq 0){ $flagged=$true; Write-Warning "[WARNING] Domain-root GPO link is not enforced: $($l.DisplayName)"}
  }

  if(-not $flagged){ Write-Warning "[PASS] All domain-root GPO links are enabled (and enforced per policy)"}
  else{ Write-Warning "[FAILURE] There are disabled or non-enforced GPO links at the domain root"}
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-DisabledGpoLinksAtDomainRoot
}
