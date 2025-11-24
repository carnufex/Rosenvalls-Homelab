# Bootstrap Script for Rosenvalls-Homelab
# This script automates the "messy middle" between Infrastructure (Tofu) and GitOps (ArgoCD).

$ErrorActionPreference = "Stop"

# 1. Setup Environment
$KubeConfigPath = "$PSScriptRoot\tofu\output\kubeconfig"
if (-not (Test-Path $KubeConfigPath)) {
    Write-Error "Kubeconfig not found at $KubeConfigPath. Did you run 'tofu apply'?"
}
$env:KUBECONFIG = $KubeConfigPath
Write-Host "Environment configured." -ForegroundColor Green

# 2. Install ArgoCD (GitOps)
Write-Host "Installing ArgoCD..." -ForegroundColor Cyan
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install argocd argo/argo-cd --version 7.7.16 `
    --namespace argocd `
    -f kubernetes/infrastructure/controllers/argocd/values.yaml `
    --set crds.install=true

Write-Host "Waiting for ArgoCD to be ready..." -ForegroundColor Cyan
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s
Write-Host "ArgoCD installed." -ForegroundColor Green

# 3. Apply Bootstrap App
Write-Host "Applying GitOps Bootstrap..." -ForegroundColor Cyan
kubectl apply -f kubernetes/bootstrap.yaml
Write-Host "Bootstrap manifest applied." -ForegroundColor Green

# 4. Setup Secrets
Write-Host "Setting up Secrets..." -ForegroundColor Cyan
$SecretName = "bitwarden-access-token"
$SecretNamespace = "external-secrets"

# Check if secret exists
if (kubectl get secret $SecretName -n $SecretNamespace --ignore-not-found) {
    Write-Host "   Secret '$SecretName' already exists. Skipping." -ForegroundColor Yellow
} else {
    Write-Host "   Please enter your Bitwarden Access Token:" -ForegroundColor Yellow
    $Token = Read-Host -AsSecureString
    $TokenPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Token))
    
    kubectl create namespace $SecretNamespace --dry-run=client -o yaml | kubectl apply -f -
    kubectl create secret generic $SecretName -n $SecretNamespace --from-literal=token=$TokenPlain
    Write-Host "Secret created." -ForegroundColor Green
}

Write-Host "`nCluster Bootstrap Complete!" -ForegroundColor Green
Write-Host "You can now access ArgoCD:"
Write-Host "   User: admin"
Write-Host "   Password: (see README for command)"
