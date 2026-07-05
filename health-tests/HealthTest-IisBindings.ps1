<#
Standalone file for HealthTest-IisBindings.
Generated during the repo-wide health-test split.
#>
# HostRequirement: All

function HealthTest-IisBindings {
<#
Description: Checks IIS bindings for wildcard or otherwise risky binding configurations.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: low
Tags: Essential
Uses: Get-WindowsFeature, Get-Website, Get-WebBinding.
#>
    $iisInstalled = $false

    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
        $role = Get-WindowsFeature Web-Server -ErrorAction SilentlyContinue
        $iisInstalled = [bool]($role -and $role.Installed)
    }
    else {
        # Get-WindowsFeature is ServerManager-only (not available on many workstation SKUs).
        # Fall back to checking for an IIS core service that exists when IIS is installed.
        $w3svc = Get-Service W3SVC -ErrorAction SilentlyContinue
        $iisInstalled = [bool]$w3svc
    }

    if (-not $iisInstalled) {
        Write-Warning "[info] No IIS installed; skiping HealthTest-IisBindings"
        return
    }
    $problem_found = $false
    $sites = Get-Website
    foreach ($s in $sites) {
      $b = Get-WebBinding -Name $s.Name
      foreach ($x in $b) {
        if ($x.protocol -eq 'http' -and ($x.bindingInformation -like '*:80:*') -and ($sites.count -gt 1)) {
            $commnet = ""
            if ($sites.count -gt 1) {$comment = "`nSince multiple sites are hosted, wildcard bindins may expose unintended content"}
            Write-Warning "[NOTICE] $($s.Name): site serves plain HTTP with wildcard bindings$comment"
            $problem_found = $true
        }
        if ($x.protocol -eq 'https' -and ($x.bindingInformation -like '*:443:*') -and -not $x.certificateHash) {
            Write-Warning "[WARNING] $($s.Name): site is configured for HTTPS, but it has no certificate assigned"
            $problem_found = $true
        }
      }
    }
    if ($problem_found) {return}
    Write-Warning "[PASS] IIS bindings look sane"
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-IisBindings
}
