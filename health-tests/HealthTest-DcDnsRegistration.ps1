# HostRequirement: DC

function HealthTest-DcDnsRegistration {
<#
Description: Checks whether this domain controller has registered its expected DNS records.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Network)
Uses: Resolve-DnsName.
#>
    [CmdletBinding()]
    param()

    try {
        $role = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).DomainRole
        if ($role -notin (0..5)) { throw 'Win32_ComputerSystem returned no valid DomainRole.' }
    } catch {
        Write-Warning "[WARNING] Could not determine whether this computer is a domain controller`n$($_.Exception.Message)"
        return
    }
    if ($role -notin 4, 5) {
        Write-Warning '[INFO] DC DNS registration check applies only to domain controllers'
        return
    }

    $domain = $env:USERDNSDOMAIN
    $dcFqdn = "$($env:COMPUTERNAME).$domain"

    if (-not $domain) {
        Write-Warning "[debug] USERDNSDOMAIN is not set`nThis computer does not appear to have a domain DNS context in the current session."
        return
    }

    $checks = @(
        [pscustomobject]@{
            Name = 'HostARecord'
            QueryName = $dcFqdn
            Type = 'A'
            Test = {
                @(Resolve-DnsName $dcFqdn -Type A -ErrorAction Stop)
            }
            Detail = {
                param($result)
                (($result | Select-Object -ExpandProperty IPAddress) -join ', ')
            }
        }
        [pscustomobject]@{
            Name = 'LdapDcSrv'
            QueryName = "_ldap._tcp.dc._msdcs.$domain"
            Type = 'SRV'
            Test = {
                @(Resolve-DnsName "_ldap._tcp.dc._msdcs.$domain" -Type SRV -ErrorAction Stop | Where-Object { $_.NameTarget -eq $dcFqdn })
            }
            Detail = {
                param($result)
                (($result | ForEach-Object { "$($_.NameTarget):$($_.Port)" }) -join ', ')
            }
        }
        [pscustomobject]@{
            Name = 'KerberosDcSrv'
            QueryName = "_kerberos._tcp.dc._msdcs.$domain"
            Type = 'SRV'
            Test = {
                @(Resolve-DnsName "_kerberos._tcp.dc._msdcs.$domain" -Type SRV -ErrorAction Stop | Where-Object { $_.NameTarget -eq $dcFqdn })
            }
            Detail = {
                param($result)
                (($result | ForEach-Object { "$($_.NameTarget):$($_.Port)" }) -join ', ')
            }
        }
    )

    $issueFound = $false

    foreach ($check in $checks) {
        $result = $null
        try {
            $result = & $check.Test
        } catch {
            $issueFound = $true
            $synopsis = "DNS record $($check.Name) for this domain controller is missing or unresolved"
            $details = "`nQuery: $($check.QueryName)`nType: $($check.Type)`nError: $($_.Exception.Message)"
            Write-Warning "[NOTICE] $synopsis$details"
            continue
        }

        if (-not $result) {
            $issueFound = $true
            $synopsis = "DNS record $($check.Name) for this domain controller is missing"
            $details = "`nQuery: $($check.QueryName)`nType: $($check.Type)`nExpected target: $dcFqdn"
            Write-Warning "[NOTICE] $synopsis$details"
            continue
        }

        $synopsis = "DNS record $($check.Name) for this domain controller exists"
        $details = "`nQuery: $($check.QueryName)`nType: $($check.Type)`nValue: $(& $check.Detail $result)"
        Write-Warning "[debug] $synopsis$details"
    }

    if (-not $issueFound) {
        $synopsis = "All tested DNS records for this domain controller exist"
        $details = "`nDomain controller: $dcFqdn"
        Write-Warning "[PASS] $synopsis$details"
    }
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-DcDnsRegistration
}
