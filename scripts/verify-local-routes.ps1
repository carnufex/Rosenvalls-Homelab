param(
    [string]$GatewayIp = "192.168.1.220",
    [string[]]$Hosts = @(
        "radarr.rosenvall.local",
        "sonarr.rosenvall.local",
        "jackett.rosenvall.local",
        "seerr.rosenvall.local",
        "overseerr.rosenvall.local",
        "deluge.rosenvall.local",
        "plex.rosenvall.local",
        "authentik.rosenvall.local",
        "grafana.rosenvall.local",
        "prometheus.rosenvall.local",
        "longhorn.rosenvall.local"
    )
)

. (Join-Path $PSScriptRoot "pvc-seed-utils.ps1")

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
Set-HomelabKubeconfig
Assert-Command -Name "curl.exe"

function Invoke-CurlStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$ResolveHost
    )

    $stdout = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString("n") + ".out")
    $stderr = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString("n") + ".err")
    $arguments = @(
        "--silent",
        "--show-error",
        "--max-redirs", "0",
        "--max-time", "15",
        "--output", "NUL",
        "--write-out", "%{http_code}|%{redirect_url}",
        "--resolve", $ResolveHost,
        "-k",
        $Url
    )

    $process = Start-Process -FilePath "curl.exe" -ArgumentList $arguments -NoNewWindow -PassThru -Wait -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $line = (Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue).Trim()
    Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue

    if (-not $line) {
        return [pscustomobject]@{
            Status   = "ERR($($process.ExitCode))"
            Redirect = ""
        }
    }

    $parts = $line -split "\|", 2
    return [pscustomobject]@{
        Status   = $parts[0]
        Redirect = if ($parts.Count -gt 1) { $parts[1] } else { "" }
    }
}

$results = foreach ($hostname in @("rosenvall.local") + $Hosts) {
    $https = Invoke-CurlStatus -Url "https://$hostname/" -ResolveHost "$hostname`:443:$GatewayIp"
    $http = Invoke-CurlStatus -Url "http://$hostname/" -ResolveHost "$hostname`:80:$GatewayIp"

    [pscustomobject]@{
        Host         = $hostname
        HttpsStatus  = $https.Status
        HttpsRedirect = $https.Redirect
        HttpStatus   = $http.Status
        HttpRedirect = $http.Redirect
    }
}

$aliasHttps = Invoke-CurlStatus -Url "https://hub-central.rosenvall.local/" -ResolveHost "hub-central.rosenvall.local`:443:$GatewayIp"
$aliasHttp = Invoke-CurlStatus -Url "http://hub-central.rosenvall.local/" -ResolveHost "hub-central.rosenvall.local`:80:$GatewayIp"

$results | Format-Table -AutoSize
Write-Host ""
Write-Host "Hub Central alias HTTPS: $($aliasHttps.Status) -> $($aliasHttps.Redirect)" -ForegroundColor Cyan
Write-Host "Hub Central alias HTTP : $($aliasHttp.Status) -> $($aliasHttp.Redirect)" -ForegroundColor Cyan
