param(
    [string]$SourceRoot = "C:\Users\Crille\Downloads\media",
    [string]$Namespace = "homeassistant",
    [string]$PvcName = "homeassistant-config",
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

$sourcePath = Join-Path $SourceRoot "homeassistant"
if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
    throw "Home Assistant source path '$sourcePath' does not exist."
}

if (-not $AllowRunning) {
    $replicas = (& kubectl @("-n", $Namespace, "get", "deployment", "homeassistant", "-o", "jsonpath={.spec.replicas}") 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read deployment '$Namespace/homeassistant'.`n$($replicas | Out-String)"
    }

    $replicas = ($replicas | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($replicas)) {
        $replicas = "0"
    }

    if ([int]$replicas -gt 0) {
        throw "Refusing to seed 'homeassistant' while it has replicas=$replicas. Scale it to 0 first, or pass -AllowRunning if you intentionally accept the risk."
    }
}

$stagePath = New-TemporaryDirectory -Prefix "homeassistant-seed"
try {
    Copy-Tree -SourcePath $sourcePath -DestinationPath $stagePath

    $configPath = Join-Path $stagePath "configuration.yaml"
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Home Assistant configuration file '$configPath' was not found."
    }

    $configLines = Get-Content -LiteralPath $configPath
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

    Set-Utf8NoBomContent -Path $configPath -Value ($outputLines -join [Environment]::NewLine)

    $coreConfigPath = Join-Path $stagePath ".storage\core.config"
    if (Test-Path -LiteralPath $coreConfigPath) {
        $coreConfig = Get-Content -LiteralPath $coreConfigPath -Raw | ConvertFrom-Json
        $coreConfig.data.internal_url = "https://homeassistant.rosenvall.local"
        $coreConfig.data.external_url = "https://homeassistant.rosenvall.local"
        Set-Utf8NoBomContent -Path $coreConfigPath -Value ($coreConfig | ConvertTo-Json -Depth 20)
    }

    Get-ChildItem -LiteralPath $stagePath -Recurse -Force -File |
        Where-Object { $_.Name -eq ".ha_run.lock" -or $_.Name -like "*.pid" } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Seed-DirectoryToPvc -Namespace $Namespace -PvcName $PvcName -SourcePath $stagePath -MountPath "/config"
    Write-Host "Seeded Home Assistant from '$sourcePath' into '$Namespace/$PvcName'." -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $stagePath -Recurse -Force -ErrorAction SilentlyContinue
}
