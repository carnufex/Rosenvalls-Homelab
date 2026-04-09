param(
    [string]$SourceRoot = "C:\Users\Crille\Downloads\media",
    [string]$Namespace = "media"
)

. (Join-Path $PSScriptRoot "pvc-seed-utils.ps1")

$ErrorActionPreference = "Stop"
Set-HomelabKubeconfig

function Remove-RuntimeFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Get-ChildItem -LiteralPath $Path -Recurse -Force -File -Include ".ha_run.lock","*.pid","deluged.pid" | Remove-Item -Force -ErrorAction SilentlyContinue
}

function Update-JackettConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $config.LocalBindAddress = "0.0.0.0"
    $config.AllowExternal = $true
    $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Update-OverseerrConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $settings = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $settings.main.applicationUrl = "https://overseerr.rosenvall.local"
    $settings.main.trustProxy = $true

    foreach ($entry in $settings.radarr) {
        $entry.hostname = "radarr.media.svc.cluster.local"
        $entry.port = 7878
        $entry.useSsl = $false
    }

    foreach ($entry in $settings.sonarr) {
        $entry.hostname = "sonarr.media.svc.cluster.local"
        $entry.port = 8989
        $entry.useSsl = $false
    }

    if ($settings.plex) {
        $settings.plex.name = "k8s-plex"
        $settings.plex.ip = "plex.media.svc.cluster.local"
        $settings.plex.port = 32400
        $settings.plex.useSsl = $false
    }

    $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Update-HomeAssistantConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $configLines = Get-Content -LiteralPath $Path
    $outputLines = New-Object System.Collections.Generic.List[string]
    $insideHttpBlock = $false
    $replacedHttpBlock = $false

    foreach ($line in $configLines) {
        if (-not $insideHttpBlock -and $line -match '^http:\s*$') {
            $insideHttpBlock = $true
            $replacedHttpBlock = $true
            $outputLines.Add("http:")
            $outputLines.Add("  use_x_forwarded_for: true")
            $outputLines.Add("  trusted_proxies:")
            $outputLines.Add("    - 192.168.1.0/24")
            $outputLines.Add("    - 10.0.0.0/8")
            $outputLines.Add("    - 127.0.0.1")
            continue
        }

        if ($insideHttpBlock) {
            if ($line -match '^\S') {
                $insideHttpBlock = $false
                $outputLines.Add($line)
            }
            continue
        }

        $outputLines.Add($line)
    }

    if (-not $replacedHttpBlock) {
        $outputLines.Add("")
        $outputLines.Add("http:")
        $outputLines.Add("  use_x_forwarded_for: true")
        $outputLines.Add("  trusted_proxies:")
        $outputLines.Add("    - 192.168.1.0/24")
        $outputLines.Add("    - 10.0.0.0/8")
        $outputLines.Add("    - 127.0.0.1")
    }

    Set-Content -LiteralPath $Path -Value $outputLines -Encoding utf8
}

function Invoke-PvcPostSeedMutation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Namespace,
        [Parameter(Mandatory = $true)]
        [string]$ClaimName,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    $podName = New-PvcHelperPod -Namespace $Namespace -ClaimName $ClaimName
    try {
        & $Action $podName
    }
    finally {
        Remove-PvcHelperPod -Namespace $Namespace -PodName $podName
    }
}

function Get-RenderedDelugeWireGuardConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $content = Get-Content -LiteralPath $Path -Raw
    $postUp = "PostUp = LAN_GW=`$(ip -4 route list default | awk 'NR==1{print `$3}'); ip route replace 10.96.0.0/12 via `$LAN_GW dev eth0; ip route replace 10.244.0.0/16 via `$LAN_GW dev eth0; ip route replace 192.168.1.0/24 via `$LAN_GW dev eth0"
    $postDown = "PostDown = LAN_GW=`$(ip -4 route list default | awk 'NR==1{print `$3}'); ip route del 10.96.0.0/12 via `$LAN_GW dev eth0 || true; ip route del 10.244.0.0/16 via `$LAN_GW dev eth0 || true; ip route del 192.168.1.0/24 via `$LAN_GW dev eth0 || true"

    $content = [regex]::Replace($content, '(?m)^PostUp\s*=.*$', $postUp)
    $content = [regex]::Replace($content, '(?m)^PostDown\s*=.*$', $postDown)

    return $content
}

$definitions = @(
    @{
        Name = "jackett"
        Source = "jackett\config"
        Claim = "jackett-config"
        Mount = "/config"
        Prepare = {
            param($StageRoot)
            Update-JackettConfig -Path (Join-Path $StageRoot "Jackett\ServerConfig.json")
            Remove-RuntimeFiles -Path $StageRoot
        }
    },
    @{
        Name = "radarr"
        Source = "radarr\config"
        Claim = "radarr-config"
        Mount = "/config"
        Prepare = {
            param($StageRoot)
            Remove-RuntimeFiles -Path $StageRoot
        }
    },
    @{
        Name = "sonarr"
        Source = "sonarr\config"
        Claim = "sonarr-config"
        Mount = "/config"
        Prepare = {
            param($StageRoot)
            Remove-RuntimeFiles -Path $StageRoot
        }
    },
    @{
        Name = "overseerr"
        Source = "overseerr\config"
        Claim = "overseerr-config"
        Mount = "/config"
        Prepare = {
            param($StageRoot)
            Update-OverseerrConfig -Path (Join-Path $StageRoot "settings.json")
            Remove-RuntimeFiles -Path $StageRoot
        }
    },
    @{
        Name = "plex"
        Source = "plex\config"
        Claim = "plex-config"
        Mount = "/config"
        Prepare = {
            param($StageRoot)
            Remove-RuntimeFiles -Path $StageRoot
        }
    },
    @{
        Name = "deluge"
        Source = "deluge\config"
        Claim = "deluge-config"
        Mount = "/config"
        Prepare = {
            param($StageRoot, $SourceRootPath)
            $wg0Source = Join-Path $SourceRootPath "wireguard\wg0.conf"
            if (-not (Test-Path -LiteralPath $wg0Source -PathType Leaf)) {
                throw "WireGuard config '$wg0Source' was not found."
            }

            Remove-RuntimeFiles -Path $StageRoot
        }
        PostSeed = {
            param($NamespaceName, $ClaimName, $SourceRootPath)

            $wg0Source = Join-Path $SourceRootPath "wireguard\wg0.conf"
            $wg0Content = Get-RenderedDelugeWireGuardConfig -Path $wg0Source
            $wg0Base64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($wg0Content))

            Invoke-PvcPostSeedMutation -Namespace $NamespaceName -ClaimName $ClaimName -Action {
                param($PodName)

                $script = @"
mkdir -p /target/wg_confs /target/templates /target/coredns
printf '%s' '$wg0Base64' | base64 -d > /target/wg_confs/wg0.conf
chown -R 1000:1000 /target/wg_confs /target/templates /target/coredns
rm -f /target/wg0.conf
chown 1000:1000 /target/wg_confs/wg0.conf
chmod 600 /target/wg_confs/wg0.conf
"@
                Invoke-PodShell -Namespace $NamespaceName -PodName $PodName -Script $script | Out-Null
            }
        }
    }
)

foreach ($definition in $definitions) {
    $sourcePath = Join-Path $SourceRoot $definition.Source
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        throw "Source path '$sourcePath' does not exist."
    }

    $stagePath = New-TemporaryDirectory -Prefix "$($definition.Name)-seed"
    try {
        Copy-Tree -SourcePath $sourcePath -DestinationPath $stagePath
        & $definition.Prepare $stagePath $SourceRoot

        Seed-DirectoryToPvc -Namespace $Namespace -PvcName $definition.Claim -SourcePath $stagePath -MountPath $definition.Mount
        if ($definition.ContainsKey("PostSeed") -and $definition.PostSeed) {
            & $definition.PostSeed $Namespace $definition.Claim $SourceRoot
        }
        Write-Host "Seeded $($definition.Name) from '$sourcePath'." -ForegroundColor Green
    }
    finally {
        Remove-Item -LiteralPath $stagePath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
