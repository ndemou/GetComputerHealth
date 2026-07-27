# HostRequirement: All

function Get-CertExpiryPropertyValue {
    param(
        [Parameter(Mandatory=$true)]$InputObject,
        [Parameter(Mandatory=$true)][string]$Name
    )

    try {
        $property = $InputObject.PSObject.Properties[$Name]
        if ($null -ne $property) {
            return $property.Value
        }
    }
    catch {
        return $null
    }

    return $null
}

function ConvertTo-CertExpiryFindingValue {
    param($Value)

    if ($null -eq $Value) {
        return '(not reported)'
    }

    $text = $Value.ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return '(not reported)'
    }

    return $text.Replace("'", "''")
}

function Format-CertExpiryDate {
    param($Value)

    if ($null -eq $Value) {
        return '(not reported)'
    }

    try {
        $date = [datetime]$Value
        if ($date.Kind -eq [System.DateTimeKind]::Utc) {
            $date = $date.ToLocalTime()
        }
        return $date.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        return '(invalid date)'
    }
}

function Format-CertExpiryEnhancedKeyUsage {
    param([Parameter(Mandatory=$true)]$Certificate)

    $usageObjects = @(Get-CertExpiryPropertyValue -InputObject $Certificate -Name 'EnhancedKeyUsageList')
    $usageTexts = @()

    foreach ($usage in $usageObjects) {
        if ($null -eq $usage) {
            continue
        }

        $friendlyName = Get-CertExpiryPropertyValue -InputObject $usage -Name 'FriendlyName'
        $oidValue = Get-CertExpiryPropertyValue -InputObject $usage -Name 'Value'
        if ($null -eq $oidValue) {
            $objectId = Get-CertExpiryPropertyValue -InputObject $usage -Name 'ObjectId'
            if ($null -ne $objectId) {
                $oidValue = Get-CertExpiryPropertyValue -InputObject $objectId -Name 'Value'
            }
        }

        $friendlyNameText = ConvertTo-CertExpiryFindingValue -Value $friendlyName
        $oidValueText = ConvertTo-CertExpiryFindingValue -Value $oidValue
        if ($friendlyNameText -ne '(not reported)' -and $oidValueText -ne '(not reported)') {
            $usageTexts += "$friendlyNameText ($oidValueText)"
        }
        elseif ($friendlyNameText -ne '(not reported)') {
            $usageTexts += $friendlyNameText
        }
        elseif ($oidValueText -ne '(not reported)') {
            $usageTexts += $oidValueText
        }
    }

    if ($usageTexts.Count -eq 0) {
        return '(none reported)'
    }

    return ($usageTexts -join '; ')
}

function Get-CertExpiryFindingTitle {
    param(
        [Parameter(Mandatory=$true)]$Certificate,
        [Parameter(Mandatory=$true)][string]$Store,
        [string]$Summary = 'Certificate validity issue'
    )

    $subject = ConvertTo-CertExpiryFindingValue -Value (Get-CertExpiryPropertyValue -InputObject $Certificate -Name 'Subject')
    $issuer = ConvertTo-CertExpiryFindingValue -Value (Get-CertExpiryPropertyValue -InputObject $Certificate -Name 'Issuer')
    $serialNumber = ConvertTo-CertExpiryFindingValue -Value (Get-CertExpiryPropertyValue -InputObject $Certificate -Name 'SerialNumber')

    return "$($Summary): Store='$Store'; Subject='$subject'; Issuer='$issuer'; SerialNumber='$serialNumber'"
}

function Get-CertExpiryReplacementCandidate {
    param(
        [Parameter(Mandatory=$true)]$Certificate,
        [Parameter(Mandatory=$true)][array]$Certificates,
        [Parameter(Mandatory=$true)][datetime]$Now
    )

    $subject = ConvertTo-CertExpiryFindingValue -Value (Get-CertExpiryPropertyValue -InputObject $Certificate -Name 'Subject')
    $issuer = ConvertTo-CertExpiryFindingValue -Value (Get-CertExpiryPropertyValue -InputObject $Certificate -Name 'Issuer')
    $serialNumber = ConvertTo-CertExpiryFindingValue -Value (Get-CertExpiryPropertyValue -InputObject $Certificate -Name 'SerialNumber')
    $notAfterValue = Get-CertExpiryPropertyValue -InputObject $Certificate -Name 'NotAfter'
    if ($null -eq $notAfterValue) {
        return $null
    }

    try {
        $notAfter = [datetime]$notAfterValue
    }
    catch {
        return $null
    }

    $bestCandidate = $null
    $bestCandidateNotAfter = [datetime]::MinValue
    foreach ($candidate in $Certificates) {
        $candidateSubject = ConvertTo-CertExpiryFindingValue -Value (Get-CertExpiryPropertyValue -InputObject $candidate -Name 'Subject')
        if (-not [string]::Equals($candidateSubject, $subject, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $candidateIssuer = ConvertTo-CertExpiryFindingValue -Value (Get-CertExpiryPropertyValue -InputObject $candidate -Name 'Issuer')
        $candidateSerialNumber = ConvertTo-CertExpiryFindingValue -Value (Get-CertExpiryPropertyValue -InputObject $candidate -Name 'SerialNumber')
        $sameIssuer = [string]::Equals($candidateIssuer, $issuer, [System.StringComparison]::OrdinalIgnoreCase)
        $sameSerialNumber = [string]::Equals($candidateSerialNumber, $serialNumber, [System.StringComparison]::OrdinalIgnoreCase)
        if ($sameIssuer -and $sameSerialNumber) {
            continue
        }

        $candidateNotBeforeValue = Get-CertExpiryPropertyValue -InputObject $candidate -Name 'NotBefore'
        $candidateNotAfterValue = Get-CertExpiryPropertyValue -InputObject $candidate -Name 'NotAfter'
        if ($null -eq $candidateNotBeforeValue -or $null -eq $candidateNotAfterValue) {
            continue
        }

        try {
            $candidateNotBefore = [datetime]$candidateNotBeforeValue
            $candidateNotAfter = [datetime]$candidateNotAfterValue
        }
        catch {
            continue
        }

        if ($candidateNotBefore -gt $Now -or $candidateNotAfter -le $Now) {
            continue
        }
        if ($candidateNotAfter -le $notAfter) {
            continue
        }
        if ($candidateNotAfter -le $bestCandidateNotAfter) {
            continue
        }

        $bestCandidate = $candidate
        $bestCandidateNotAfter = $candidateNotAfter
    }

    return $bestCandidate
}

function HealthTest-CertExpiry {
<#
Description: Checks LocalMachine\My certificates for expiration and reports identity, validity, usage context, and remediation guidance.
AppliesTo: All
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: Medium(Time)
Tags: Essential
Uses: None.
The stable finding identity contains the store, subject, issuer, and serial number. It intentionally excludes the certificate thumbprint and volatile expiration details.
Expiration status, validity dates, private-key presence, enhanced key usages, a newer same-subject candidate, and remediation guidance are included in the finding comments.
Certificates expired for 60 days or more are notices because continued operation suggests that they were replaced or are no longer used; administrators must still verify bindings before removal.
Certificates with a total validity period of four days or less do not produce upcoming-expiry findings. Expired short-lived certificates are notices unless a newer currently valid certificate with the same subject exists, in which case they are included in an informational summary.
Expired Azure CRP certificates are summarized as informational noise only when a newer currently valid certificate with the same subject exists.
The certificate store has no universal reverse lookup for service or application bindings. Those references are stored separately by each product, so a same-subject certificate is only a candidate replacement and not proof that migration is complete.
#>
    param(
        [ValidateRange(0, 3650)][int]$WarnDays = 60,
        [ValidateRange(0, 3650)][int]$FailDays = 30
    )

    $store = 'LocalMachine\My'
    if ($WarnDays -lt $FailDays) {
        Write-Warning "[FAILURE] Certificate expiry test configuration issue: Store='$store'`nWarnDays ($WarnDays) must be greater than or equal to FailDays ($FailDays)."
        return
    }

    $now = Get-Date
    try {
        $certificates = @(Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction Stop)
    }
    catch {
        Write-Warning "[FAILURE] Certificate store inspection failed: Store='$store'`nError: $($_.Exception.Message)"
        return
    }

    if ($certificates.Count -eq 0) {
        Write-Warning "[info] No certificates found in Store='$store'"
        return
    }

    $findingCount = 0
    $shortLivedMaxDays = 4
    $suppressedShortLived = @()
    $suppressedAzureCrp = @()
    foreach ($certificate in $certificates) {
        $notAfterValue = Get-CertExpiryPropertyValue -InputObject $certificate -Name 'NotAfter'
        if ($null -eq $notAfterValue) {
            $title = Get-CertExpiryFindingTitle -Certificate $certificate -Store $store
            Write-Warning "[FAILURE] $title`nStatus: Expiration date was not reported.`nRecommended action: Inspect the certificate record and the certificate store provider."
            $findingCount++
            continue
        }

        try {
            $notAfter = [datetime]$notAfterValue
        }
        catch {
            $title = Get-CertExpiryFindingTitle -Certificate $certificate -Store $store
            Write-Warning "[FAILURE] $title`nStatus: Expiration date is invalid: '$(ConvertTo-CertExpiryFindingValue -Value $notAfterValue)'.`nRecommended action: Inspect the certificate record and the certificate store provider."
            $findingCount++
            continue
        }

        $isShortLived = $false
        $notBeforeDate = $null
        $notBeforeValue = Get-CertExpiryPropertyValue -InputObject $certificate -Name 'NotBefore'
        if ($null -ne $notBeforeValue) {
            try {
                $notBeforeDate = [datetime]$notBeforeValue
                $validityPeriod = $notAfter - $notBeforeDate
                if ($validityPeriod.TotalSeconds -gt 0 -and
                    $validityPeriod.TotalDays -le $shortLivedMaxDays) {
                    $isShortLived = $true
                }
            }
            catch {
                $isShortLived = $false
            }
        }

        if ($isShortLived -and
            $notBeforeDate -le $now -and
            $notAfter -gt $now) {
            $suppressedShortLived += [pscustomobject]@{
                Subject = ConvertTo-CertExpiryFindingValue -Value (Get-CertExpiryPropertyValue -InputObject $certificate -Name 'Subject')
                Issuer = ConvertTo-CertExpiryFindingValue -Value (Get-CertExpiryPropertyValue -InputObject $certificate -Name 'Issuer')
                SerialNumber = ConvertTo-CertExpiryFindingValue -Value (Get-CertExpiryPropertyValue -InputObject $certificate -Name 'SerialNumber')
                NotBefore = Format-CertExpiryDate -Value $notBeforeDate
                NotAfter = Format-CertExpiryDate -Value $notAfter
                Reason = 'Currently valid; fixed upcoming-expiry thresholds do not apply.'
                ReplacementSerialNumber = '(not applicable)'
                ReplacementExpires = '(not applicable)'
            }
            continue
        }

        $level = $null
        $status = $null
        if ($notAfter -lt $now) {
            $expiredDays = [int][Math]::Floor(($now - $notAfter).TotalDays)
            if ($expiredDays -lt 1) {
                $status = 'Expired less than one day ago.'
            }
            elseif ($expiredDays -eq 1) {
                $status = 'Expired 1 day ago.'
            }
            else {
                $status = "Expired $expiredDays days ago."
            }

            if ($expiredDays -ge 60) {
                $level = 'NOTICE'
            }
            else {
                $level = 'FAILURE'
            }
        }
        elseif ($notAfter.Date -eq $now.Date) {
            $level = 'FAILURE'
            $status = 'Expires today.'
        }
        else {
            $remainingDays = [int][Math]::Ceiling(($notAfter - $now).TotalDays)
            if ($remainingDays -le $FailDays) {
                $level = 'FAILURE'
                if ($remainingDays -eq 1) {
                    $status = 'Expires in 1 day.'
                }
                else {
                    $status = "Expires in $remainingDays days."
                }
            }
            elseif ($remainingDays -le $WarnDays) {
                $level = 'WARNING'
                $status = "Expires in $remainingDays days."
            }
        }

        if ($null -eq $level) {
            continue
        }

        $replacement = Get-CertExpiryReplacementCandidate -Certificate $certificate -Certificates $certificates -Now $now
        $subject = ConvertTo-CertExpiryFindingValue -Value (Get-CertExpiryPropertyValue -InputObject $certificate -Name 'Subject')
        if ($isShortLived) {
            if ($null -ne $replacement) {
                $suppressedShortLived += [pscustomobject]@{
                    Subject = $subject
                    Issuer = ConvertTo-CertExpiryFindingValue -Value (Get-CertExpiryPropertyValue -InputObject $certificate -Name 'Issuer')
                    SerialNumber = ConvertTo-CertExpiryFindingValue -Value (Get-CertExpiryPropertyValue -InputObject $certificate -Name 'SerialNumber')
                    NotBefore = Format-CertExpiryDate -Value $notBeforeDate
                    NotAfter = Format-CertExpiryDate -Value $notAfter
                    Reason = 'Expired; a newer currently valid certificate with the same subject exists.'
                    ReplacementSerialNumber = ConvertTo-CertExpiryFindingValue -Value (Get-CertExpiryPropertyValue -InputObject $replacement -Name 'SerialNumber')
                    ReplacementExpires = Format-CertExpiryDate -Value (Get-CertExpiryPropertyValue -InputObject $replacement -Name 'NotAfter')
                }
                continue
            }

            $level = 'NOTICE'
        }

        if ($notAfter -lt $now -and
            $subject -ieq 'DC=Windows Azure CRP Certificate Generator' -and
            $null -ne $replacement) {
            $suppressedAzureCrp += [pscustomobject]@{
                SerialNumber = ConvertTo-CertExpiryFindingValue -Value (Get-CertExpiryPropertyValue -InputObject $certificate -Name 'SerialNumber')
                Expired = Format-CertExpiryDate -Value $notAfter
                ReplacementSerialNumber = ConvertTo-CertExpiryFindingValue -Value (Get-CertExpiryPropertyValue -InputObject $replacement -Name 'SerialNumber')
                ReplacementExpires = Format-CertExpiryDate -Value (Get-CertExpiryPropertyValue -InputObject $replacement -Name 'NotAfter')
            }
            continue
        }

        $titleSummary = 'Certificate validity issue'
        if ($status -like 'Expires in *') {
            if ($level -eq 'FAILURE') {
                $titleSummary = 'Certificate will expire very soon'
            }
            elseif ($level -eq 'WARNING') {
                $titleSummary = 'Certificate will expire soon'
            }
        }

        $title = Get-CertExpiryFindingTitle -Certificate $certificate -Store $store -Summary $titleSummary
        $notBefore = Format-CertExpiryDate -Value (Get-CertExpiryPropertyValue -InputObject $certificate -Name 'NotBefore')
        $formattedNotAfter = Format-CertExpiryDate -Value $notAfter
        $friendlyName = ConvertTo-CertExpiryFindingValue -Value (Get-CertExpiryPropertyValue -InputObject $certificate -Name 'FriendlyName')
        $hasPrivateKeyValue = Get-CertExpiryPropertyValue -InputObject $certificate -Name 'HasPrivateKey'
        if ($null -eq $hasPrivateKeyValue) {
            $hasPrivateKey = '(not reported)'
        }
        elseif ([bool]$hasPrivateKeyValue) {
            $hasPrivateKey = 'Yes'
        }
        else {
            $hasPrivateKey = 'No'
        }
        $enhancedKeyUsages = Format-CertExpiryEnhancedKeyUsage -Certificate $certificate

        if ($null -ne $replacement) {
            $replacementSubject = ConvertTo-CertExpiryFindingValue -Value (Get-CertExpiryPropertyValue -InputObject $replacement -Name 'Subject')
            $replacementIssuer = ConvertTo-CertExpiryFindingValue -Value (Get-CertExpiryPropertyValue -InputObject $replacement -Name 'Issuer')
            $replacementSerialNumber = ConvertTo-CertExpiryFindingValue -Value (Get-CertExpiryPropertyValue -InputObject $replacement -Name 'SerialNumber')
            $replacementNotAfter = Format-CertExpiryDate -Value (Get-CertExpiryPropertyValue -InputObject $replacement -Name 'NotAfter')
            $replacementText = "Subject='$replacementSubject'; Issuer='$replacementIssuer'; SerialNumber='$replacementSerialNumber'; Expires='$replacementNotAfter' (local time). Confirm that required bindings moved before treating it as a replacement."
        }
        else {
            $replacementText = 'None found.'
        }

        if ($subject -like '*Azure Backup*') {
            $recommendedAction = 'Confirm recent Azure Backup jobs and required restore or encryption configuration. Renew or replace the certificate if still used; remove it only by following the Azure Backup or workload runbook.'
        }
        elseif ($subject -ieq 'DC=Windows Azure CRP Certificate Generator') {
            $recommendedAction = 'Check Azure VM Agent and extension health. Update or repair the agent if needed; remove stale CRP certificates only under the Azure VM extension cleanup guidance.'
        }
        elseif ($isShortLived -and $notAfter -lt $now) {
            $recommendedAction = 'Check the issuing or enrollment system that normally rotates this short-lived certificate. Confirm whether a service or application still uses it, and remove it only after confirming that it is unused.'
        }
        elseif ($notAfter -lt $now) {
            $recommendedAction = 'Identify whether a service or application still uses this certificate. Renew or replace it if needed; remove it only after confirming it is unused and following the owning product runbook.'
        }
        else {
            $recommendedAction = 'Identify the service or application using this certificate and renew or replace it before expiration.'
        }

        $commentLines = @(
            "Status: $status",
            "Validity: '$notBefore' through '$formattedNotAfter' (local time).",
            "Friendly name: '$friendlyName'.",
            "Has private key: $hasPrivateKey.",
            "Enhanced key usages: $enhancedKeyUsages.",
            "Newer valid same-subject candidate: $replacementText",
            'Binding check: Not performed because the Windows certificate store has no universal reverse lookup for references kept separately by services and applications. Confirm whether IIS, HTTP.sys, RDP, WinRM, SQL Server, Azure Backup, or another service references this certificate.',
            "Recommended action: $recommendedAction"
        )
        Write-Warning "[$level] $title`n$($commentLines -join "`n")"
        $findingCount++
    }

    if ($suppressedShortLived.Count -gt 0) {
        $suppressedDetails = @()
        foreach ($suppressedCertificate in $suppressedShortLived) {
            $suppressedDetails += "Subject='$($suppressedCertificate.Subject)'; Issuer='$($suppressedCertificate.Issuer)'; SerialNumber='$($suppressedCertificate.SerialNumber)'; Validity='$($suppressedCertificate.NotBefore)' through '$($suppressedCertificate.NotAfter)' (local time); Reason=$($suppressedCertificate.Reason); CandidateSerialNumber='$($suppressedCertificate.ReplacementSerialNumber)'; CandidateExpires='$($suppressedCertificate.ReplacementExpires)'."
        }

        $summaryLines = @(
            "Count: $($suppressedShortLived.Count).",
            "Definition: Total validity is no more than $shortLivedMaxDays days.",
            'Reason: Fixed upcoming-expiry thresholds are not useful for certificates designed with short validity periods.',
            'Suppressed certificates:',
            ($suppressedDetails -join "`n")
        )
        Write-Warning "[info] Short-lived certificate expiry findings suppressed`n$($summaryLines -join "`n")"
    }

    if ($suppressedAzureCrp.Count -gt 0) {
        $suppressedDetails = @()
        foreach ($suppressedCertificate in $suppressedAzureCrp) {
            $suppressedDetails += "SerialNumber='$($suppressedCertificate.SerialNumber)'; Expired='$($suppressedCertificate.Expired)'; CandidateSerialNumber='$($suppressedCertificate.ReplacementSerialNumber)'; CandidateExpires='$($suppressedCertificate.ReplacementExpires)' (local time)."
        }

        $summaryLines = @(
            "Count: $($suppressedAzureCrp.Count).",
            'Reason: Each expired Azure CRP certificate has a newer, currently valid certificate with the same subject.',
            'Suppressed certificates:',
            ($suppressedDetails -join "`n"),
            'Binding check: Not performed because the Windows certificate store has no universal reverse lookup for references kept separately by services and applications. If Azure VM Agent or extension operations are unhealthy, inspect the agent and extension state before removing certificates.'
        )
        Write-Warning "[info] Superseded Azure CRP certificate expiry findings suppressed`n$($summaryLines -join "`n")"
    }

    if ($findingCount -eq 0) {
        Write-Warning "[PASS] No reportable certificate expiry issues within $WarnDays days"
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    HealthTest-CertExpiry
}
