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
            param($StageRoot)
            Remove-RuntimeFiles -Path $StageRoot
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
        Write-Host "Seeded $($definition.Name) from '$sourcePath'." -ForegroundColor Green
    }
    finally {
        Remove-Item -LiteralPath $stagePath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
