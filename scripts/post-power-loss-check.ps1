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

function Remove-TerminalControllerPods {
    Write-Host ""
    Write-Host "== Cleanup terminal controller pods ==" -ForegroundColor Cyan

    if ($SkipFailedPodCleanup) {
        Write-Host "[SKIP] Terminal pod cleanup disabled." -ForegroundColor Yellow
        return
    }

    $raw = kubectl get pods -A -o json
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list pods."
    }

    $pods = ($raw | ConvertFrom-Json).items
    $terminalControllerPods = @(
        $pods | Where-Object {
            ($_.status.phase -eq "Failed" -or $_.status.phase -eq "Succeeded") -and
            $_.metadata.ownerReferences -and
            $_.metadata.ownerReferences[0].kind -ne "Job"
        }
    )

    if ($terminalControllerPods.Count -eq 0) {
        Write-Host "[OK] No terminal non-Job controller pods to clean up." -ForegroundColor Green
        return
    }

    $terminalControllerPods |
        Select-Object @{Name = "Namespace"; Expression = { $_.metadata.namespace } },
                      @{Name = "Name"; Expression = { $_.metadata.name } },
                      @{Name = "Phase"; Expression = { $_.status.phase } },
                      @{Name = "OwnerKind"; Expression = { $_.metadata.ownerReferences[0].kind } } |
        Format-Table -AutoSize

    foreach ($pod in $terminalControllerPods) {
        kubectl -n $pod.metadata.namespace delete pod $pod.metadata.name --ignore-not-found=true | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to delete terminal pod $($pod.metadata.namespace)/$($pod.metadata.name)."
        }
    }

    Write-Host "[OK] Removed $($terminalControllerPods.Count) terminal non-Job controller pod(s)." -ForegroundColor Green
}

Push-Location $repoRoot
try {
    Invoke-Step "Core preflight" { & "$PSScriptRoot\preflight-core.ps1" }
    Invoke-Step "ArgoCD core health gate" { & "$PSScriptRoot\argocd-health-gate.ps1" }
    Remove-TerminalControllerPods
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
