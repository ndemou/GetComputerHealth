<#
Domain Controller Discovery
#>

function Get-DomainControllers {
<#
.SYNOPSIS
Returns a list of all Domain Controllers(FQDNs) using DNS SRV records.

.DESCRIPTION
Queries _ldap._tcp.dc._msdcs.<domain> via Resolve-DnsName and returns a unique set of DC hostnames.

.OUTPUTS
[System.String[]] hostnames (no trailing dot), case-insensitive unique list.

.EXAMPLE
Get-DomainControllers
Gets DCs for the current logon domain.

.NOTES
Throws if no domain can be inferred. Requires DNS reachability.
#>

  $Domain = (Get-CimInstance Win32_ComputerSystem).Domain

  if (-not $Domain) { throw "No domain detected." }
  $results = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)

  try {
    if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
      $srv = Resolve-DnsName -Type SRV ("_ldap._tcp.dc._msdcs.{0}" -f $Domain) -ErrorAction Stop
      foreach ($r in $srv) {
        if ($r.NameTarget) { [void]$results.Add(($r.NameTarget.TrimEnd('.'))) }
      }
    }
  } catch {}
  return $results
}

