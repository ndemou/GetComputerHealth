<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:47.041Z","completions":[]} -->

GitHub source: [#137](https://github.com/ndemou/GetComputerHealth/issues/137)
Related TAT task: [t@ur96 Run eligible health tests once per domain or forest](./t%40ur96%2C%20p5%2C%20FEATURE%2C%20Run%20eligible%20health%20tests%20once%20per%20domain%20or%20forest.md)

Here's how to use the function below

```
C:\> Get-SslCertificateDaysRemaining -Url https://wiki.enlogic.gr
197 # days remaining until cert expires
```

I can add this function to helpers for custom health tests.

I can write a custom health test on DC01 & DC02 until I have the mechanism
to only run a test once per domain at which point I can add it to the
domain and the first domain server that runs will execute it and
add a flag so that the others don't run it too.


```
function Get-SslCertificateDaysRemaining {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Url,

        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds = 10
    )

    if ($Url -notmatch '^[a-z][a-z0-9+.-]*://') {
        $Url = "https://$Url"
    }

    try {
        $uri = [Uri]$Url
    }
    catch {
        throw "Invalid URL: $Url"
    }

    if ($uri.Scheme -ne 'https') {
        throw "The URL must use HTTPS: $Url"
    }

    $serverName = $uri.DnsSafeHost
    $port = if ($uri.IsDefaultPort) { 443 } else { $uri.Port }

    $tcpClient = $null
    $sslStream = $null
    $asyncWaitHandle = $null

    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $asyncResult = $tcpClient.BeginConnect(
            $serverName,
            $port,
            $null,
            $null
        )

        $asyncWaitHandle = $asyncResult.AsyncWaitHandle

        if (-not $asyncWaitHandle.WaitOne($TimeoutSeconds * 1000)) {
            throw "Connection to $($serverName):$port timed out."
        }

        $tcpClient.EndConnect($asyncResult)

        $validationCallback =
            [System.Net.Security.RemoteCertificateValidationCallback] {
                param(
                    $sender,
                    $certificate,
                    $chain,
                    $sslPolicyErrors
                )

                return $true
            }

        $sslStream = New-Object System.Net.Security.SslStream(
            $tcpClient.GetStream(),
            $false,
            $validationCallback
        )

        $sslStream.AuthenticateAsClient($serverName)

        if ($null -eq $sslStream.RemoteCertificate) {
            throw "The server did not provide an SSL certificate."
        }

        $certificate =
            New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
                $sslStream.RemoteCertificate
            )

        [math]::Floor(
            (
                $certificate.NotAfter.ToUniversalTime() -
                [DateTime]::UtcNow
            ).TotalDays
        )
    }
    finally {
        if ($null -ne $asyncWaitHandle) {
            $asyncWaitHandle.Dispose()
        }

        if ($null -ne $sslStream) {
            $sslStream.Dispose()
        }

        if ($null -ne $tcpClient) {
            $tcpClient.Close()
        }
    }
}
```
