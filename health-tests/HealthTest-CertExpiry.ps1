<#
Standalone file for HealthTest-CertExpiry.
Generated during the repo-wide health-test split.
#>
# HostRequirement: All

function HealthTest-CertExpiry {
<#
Description: Checks for certificates that are expired or nearing expiration.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Tags: Essential
Uses: None.
#>
    param([int]$WarnDays=60,[int]$FailDays=30)
    $now = Get-Date
    $certs = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue
    $problem_found = $false
    if (-not $certs) { Write-Warning "[info] No certificates in LocalMachine\My"; return }
    $fail = @(); $warn = @()
    foreach ($c in $certs) {
      $days = ($c.NotAfter - $now).TotalDays
      if ($days -le -60) { $warn += "$($c.Subject) :: expired long time ago $($c.NotAfter)" }
      elseif ($days -le -1) { $fail += "$($c.Subject) :: expired recently $($c.NotAfter)" }
      elseif ($days -eq 0) { $fail += "$($c.Subject) :: expires today $($c.NotAfter)" }
      elseif ($days -le $FailDays) { $fail += "$($c.Subject) :: will expire soon, at $($c.NotAfter)" }
      elseif ($days -le $WarnDays) { $warn += "$($c.Subject) :: will expire within $WarnDays, at $($c.NotAfter)" }
    }
    if ($problem_found) {return}
    Write-Warning "[PASS] No certificates expiring within $WarnDays days"
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-CertExpiry
}
