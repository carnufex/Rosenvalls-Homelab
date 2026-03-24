param(
    [int]$TimeoutSeconds = 2400,
    [int]$SleepSeconds = 10,
    [string[]]$CoreApps = @(
        "cilium",
        "longhorn",
        "cert-manager",
        "external-secrets",
        "gateway",
        "cloudflared",
        "cloudnative-pg",
        "authentik-db-prereqs",
        "authentik-runtime",
        "authentik-db-ops",
        "argocd",
        "prometheus-stack"
    )
)

$ErrorActionPreference = "Stop"

if (-not $env:KUBECONFIG) {
    throw "KUBECONFIG is not set."
}

function Wait-ForArgoApplicationHealthySynced {
    param(
        [string]$Name,
        [int]$TimeoutSeconds,
        [int]$SleepSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $raw = kubectl get applications.argoproj.io $Name -n argocd -o json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) {
            Start-Sleep -Seconds $SleepSeconds
            continue
        }

        $app = $raw | ConvertFrom-Json
        $sync = $app.status.sync.status
        $health = $app.status.health.status

        if ($sync -eq "Synced" -and $health -eq "Healthy") {
            Write-Host "[OK] $Name is Synced+Healthy" -ForegroundColor Green
            return
        }

        Write-Host "[WAIT] $Name sync=$sync health=$health" -ForegroundColor DarkGray
        Start-Sleep -Seconds $SleepSeconds
    }

    throw "Timed out waiting for '$Name' to become Synced+Healthy."
}

foreach ($app in $CoreApps) {
    Wait-ForArgoApplicationHealthySynced -Name $app -TimeoutSeconds $TimeoutSeconds -SleepSeconds $SleepSeconds
}

Write-Host "All core applications are Synced+Healthy." -ForegroundColor Green
