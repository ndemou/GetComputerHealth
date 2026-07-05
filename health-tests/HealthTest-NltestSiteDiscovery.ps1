<#
Standalone file for HealthTest-NltestSiteDiscovery.
Generated during the repo-wide health-test split.
#>
# HostRequirement: DomainJoined

function HealthTest-NltestSiteDiscovery {
<#
Description: Checks whether site discovery returns a valid AD site for the computer.
AppliesTo: DomainJoined
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Uses: nltest.exe.
#>
  [CmdletBinding()] param()

  $out  = nltest /dsgetsite 2>&1
  $exit = $LASTEXITCODE
  $txt  = ($out | Out-String).Trim()

  if ($exit -eq 0 -and $txt -match 'The command completed successfully') {
    $lines = $txt -split "`r?`n"
    $site  = $null
    foreach ($l in $lines) {
      if (-not $site -and $l -and $l -notmatch 'The command completed successfully') {
        $site = $l.Trim()
        break
      }
    }
    if (-not $site) { $site = '(unknown)' }
    Write-Warning "[PASS] NLTEST /dsgetsite succeeded.`nSite: $site"
  } else {
    $hex = '0x{0:X}' -f ($exit -band 0xFFFFFFFF)
    Write-Warning "[FAILURE] NLTEST /dsgetsite failed.`nExitCode=$hex; Output=`n$txt"
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-NltestSiteDiscovery
}
