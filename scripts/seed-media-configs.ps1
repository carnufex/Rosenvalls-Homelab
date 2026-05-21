param(
    [string]$SourceRoot = "C:\Users\Crille\Downloads\media",
    [string]$Namespace = "media",
    [string[]]$Apps = @(),
    [switch]$AllowRunning
)

. (Join-Path $PSScriptRoot "pvc-seed-utils.ps1")

$ErrorActionPreference = "Stop"
Set-HomelabKubeconfig

function Set-Utf8NoBomContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Remove-RuntimeFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Get-ChildItem -LiteralPath $Path -Recurse -Force -File |
        Where-Object { $_.Name -eq ".ha_run.lock" -or $_.Name -eq "deluged.pid" -or $_.Name -like "*.pid" } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Assert-DeploymentScaledDown {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Namespace,
        [Parameter(Mandatory = $true)]
        [string]$DeploymentName
    )

    if ($AllowRunning) {
        return
    }

    $replicas = (& kubectl @("-n", $Namespace, "get", "deployment", $DeploymentName, "-o", "jsonpath={.spec.replicas}") 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read deployment '$Namespace/$DeploymentName'.`n$($replicas | Out-String)"
    }

    $replicas = ($replicas | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($replicas)) {
        $replicas = "0"
    }

    if ([int]$replicas -gt 0) {
        throw "Refusing to seed '$DeploymentName' while it has replicas=$replicas. Scale it to 0 first, or pass -AllowRunning if you intentionally accept the risk."
    }
}

function Update-JackettConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $config.LocalBindAddress = "0.0.0.0"
    $config.AllowExternal = $true
    Set-Utf8NoBomContent -Path $Path -Value ($config | ConvertTo-Json -Depth 10)
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

    Set-Utf8NoBomContent -Path $Path -Value ($settings | ConvertTo-Json -Depth 20)
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
        Deployment = "jackett"
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
        Deployment = "radarr"
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
        Deployment = "sonarr"
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
        Deployment = "overseerr"
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
        Deployment = "plex"
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
        Deployment = "deluge-vpn"
        Source = "deluge\config"
        Claim = "deluge-config"
        Mount = "/config"
        Prepare = {
            param($StageRoot)
            Remove-RuntimeFiles -Path $StageRoot
        }
    }
)

$selectedApps = $Apps | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.ToLowerInvariant() }
if ($selectedApps.Count -gt 0) {
    $knownApps = $definitions | ForEach-Object { $_.Name }
    foreach ($app in $selectedApps) {
        if ($knownApps -notcontains $app) {
            throw "Unknown media app '$app'. Known apps: $($knownApps -join ', ')."
        }
    }
}

foreach ($definition in $definitions) {
    if ($selectedApps.Count -gt 0 -and $selectedApps -notcontains $definition.Name) {
        continue
    }

    $sourcePath = Join-Path $SourceRoot $definition.Source
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        throw "Source path '$sourcePath' does not exist."
    }

    Assert-DeploymentScaledDown -Namespace $Namespace -DeploymentName $definition.Deployment

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
