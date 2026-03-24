param(
    [string]$BitwardenAccessToken = $env:BITWARDEN_ACCESS_TOKEN
)

$ErrorActionPreference = "Stop"

function Wait-ForKubernetesApi {
    param(
        [int]$MaxRetries = 60,
        [int]$SleepSeconds = 10
    )

    Write-Host "Waiting for Kubernetes API to be reachable..." -ForegroundColor Cyan
    for ($retry = 1; $retry -le $MaxRetries; $retry++) {
        kubectl get nodes --request-timeout=5s *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Kubernetes API is up." -ForegroundColor Green
            return
        }

        Write-Host "  API not ready yet (attempt $retry/$MaxRetries)" -ForegroundColor DarkGray
        Start-Sleep -Seconds $SleepSeconds
    }

    throw "Timed out waiting for Kubernetes API."
}

function Ensure-BitwardenBootstrapSecret {
    param(
        [string]$Namespace,
        [string]$Name,
        [string]$Token
    )

    Write-Host "Ensuring bootstrap secret '$Name' exists in namespace '$Namespace'..." -ForegroundColor Cyan
    kubectl create namespace $Namespace --dry-run=client -o yaml | kubectl apply -f - | Out-Null

    $existing = kubectl get secret $Name -n $Namespace -o name --ignore-not-found 2>$null
    if ($existing) {
        Write-Host "  Secret already exists. Skipping creation." -ForegroundColor Yellow
        return
    }

    $resolvedToken = $Token
    if (-not $resolvedToken) {
        Write-Host "  Enter Bitwarden Access Token:" -ForegroundColor Yellow
        $secure = Read-Host -AsSecureString
        $resolvedToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    }

    kubectl create secret generic $Name -n $Namespace --from-literal=token=$resolvedToken --dry-run=client -o yaml | kubectl apply -f - | Out-Null
    Write-Host "  Secret created." -ForegroundColor Green
}

function Wait-ForArgoApplicationHealthySynced {
    param(
        [string]$Name,
        [int]$TimeoutSeconds = 1800,
        [int]$SleepSeconds = 10
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
            Write-Host "  App '$Name' is Synced and Healthy." -ForegroundColor Green
            return
        }

        Write-Host "  Waiting for app '$Name' (sync=$sync, health=$health)..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $SleepSeconds
    }

    throw "Timed out waiting for app '$Name' to become Synced+Healthy."
}

function Wait-ForClusterSecretStoreReady {
    param(
        [string]$Name,
        [int]$TimeoutSeconds = 900,
        [int]$SleepSeconds = 10
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $raw = kubectl get clustersecretstore $Name -o json 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) {
            $store = $raw | ConvertFrom-Json
            $ready = ($store.status.conditions | Where-Object { $_.type -eq "Ready" } | Select-Object -First 1).status
        } else {
            $ready = $null
        }
        if ($ready -eq "True") {
            Write-Host "ClusterSecretStore '$Name' is Ready." -ForegroundColor Green
            return
        }

        Write-Host "  Waiting for ClusterSecretStore '$Name' to be Ready..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $SleepSeconds
    }

    throw "Timed out waiting for ClusterSecretStore '$Name' to become Ready."
}

function Wait-ForCertificateReady {
    param(
        [string]$Namespace,
        [string]$Name,
        [int]$TimeoutSeconds = 1200,
        [int]$SleepSeconds = 10
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $raw = kubectl get certificate $Name -n $Namespace -o json 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) {
            $cert = $raw | ConvertFrom-Json
            $ready = ($cert.status.conditions | Where-Object { $_.type -eq "Ready" } | Select-Object -First 1).status
        } else {
            $ready = $null
        }
        if ($ready -eq "True") {
            Write-Host "Certificate '$Namespace/$Name' is Ready." -ForegroundColor Green
            return
        }

        Write-Host "  Waiting for certificate '$Namespace/$Name' to be Ready..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $SleepSeconds
    }

    throw "Timed out waiting for certificate '$Namespace/$Name' to become Ready."
}

function Wait-ForGatewayHttpsResolved {
    param(
        [string]$Namespace,
        [string]$Name,
        [int]$TimeoutSeconds = 1200,
        [int]$SleepSeconds = 10
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $raw = kubectl get gateway $Name -n $Namespace -o json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) {
            Start-Sleep -Seconds $SleepSeconds
            continue
        }

        $gw = $raw | ConvertFrom-Json
        $https = $gw.status.listeners | Where-Object { $_.name -eq "https" }

        if ($https) {
            $programmed = ($https.conditions | Where-Object { $_.type -eq "Programmed" } | Select-Object -First 1).status
            $resolved = ($https.conditions | Where-Object { $_.type -eq "ResolvedRefs" } | Select-Object -First 1).status
            if ($programmed -eq "True" -and $resolved -eq "True") {
                Write-Host "Gateway '$Namespace/$Name' HTTPS listener is Programmed and ResolvedRefs." -ForegroundColor Green
                return
            }

            Write-Host "  Waiting for gateway '$Namespace/$Name' HTTPS listener (Programmed=$programmed, ResolvedRefs=$resolved)..." -ForegroundColor DarkGray
        } else {
            Write-Host "  Waiting for gateway '$Namespace/$Name' HTTPS listener to appear..." -ForegroundColor DarkGray
        }

        Start-Sleep -Seconds $SleepSeconds
    }

    throw "Timed out waiting for gateway '$Namespace/$Name' HTTPS listener readiness."
}

# 1. Setup environment
$KubeConfigPath = "$PSScriptRoot\tofu\output\kubeconfig"
if (-not (Test-Path $KubeConfigPath)) {
    throw "Kubeconfig not found at $KubeConfigPath. Run 'tofu apply' first."
}
$env:KUBECONFIG = $KubeConfigPath
Write-Host "Environment configured (KUBECONFIG=$KubeConfigPath)." -ForegroundColor Green

# 2. Wait for API
Wait-ForKubernetesApi

# 3. Install ArgoCD
Write-Host "Installing ArgoCD..." -ForegroundColor Cyan
helm repo add argo https://argoproj.github.io/argo-helm | Out-Null
helm repo update | Out-Null
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - | Out-Null

Write-Host "Installing Gateway API CRDs..." -ForegroundColor Cyan
kubectl apply -k kubernetes/infrastructure/crds/gateway-api | Out-Null

helm upgrade --install argocd argo/argo-cd --version 7.7.16 `
    --namespace argocd `
    -f kubernetes/infrastructure/controllers/argocd/values.yaml `
    --set crds.install=true | Out-Null

kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s | Out-Null
Write-Host "ArgoCD installed." -ForegroundColor Green

# 4. Ensure bootstrap secret before GitOps sync
Ensure-BitwardenBootstrapSecret -Namespace "external-secrets" -Name "bitwarden-access-token" -Token $BitwardenAccessToken

# 5. Apply bootstrap app
Write-Host "Applying bootstrap application..." -ForegroundColor Cyan
kubectl apply -f kubernetes/bootstrap.yaml | Out-Null
Write-Host "Bootstrap manifest applied." -ForegroundColor Green

# 6. Strict core gate
Write-Host "Running strict core health gate..." -ForegroundColor Cyan
$coreApps = @(
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

foreach ($appName in $coreApps) {
    Wait-ForArgoApplicationHealthySynced -Name $appName -TimeoutSeconds 2400
}

Wait-ForClusterSecretStoreReady -Name "bitwarden-secretsmanager"
Wait-ForCertificateReady -Namespace "gateway" -Name "cert-wildcard"
Wait-ForGatewayHttpsResolved -Namespace "gateway" -Name "external"
& "$PSScriptRoot/scripts/preflight-core.ps1"

Write-Host "`nCluster bootstrap complete and core gate is green." -ForegroundColor Green
Write-Host "ArgoCD URL: https://argo.rosenvall.se"
Write-Host "Bootstrap note: bitwarden-access-token remains manual by design." -ForegroundColor Yellow
