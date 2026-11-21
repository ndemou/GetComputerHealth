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
    $sites = @(Get-Website)
    foreach ($s in $sites) {
      $b = Get-WebBinding -Name $s.Name
      foreach ($x in $b) {
        if ($x.protocol -notin 'http', 'https') { continue }

        # Match the port and host from the right, leaving IPv6 colons in the address.
        $binding = [regex]::Match([string]$x.bindingInformation, '^(?<address>\S*):(?<port>[0-9]+):(?<hostname>[^:\s]*)$')
        $address = $binding.Groups['address'].Value
        $port = 0
        $ip = $null
        if (-not $binding.Success -or
            -not [int]::TryParse($binding.Groups['port'].Value, [ref]$port) -or
            $port -lt 1 -or $port -gt 65535 -or
            ($address -notin '', '*' -and -not [ipaddress]::TryParse($address, [ref]$ip))) {
            Write-Warning "[WARNING] $($s.Name): Could not parse IIS $($x.protocol) binding`n$($x.bindingInformation)"
            $problem_found = $true
            continue
        }

        $allAddresses = $address -in '', '*' -or $ip -in [ipaddress]::Any, [ipaddress]::IPv6Any
        if ($x.protocol -eq 'http' -and $port -eq 80 -and $allAddresses -and
            -not $binding.Groups['hostname'].Value -and $sites.Count -gt 1) {
            $comment = "`nSince multiple sites are hosted, wildcard bindings may expose unintended content"
            Write-Warning "[NOTICE] $($s.Name): site serves plain HTTP with wildcard bindings$comment"
            $problem_found = $true
        }
        if ($x.protocol -eq 'https' -and $port -eq 443 -and -not $x.certificateHash) {
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
