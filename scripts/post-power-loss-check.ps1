param(
    [switch]$SkipMediaChecks,
    [switch]$SkipFailedPodCleanup
)

$ErrorActionPreference = "Stop"

if (-not $env:KUBECONFIG) {
    throw "KUBECONFIG is not set."
}

$repoRoot = Split-Path -Parent $PSScriptRoot

function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Command
    )

    Write-Host ""
    Write-Host "== $Name ==" -ForegroundColor Cyan
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed."
    }
}

function Remove-NodeShutdownFailedPods {
    Write-Host ""
    Write-Host "== Cleanup node-shutdown failed pods ==" -ForegroundColor Cyan

    if ($SkipFailedPodCleanup) {
        Write-Host "[SKIP] Failed pod cleanup disabled." -ForegroundColor Yellow
        return
    }

    $raw = kubectl get pods -A --field-selector=status.phase=Failed -o json
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list failed pods."
    }

    $failedPods = ($raw | ConvertFrom-Json).items
    $shutdownPods = @(
        $failedPods | Where-Object {
            $_.status.reason -eq "NodeShutdown" -or
            ($_.status.reason -eq "Terminated" -and $_.status.message -like "*node shutdown*")
        }
    )

    if ($shutdownPods.Count -eq 0) {
        Write-Host "[OK] No node-shutdown failed pods to clean up." -ForegroundColor Green
        return
    }

    foreach ($pod in $shutdownPods) {
        kubectl -n $pod.metadata.namespace delete pod $pod.metadata.name --ignore-not-found=true | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to delete failed pod $($pod.metadata.namespace)/$($pod.metadata.name)."
        }
    }

    Write-Host "[OK] Removed $($shutdownPods.Count) node-shutdown failed pod(s)." -ForegroundColor Green
}

Push-Location $repoRoot
try {
    Invoke-Step "Core preflight" { & "$PSScriptRoot\preflight-core.ps1" }
    Invoke-Step "ArgoCD core health gate" { & "$PSScriptRoot\argocd-health-gate.ps1" }
    Remove-NodeShutdownFailedPods
    Invoke-Step "Cluster health report" { & "$PSScriptRoot\cluster-health-report.ps1" }

    if (-not $SkipMediaChecks) {
        Invoke-Step "Media NFS verification" { & "$PSScriptRoot\verify-media-nfs.ps1" }
        Invoke-Step "Deluge VPN verification" { & "$PSScriptRoot\verify-deluge-vpn.ps1" }
    }

    Write-Host ""
    Write-Host "[OK] Post power-loss recovery checks completed." -ForegroundColor Green
} finally {
    Pop-Location
}
